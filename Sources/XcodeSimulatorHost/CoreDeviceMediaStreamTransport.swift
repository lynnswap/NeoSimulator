import ABIBridge
import AppKit

@MainActor
final class CoreDeviceMediaStreamTransport: RemoteScreenTransport {
    private let remote: CoreDeviceRemoteScreenDevice
    private let input: CoreDeviceScreenInput
    private let bindings: MediaStreamBindings
    private let framebuffer = RemoteScreenFramebuffer(frame: .zero)
    private let displayGeometry: CoreDeviceDisplayGeometry
    private let capture = RemoteScreenFrameCapture()
    private let contentView: NSView
    private var session: NativeSwiftValue?
    private var stream: NativeSwiftValue?
    private var observation: Task<Void, Never>?
    private var disconnecting: Task<Void, any Error>?
    private var events: (@MainActor (RemoteScreenTransportEvent) -> Void)?
    private var stopped = false
    private var observationFinished = false
    private var observationFailure: (any Error)?
    private let capabilityObservation: RemoteScreenInputCapabilityObservation
    var inputCapabilities: Set<RemoteDeviceInputKind> {
        framebuffer.isReady ? capabilityObservation.capabilities : capabilityObservation.capabilities.subtracting([.pointer, .digitizer])
    }
    var canCaptureScreenshot: Bool { !stopped && stream != nil }
    private(set) var canRecordScreen = false

    init(remote: CoreDeviceRemoteScreenDevice, contentView: NSView) throws {
        self.remote = remote
        self.contentView = contentView
        let input = CoreDeviceScreenInput(remote: remote)
        self.input = input
        capabilityObservation = RemoteScreenInputCapabilityObservation(source: try CoreDeviceInputCapabilitySource(remote: remote),
            read: { try input.capabilities() }, invalidateInputs: { input.discardInputs(for: $0) })
        bindings = try MediaStreamBindings(runtime: remote.runtime)
        displayGeometry = try CoreDeviceDisplayGeometry(remote: remote)
        framebuffer.autoresizingMask = [.width, .height]
    }

    func start(events: @escaping @MainActor (RemoteScreenTransportEvent) -> Void) async throws {
        try checkConnection()
        self.events = events
        try capabilityObservation.start(update: { [weak self] in
            self?.events?(.inputGeometryChanged)
        }, failure: { [weak self] error in
            Task { @MainActor [weak self] in await self?.finishObservation(error: error) }
        })
        canRecordScreen = try remote.supports("com.apple.coredevice.feature.screenrecording")
        framebuffer.frame = contentView.bounds
        contentView.addSubview(framebuffer)
        try await displayGeometry.start { [weak self] result in
            guard let self, !self.stopped else { return }
            switch result {
            case .success(let display):
                self.framebuffer.update(display: display)
                self.events?(.inputGeometryChanged)
            case .failure(let error):
                self.framebuffer.update(display: nil)
                Task { @MainActor [weak self] in await self?.finishObservation(error: error) }
            }
        }
        try checkConnection()
        let session = try unsafe bindings.makeSession.unsafeInvoke(UUID())
        self.session = session
        let configuration = try unsafe bindings.makeConfiguration.unsafeInvoke(framebuffer.sourceLayer, 30)
        let created = try await unsafe bindings.makeVideoStream.unsafeInvoke(on: session, configuration, remote.object).copyUnderlyingValue()
        stream = created
        try Task.checkCancellation()
        try checkConnection()
        let activate = try created.type.resolveAndWait(.method("CoreDeviceMediaStreamSupport.MediaStreamProtocol.activate()",
            as: (() async throws -> NativeSwiftValue).self, valueABIs: bindings.eventABIs))
        let sequence = try await unsafe activate.unsafeInvoke(on: created)
        try Task.checkCancellation()
        try checkConnection()
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
        let requestFrame = try created.type.resolveAndWait(.method("CoreDeviceMediaStreamSupport.VideoStream.requestLastDecodedFrame()",
            as: (() async -> Void).self))
        try capture.requestInitialFrame {
            try await unsafe requestFrame.unsafeInvoke(on: created)
        }
        // Activation establishes the transport; a decoded-frame event separately proves pixels arrived.
        events(.connected)
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
    func startRecording(displayUniqueID: String?) async throws -> any RemoteScreenRecordingHandle {
        try await remote.startRecording(displayUniqueID: displayUniqueID)
    }
    func releaseInputs() async throws { try await input.releaseInputs() }
    func inputLocations(atWindowPoint point: CGPoint, clampingToDisplay: Bool) -> RemoteDeviceInputLocations? {
        framebuffer.inputLocations(at: contentView.convert(point, from: nil), from: contentView,
                                   clampingToDisplay: clampingToDisplay)
    }

    func stop() async throws {
        stopped = true
        displayGeometry.stop()
        events = nil
        capture.fail(CancellationError())
        await capabilityObservation.stop()
        canRecordScreen = false
        observation?.cancel()
        defer { framebuffer.removeFromSuperview() }
        var failure: (any Error)?
        do { try await disconnectNative() } catch { failure = error }
        let task = observation
        observation = nil
        await task?.value
        if let failure { throw failure }
    }

    private func finishObservation(error: (any Error)?) async {
        guard !stopped, !observationFinished else { return }
        observationFinished = true
        observationFailure = error
        observation?.cancel()
        await capabilityObservation.stop()
        displayGeometry.stop()
        var failure = error
        do { try await disconnectNative() }
        catch { failure = failure.map { RemoteDeviceScreenSession.combining($0, cleanup: error) } ?? error }
        observationFailure = failure
        capture.fail(failure ?? CLIError.unavailable("remote-screen-disconnected", "The remote screen connection ended before its screenshot arrived."))
        if let failure { events?(.failure(failure)) }
        else { events?(.disconnected) }
    }

    private func checkConnection() throws {
        if stopped { throw CancellationError() }
        if observationFinished {
            throw observationFailure ?? CLIError.unavailable("remote-screen-disconnected", "The remote screen connection ended.")
        }
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
                let value = try bindings.attributes(attributes)
                framebuffer.update(attributes: value)
                events?(.attributes(value))
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
