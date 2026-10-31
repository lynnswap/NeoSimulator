import ABIBridge
import AppKit

/// Shows an app-resize assertion's dedicated display, which only CoreDevice's media stream provides.
@MainActor
final class CoreDeviceMediaStreamTransport: RemoteScreenTransport {
    private let remote: CoreDeviceRemoteScreenDevice
    private let input: CoreDeviceScreenInput
    private let bindings: MediaStreamBindings
    private let sourceLayer = CALayer()
    private var contentsObservation: NSKeyValueObservation?
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
    private let displayUniqueID: String
    private var displayWaiter: CheckedContinuation<UInt32, any Error>?
    private var videoDisplayID: UInt32?
    var inputCapabilities: Set<RemoteDeviceInputKind> {
        framebuffer.isReady ? capabilityObservation.capabilities : capabilityObservation.capabilities.subtracting([.pointer, .digitizer])
    }
    var canCaptureScreenshot: Bool { !stopped && stream != nil }
    private(set) var canRecordScreen = false

    init(remote: CoreDeviceRemoteScreenDevice, contentView: NSView, displayUniqueID: String) throws {
        self.remote = remote
        self.contentView = contentView
        self.displayUniqueID = displayUniqueID
        let input = CoreDeviceScreenInput(remote: remote, displayUniqueID: displayUniqueID)
        self.input = input
        capabilityObservation = RemoteScreenInputCapabilityObservation(source: try CoreDeviceInputCapabilitySource(remote: remote, dedicatedDisplay: true),
            read: { try input.capabilities() }, invalidateInputs: { input.discardInputs(for: $0) })
        bindings = try MediaStreamBindings(runtime: remote.runtime)
        displayGeometry = try CoreDeviceDisplayGeometry(remote: remote, displayUniqueID: displayUniqueID)
        framebuffer.autoresizingMask = [.width, .height]
        // The native stream draws into its own layer; the framebuffer's layer applies the display geometry.
        contentsObservation = sourceLayer.observe(\.contents, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.framebuffer.withoutAnimations { self.framebuffer.video.contents = self.sourceLayer.contents }
            }
        }
    }

    func start(events: @escaping @MainActor (RemoteScreenTransportEvent) -> Void) async throws {
        try checkConnection()
        self.events = events
        try capabilityObservation.start(update: { [weak self] removed in
            self?.events?(removed.isEmpty ? .inputGeometryChanged : .inputCapabilitiesLost(removed))
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
                if let videoDisplayID, display?.identifier != videoDisplayID {
                    Task { @MainActor [weak self] in
                        await self?.finishObservation(error: CLIError.unavailable("remote-display-changed", "The dedicated display disconnected or changed identity."))
                    }
                    return
                }
                self.framebuffer.update(display: display)
                if let id = display?.identifier { self.finishDisplayWait(.success(id)) }
                self.events?(.inputGeometryChanged)
            case .failure(let error):
                self.framebuffer.update(display: nil)
                Task { @MainActor [weak self] in await self?.finishObservation(error: error) }
            }
        }
        try checkConnection()
        let identifier = try await waitForDisplay()
        videoDisplayID = identifier
        try await input.connectDisplay(identifier: identifier)
        try Task.checkCancellation()
        try checkConnection()
        let session = try unsafe bindings.makeSession.unsafeInvoke(UUID())
        self.session = session
        let configuration = try unsafe bindings.makeConfiguration.unsafeInvoke(identifier, sourceLayer, 30)
        let created = try await unsafe bindings.makeVideoStream.unsafeInvoke(on: session, configuration, remote.object).copyUnderlyingValue()
        stream = created
        try Task.checkCancellation()
        try checkConnection()
        let activate = try created.type.resolveAndWait(.swift(.method("CoreDeviceMediaStreamSupport.MediaStreamProtocol.activate()",
            as: (() async throws -> NativeSwiftValue).self, valueABIs: bindings.eventABIs)))
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
        let requestFrame = try created.type.resolveAndWait(.swift(.method("CoreDeviceMediaStreamSupport.VideoStream.requestLastDecodedFrame()",
            as: (() async -> Void).self)))
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
        let request = try stream.type.resolveAndWait(.swift(.method("CoreDeviceMediaStreamSupport.VideoStream.requestLastDecodedFrame()",
            as: (() async -> Void).self)))
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
        framebuffer.inputLocations(at: point, from: nil, clampingToDisplay: clampingToDisplay)
    }

    func stop() async throws {
        stopped = true
        finishDisplayWait(.failure(CancellationError()))
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
        finishDisplayWait(.failure(error ?? CLIError.unavailable("remote-display-ended", "The display connection ended.")))
        observation?.cancel()
        await capabilityObservation.stop()
        displayGeometry.stop()
        // A resize session must finish its recording before relinquishing this display.
        // Its session owner performs teardown after receiving this event.
        capture.fail(error ?? CLIError.unavailable("remote-screen-disconnected", "The remote screen connection ended before its screenshot arrived."))
        if let error { events?(.failure(error)) }
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
            do { try await input.stop() } catch { failure = error }
            if let stream {
                do {
                    let invalidate = try stream.type.resolveAndWait(.swift(.method("CoreDeviceMediaStreamSupport.MediaStreamProtocol.invalidate()",
                        as: (() async -> Void).self)))
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

    private func waitForDisplay() async throws -> UInt32 {
        if let identifier = framebuffer.display?.identifier { return identifier }
        let timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.finishDisplayWait(.failure(CLIError.unavailable("remote-display-timeout", "The dedicated display did not become available.")))
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { displayWaiter = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishDisplayWait(.failure(CancellationError())) }
        }
    }

    private func finishDisplayWait(_ result: Result<UInt32, any Error>) {
        let waiter = displayWaiter
        displayWaiter = nil
        waiter?.resume(with: result)
    }

    private func observe(_ sequence: NativeSwiftValue) async throws {
        let make = try sequence.type.resolveAndWait(.swift(.method("makeAsyncIterator()", as: (() -> NativeSwiftValue).self,
            valueABIs: bindings.eventABIs, receiverABI: .opaque(named: sequence.type.name))))
        let iterator = try unsafe make.unsafeInvoke(on: sequence)
        let next = try iterator.type.resolveAndWait(.swift(.method("next()", as: (() async throws -> NativeSwiftValue?).self,
            valueABIs: bindings.eventABIs, receiverABI: .opaque(named: iterator.type.name))))
        while let event = try await unsafe next.unsafeInvoke(on: iterator) {
            try Task.checkCancellation()
            guard !stopped else { return }
            if let attributes = try event.copyEnumPayloadAndWait(forCase: "remoteVideoAttributesChanged") {
                let value = try bindings.attributes(attributes)
                framebuffer.update(attributes: value)
                events?(.attributes(value))
            } else if let frame = try event.copyEnumPayloadAndWait(forCase: "receivedLastDecodedFrame") {
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
    let makeConfiguration: NativeSwiftFunction<(UInt32, CALayer, UInt) -> NativeSwiftValue>
    let makeVideoStream: NativeSwiftMethod<(NativeSwiftValue, NativeSwiftValue) async throws -> NativeSwiftValue>
    let eventABIs: [NativeSwiftType: NativeType]
    private let ratio: NativeSwiftMethod<() -> CGSize>
    private let contentsRect: NativeSwiftMethod<() -> CGRect>
    private let scaleFactor: NativeSwiftMethod<() -> Float>
    private let orientation: NativeSwiftMethod<() -> NativeSwiftValue>
    private let orientationRawValue: NativeSwiftMethod<() -> String>

    init(runtime: ABIRuntime) throws {
        try CoreDeviceRemoteScreenDevice.load("/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Frameworks/CoreDeviceMediaStreamSupport.framework/Versions/A/CoreDeviceMediaStreamSupport")
        let session = try runtime.resolveAndWait(.swift(.type("CoreDeviceMediaStreamSupport.MediaStreamSession")))
        makeSession = try session.resolveAndWait(.swift(.initializer("init(clientSessionID:)", as: ((UUID) -> NativeSwiftValue).self)))
        let configuration = try runtime.resolveAndWait(.swift(.type("CoreDeviceMediaStreamSupport.VideoStreamConfiguration")))
        makeConfiguration = try configuration.resolveAndWait(.swift(.staticMethod("receiveMirroredDisplayByIdentifier(_:layer:timeout:)",
            as: ((UInt32, CALayer, UInt) -> NativeSwiftValue).self)))
        makeVideoStream = try session.resolveAndWait(.swift(.method("makeVideoStream(withConfiguration:fromRemoteDevice:)",
            as: ((NativeSwiftValue, NativeSwiftValue) async throws -> NativeSwiftValue).self)))
        let event = try runtime.resolveAndWait(.swift(.type("CoreDeviceMediaStreamSupport.VideoStreamEvent")))
        let arguments: [NativeSwiftGenericArgument] = [.type(event), .type((any Error).self)]
        let sequence = try runtime.resolveAndWait(.swift(.type("Swift.AsyncThrowingStream", genericArguments: arguments)))
        let iterator = try runtime.resolveAndWait(.swift(.type("Swift.AsyncThrowingStream.Iterator", genericArguments: arguments)))
        // These stream/iterator declarations are non-frozen in the Swift SDK interface.
        eventABIs = try Dictionary(uniqueKeysWithValues: [event, sequence, iterator].map { ($0, try .opaque(named: $0.name)) })
        let attributes = try runtime.resolveAndWait(.swift(.type("CoreDeviceMediaStreamSupport.VideoStreamAttributes")))
        let abi = try NativeType.opaque(named: attributes.name)
        ratio = try attributes.resolveAndWait(.swift(.getter("ratio", as: (() -> CGSize).self, receiverABI: abi)))
        contentsRect = try attributes.resolveAndWait(.swift(.getter("contentsRect", as: (() -> CGRect).self, receiverABI: abi)))
        scaleFactor = try attributes.resolveAndWait(.swift(.getter("scaleFactor", as: (() -> Float).self, receiverABI: abi)))
        orientation = try attributes.resolveAndWait(.swift(.getter("orientation", as: (() -> NativeSwiftValue).self, receiverABI: abi)))
        let direction = try runtime.resolveAndWait(.swift(.type("CoreDevice.DeviceOrientation")))
        orientationRawValue = try direction.resolveAndWait(.swift(.getter("rawValue", as: (() -> String).self)))
    }

    func attributes(_ value: NativeSwiftValue) throws -> RemoteDeviceVideoAttributes {
        try unsafe RemoteDeviceVideoAttributes(aspectRatio: ratio.unsafeInvoke(on: value),
            contentsRect: contentsRect.unsafeInvoke(on: value), scaleFactor: scaleFactor.unsafeInvoke(on: value),
            orientation: RemoteDeviceOrientation(rawValue: orientationRawValue.unsafeInvoke(on: orientation.unsafeInvoke(on: value))))
    }
}
