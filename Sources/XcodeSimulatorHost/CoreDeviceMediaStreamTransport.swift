import ABIBridge
import AppKit

@MainActor
final class CoreDeviceMediaStreamTransport: RemoteScreenTransport {
    private let remote: CoreDeviceRemoteScreenDevice
    private let input: CoreDeviceScreenInput
    private let bindings: MediaStreamBindings
    private let layer = CALayer()
    private let capture = RemoteScreenFrameCapture()
    private let contentView: NSView
    private var session: NativeSwiftValue?
    private var stream: NativeSwiftValue?
    private var observation: Task<Void, Never>?
    private var disconnecting: Task<Void, any Error>?
    private var events: (@MainActor (RemoteScreenTransportEvent) -> Void)?
    private var stopped = false
    private(set) var inputCapabilities: Set<RemoteDeviceInputKind> = []
    var canCaptureScreenshot: Bool { !stopped && stream != nil }

    init(remote: CoreDeviceRemoteScreenDevice, contentView: NSView) throws {
        self.remote = remote
        self.contentView = contentView
        input = CoreDeviceScreenInput(remote: remote)
        bindings = try MediaStreamBindings(runtime: remote.runtime)
        layer.contentsGravity = .resizeAspect
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
    }

    func start(events: @escaping @MainActor (RemoteScreenTransportEvent) -> Void) async throws {
        guard !stopped else { throw CancellationError() }
        self.events = events
        inputCapabilities = try input.capabilities()
        layer.frame = contentView.bounds
        contentView.layer?.addSublayer(layer)
        let session = try unsafe bindings.makeSession.unsafeInvoke(UUID())
        self.session = session
        let configuration = try unsafe bindings.makeConfiguration.unsafeInvoke(layer, 30)
        let created = try await unsafe bindings.makeVideoStream.unsafeInvoke(on: session, configuration, remote.object).copyUnderlyingValue()
        stream = created
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        let activate = try created.type.resolveAndWait(.method("CoreDeviceMediaStreamSupport.MediaStreamProtocol.activate()",
            as: (() async throws -> NativeSwiftValue).self, valueABIs: bindings.eventABIs))
        let sequence = try await unsafe activate.unsafeInvoke(on: created)
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        observation = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.observe(sequence)
                if !self.stopped { await self.finishObservation(error: nil) }
            } catch {
                guard !self.stopped else { return }
                await self.finishObservation(error: error)
            }
        }
        // Activation establishes the transport; a decoded-frame event separately proves pixels arrived.
        events(.connected)
        let requestFrame = try created.type.resolveAndWait(.method("CoreDeviceMediaStreamSupport.VideoStream.requestLastDecodedFrame()",
            as: (() async -> Void).self))
        try await unsafe requestFrame.unsafeInvoke(on: created)
    }

    func captureScreenshot() async throws -> CGImage {
        guard !stopped, let stream else {
            throw CLIError.unavailable("remote-screen-connection", "Connect the device screen before capturing it.")
        }
        let request = try stream.type.resolveAndWait(.method("CoreDeviceMediaStreamSupport.VideoStream.requestLastDecodedFrame()",
            as: (() async -> Void).self))
        return try await capture.capture {
            try await unsafe request.unsafeInvoke(on: stream)
        }
    }

    func send(_ input: RemoteScreenInput) async throws { try await self.input.send(input) }
    func releaseInputs() async throws { try await input.releaseInputs() }

    func stop() async throws {
        stopped = true
        events = nil
        capture.fail(CancellationError())
        inputCapabilities = []
        observation?.cancel()
        defer { layer.removeFromSuperlayer() }
        var failure: (any Error)?
        do { try await disconnectNative() } catch { failure = error }
        let task = observation
        observation = nil
        await task?.value
        if let failure { throw failure }
    }

    private func finishObservation(error: (any Error)?) async {
        var failure = error
        do { try await disconnectNative() }
        catch { failure = failure.map { RemoteDeviceScreenSession.combining($0, cleanup: error) } ?? error }
        capture.fail(failure ?? CLIError.unavailable("remote-screen-disconnected", "The remote screen connection ended before its screenshot arrived."))
        if let failure { events?(.failure(failure)) }
        else { events?(.disconnected) }
    }

    private func disconnectNative() async throws {
        if let disconnecting { try await disconnecting.value; return }
        let task = Task { [self] in
            var failure: (any Error)?
            do { try await input.releaseInputs() } catch { failure = error }
            if let stream {
                do {
                    let invalidate = try stream.type.resolveAndWait(.method("CoreDeviceMediaStreamSupport.MediaStreamProtocol.invalidate()",
                        as: (() async -> Void).self))
                    try await unsafe invalidate.unsafeInvoke(on: stream)
                    self.stream = nil
                    session = nil
                } catch {
                    failure = failure.map { RemoteDeviceScreenSession.combining($0, cleanup: error) } ?? error
                }
            }
            if let failure { throw failure }
        }
        disconnecting = task
        defer { disconnecting = nil }
        try await task.value
    }

    private func observe(_ sequence: NativeSwiftValue) async throws {
        let make = try sequence.type.resolveAndWait(.method("makeAsyncIterator()", as: (() -> NativeSwiftValue).self,
            valueABIs: bindings.eventABIs, receiverABI: .opaque(named: sequence.type.name)))
        let iterator = try unsafe make.unsafeInvoke(on: sequence)
        let next = try iterator.type.resolveAndWait(.method("next()", as: (() async throws -> NativeSwiftValue?).self,
            valueABIs: bindings.eventABIs, receiverABI: .opaque(named: iterator.type.name)))
        while let event = try await unsafe next.unsafeInvoke(on: iterator) {
            try Task.checkCancellation()
            guard !stopped else { return }
            if let attributes = try event.resolveEnumPayloadAndWait(forCase: "remoteVideoAttributesChanged") {
                events?(.attributes(try bindings.attributes(attributes)))
            } else if let frame = try event.resolveEnumPayloadAndWait(forCase: "receivedLastDecodedFrame") {
                guard let data = try frame.withCopy({ $0 as? Data }) else {
                    throw CLIError.io("remote-screen-frame", "The remote screen supplied an unexpected frame payload.")
                }
                capture.receive(data)
                if !data.isEmpty { events?(.frameReceived) }
            }
        }
    }
}

@MainActor
private final class MediaStreamBindings {
    let makeSession: NativeSwiftFunction<(UUID) -> NativeSwiftValue>
    let makeConfiguration: NativeSwiftFunction<(CALayer, UInt) -> NativeSwiftValue>
    let makeVideoStream: NativeSwiftMethod<(NativeSwiftValue, NativeSwiftValue) async throws -> NativeSwiftValue>
    let eventABIs: [NativeSwiftType: NativeType]
    private let ratio: NativeSwiftMethod<() -> CGSize>
    private let contentsRect: NativeSwiftMethod<() -> CGRect>
    private let scaleFactor: NativeSwiftMethod<() -> Float>
    private let orientation: NativeSwiftMethod<() -> NativeSwiftValue>
    private let orientationRawValue: NativeSwiftMethod<() -> String>

    init(runtime: ABIRuntime) throws {
        try CoreDeviceRemoteScreenDevice.load("/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Frameworks/CoreDeviceMediaStreamSupport.framework/Versions/A/CoreDeviceMediaStreamSupport")
        let session = try runtime.resolveSwiftTypeAndWait(named: "CoreDeviceMediaStreamSupport.MediaStreamSession")
        makeSession = try session.resolveAndWait(.initializer("init(clientSessionID:)", as: ((UUID) -> NativeSwiftValue).self))
        let configuration = try runtime.resolveSwiftTypeAndWait(named: "CoreDeviceMediaStreamSupport.VideoStreamConfiguration")
        makeConfiguration = try configuration.resolveAndWait(.staticMethod("receiveMirroredPrimary(layer:timeout:)",
            as: ((CALayer, UInt) -> NativeSwiftValue).self))
        makeVideoStream = try session.resolveAndWait(.method("makeVideoStream(withConfiguration:fromRemoteDevice:)",
            as: ((NativeSwiftValue, NativeSwiftValue) async throws -> NativeSwiftValue).self))
        let event = try runtime.resolveSwiftTypeAndWait(named: "CoreDeviceMediaStreamSupport.VideoStreamEvent")
        let arguments: [NativeSwiftGenericArgument] = [.type(event), .type((any Error).self)]
        let sequence = try runtime.resolveSwiftTypeAndWait(named: "Swift.AsyncThrowingStream", genericArguments: arguments)
        let iterator = try runtime.resolveSwiftTypeAndWait(named: "Swift.AsyncThrowingStream.Iterator", genericArguments: arguments)
        // These stream/iterator declarations are non-frozen in the Swift SDK interface.
        eventABIs = try Dictionary(uniqueKeysWithValues: [event, sequence, iterator].map { ($0, try .opaque(named: $0.name)) })
        let attributes = try runtime.resolveSwiftTypeAndWait(named: "CoreDeviceMediaStreamSupport.VideoStreamAttributes")
        let abi = try NativeType.opaque(named: attributes.name)
        ratio = try attributes.resolveAndWait(.getter("ratio", as: (() -> CGSize).self, receiverABI: abi))
        contentsRect = try attributes.resolveAndWait(.getter("contentsRect", as: (() -> CGRect).self, receiverABI: abi))
        scaleFactor = try attributes.resolveAndWait(.getter("scaleFactor", as: (() -> Float).self, receiverABI: abi))
        orientation = try attributes.resolveAndWait(.getter("orientation", as: (() -> NativeSwiftValue).self, receiverABI: abi))
        let direction = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice.DeviceOrientation")
        orientationRawValue = try direction.resolveAndWait(.getter("rawValue", as: (() -> String).self))
    }

    func attributes(_ value: NativeSwiftValue) throws -> RemoteDeviceVideoAttributes {
        try unsafe RemoteDeviceVideoAttributes(aspectRatio: ratio.unsafeInvoke(on: value),
            contentsRect: contentsRect.unsafeInvoke(on: value), scaleFactor: scaleFactor.unsafeInvoke(on: value),
            orientation: RemoteDeviceOrientation(rawValue: orientationRawValue.unsafeInvoke(on: orientation.unsafeInvoke(on: value))))
    }
}
