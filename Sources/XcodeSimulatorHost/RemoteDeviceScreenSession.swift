import AppKit

public enum RemoteDeviceInputKind: Hashable, Sendable { case keyboard, pointer, digitizer, button }
public enum RemoteDeviceButtonState: String, Sendable { case down, up }
public enum RemoteDevicePointerPhase: String, Sendable { case down, up, dragged }
public enum RemoteDeviceTouchPhase: String, Sendable { case began, moved, ended }
public enum RemoteDeviceTouchEdge: String, Sendable { case none, top, left, right, bottom }

public enum RemoteDeviceOrientation: String, Sendable {
    case unknown, portrait, portraitUpsideDown, landscapeLeft, landscapeRight, faceUp, faceDown
}

public struct RemoteDeviceVideoAttributes: Equatable, Sendable {
    public let aspectRatio: CGSize
    public let contentsRect: CGRect
    public let scaleFactor: Float
    public let orientation: RemoteDeviceOrientation?
}

/// Owns one CoreDevice screen connection and its input resources on the main actor.
@MainActor
public final class RemoteDeviceScreenSession {
    public enum State: Equatable, Sendable { case idle, connecting, connected, stopping, stopped, failed }

    public let device: CoreDeviceDevice
    public var deviceID: DeviceInventoryID { .coreDevice(device.identifier) }
    public let contentView: NSView
    /// ScreenSharing handles AppKit events in this view; media streams use the explicit HID methods below.
    public var nativeInputView: NSView? { transport?.nativeInputView }
    public var canCaptureScreenshot: Bool { state == .connected && transport?.canCaptureScreenshot == true }
    public var canRecordScreen: Bool { state == .connected && transport?.canRecordScreen == true }
    public var recordingState: RemoteDeviceRecordingState { recording.state }
    /// True while starting, stopping, or retaining a handle after a failed stop.
    public var hasUnfinishedRecording: Bool { recording.hasUnfinishedRecording }
    /// Retained until explicitly discarded, including after a save failure or screen shutdown.
    public var completedRecording: RemoteDeviceRecording? { recording.completed }
    public var recordingError: (any Error)? { recording.lastError }
    public private(set) var state = State.idle
    public private(set) var lastError: (any Error)?
    public private(set) var videoAttributes: RemoteDeviceVideoAttributes?
    public private(set) var hasReceivedFrame = false
    public var inputCapabilities: Set<RemoteDeviceInputKind> {
        state == .connected ? transport?.inputCapabilities ?? [] : []
    }
    public var onStateChange: (() -> Void)?

    private let makeTransport: @MainActor (CoreDeviceDevice, NSView) async throws -> any RemoteScreenTransport
    private var transport: (any RemoteScreenTransport)?
    private var starting: Task<Void, any Error>?
    private var stopping: Task<Void, any Error>?
    private var generation = 0
    private let recording = RemoteScreenRecording()

    public convenience init(device: CoreDeviceDevice) {
        self.init(device: device, makeTransport: CoreDeviceScreenTransport.make)
    }

    init(device: CoreDeviceDevice,
         makeTransport: @escaping @MainActor (CoreDeviceDevice, NSView) async throws -> any RemoteScreenTransport) {
        self.device = device
        self.makeTransport = makeTransport
        contentView = NSView(frame: .zero)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        recording.onChange = { [weak self] in self?.onStateChange?() }
    }

    isolated deinit {
        starting?.cancel()
        let transport = transport
        let recording = recording
        Task { @MainActor in
            do {
                _ = try await recording.stop()
                try await transport?.stop()
            }
            catch { NSLog("NeoSimulator remote screen cleanup failed: %@", String(describing: error)) }
        }
    }

    public func start() async throws {
        if let stopping { try await stopping.value }
        if let starting { try await starting.value; return }
        if state == .connected { return }
        if transport != nil { try await stop() }
        generation += 1
        let token = generation
        lastError = nil
        hasReceivedFrame = false
        state = .connecting
        onStateChange?()
        let task = Task { [self] in
            let transport = try await makeTransport(device, contentView)
            do {
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                self.transport = transport
                onStateChange?()
                try await transport.start { [weak self] event in
                    guard let self, self.generation == token else { return }
                    self.receive(event)
                }
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                onStateChange?()
            } catch {
                do { try await transport.stop() }
                catch let cleanup { throw Self.combining(error, cleanup: cleanup) }
                throw error
            }
        }
        starting = task
        defer { starting = nil }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        }
        catch {
            if generation == token {
                state = error is CancellationError ? .stopped : .failed
                lastError = error is CancellationError ? nil : error
                onStateChange?()
            }
            throw error
        }
    }

    public func stop() async throws {
        if let stopping { try await stopping.value; return }
        generation += 1
        starting?.cancel()
        state = .stopping
        onStateChange?()
        let task = Task { [self] in
            _ = try await recording.stop()
            var failure: (any Error)?
            if let transport {
                do { try await transport.stop(); self.transport = nil }
                catch { failure = error }
            }
            do { try await starting?.value }
            catch {
                if !(error is CancellationError) {
                    failure = failure.map { Self.combining(error, cleanup: $0) } ?? error
                }
            }
            if let failure { throw failure }
        }
        stopping = task
        defer { stopping = nil }
        do {
            try await task.value
            state = .stopped
            onStateChange?()
        } catch {
            lastError = error
            state = .failed
            onStateChange?()
            throw error
        }
    }

    /// Returns pixels copied from the remote screen, without rendering the local view hierarchy.
    public func captureScreenshot() async throws -> CGImage {
        guard state == .connected, let transport else {
            throw CLIError.unavailable("remote-screen-connection", "Connect the device screen before capturing it.")
        }
        return try await transport.captureScreenshot()
    }

    /// Starts native recording with CoreDevice's default codec and mask policy.
    /// A nil display identifier delegates display selection to CoreDevice.
    public func startRecording(displayUniqueID: String? = nil) async throws {
        guard state == .connected, let transport else {
            throw CLIError.unavailable("remote-screen-connection", "Connect the device screen before recording it.")
        }
        try await recording.start { try await transport.startRecording(displayUniqueID: displayUniqueID) }
    }

    /// Finishes an active or pending recording. The returned data remains available in
    /// completedRecording until the caller saves it or explicitly discards it.
    @discardableResult
    public func stopRecording() async throws -> RemoteDeviceRecording? { try await recording.stop() }

    /// Releases the retained completed recording after saving or an explicit discard.
    public func discardCompletedRecording() { recording.discardCompleted() }

    /// Releases inputs owned by this connection without disconnecting its screen.
    public func releaseInputs() async throws {
        try await transport?.releaseInputs()
    }

    /// Converts an AppKit window location to the screen's unit input coordinates.
    /// Returns nil before display geometry arrives or outside the display. Clamp an ongoing drag's
    /// final location to the display so its matching release can still be delivered.
    public func inputLocations(atWindowPoint point: CGPoint,
                               clampingToDisplay: Bool = false) -> RemoteDeviceInputLocations? {
        guard state == .connected else { return nil }
        return transport?.inputLocations(atWindowPoint: point, clampingToDisplay: clampingToDisplay)
    }

    public func sendKey(_ usage: UInt16, state: RemoteDeviceButtonState) async throws {
        try await send(.key(usage, state))
    }

    public func movePointer(to point: CGPoint) async throws { try await send(.pointer(point)) }

    public func sendPointerButton(_ button: Int, phase: RemoteDevicePointerPhase, clicks: Int = 1,
                                  at point: CGPoint) async throws {
        try await send(.pointerButton(button, phase, clicks, point))
    }

    public func sendTouch(at point: CGPoint, secondPoint: CGPoint? = nil,
                          phase: RemoteDeviceTouchPhase, edge: RemoteDeviceTouchEdge = .none) async throws {
        try await send(.touch(point, secondPoint, phase, edge))
    }

    public func sendButton(usagePage: Int, usage: Int, state: RemoteDeviceButtonState) async throws {
        try await send(.button(usagePage, usage, state))
    }

    private func send(_ input: RemoteScreenInput) async throws {
        guard state == .connected, let transport else {
            throw CLIError.unavailable("remote-screen-connection", "Connect the device screen before sending input.")
        }
        try await transport.send(input)
    }

    private func receive(_ event: RemoteScreenTransportEvent) {
        switch event {
        case .connected: state = .connected
        case .attributes(let attributes): videoAttributes = attributes
        case .frameReceived: hasReceivedFrame = true
        case .failure(let error): lastError = error; state = .failed
        case .disconnected: state = .stopped
        case .inputGeometryChanged: break
        }
        onStateChange?()
    }

    static func combining(_ error: any Error, cleanup: any Error) -> CLIError {
        .io("remote-screen-cleanup", "\(error.localizedDescription) Disconnecting the screen also failed: \(cleanup.localizedDescription)")
    }
}

enum RemoteScreenInput: Sendable {
    case key(UInt16, RemoteDeviceButtonState)
    case pointer(CGPoint)
    case pointerButton(Int, RemoteDevicePointerPhase, Int, CGPoint)
    case touch(CGPoint, CGPoint?, RemoteDeviceTouchPhase, RemoteDeviceTouchEdge)
    case button(Int, Int, RemoteDeviceButtonState)
}

enum RemoteScreenTransportEvent {
    case connected, disconnected, frameReceived
    case inputGeometryChanged
    case attributes(RemoteDeviceVideoAttributes)
    case failure(any Error)
}

@MainActor
protocol RemoteScreenTransport: AnyObject {
    var inputCapabilities: Set<RemoteDeviceInputKind> { get }
    var nativeInputView: NSView? { get }
    var canCaptureScreenshot: Bool { get }
    var canRecordScreen: Bool { get }
    func inputLocations(atWindowPoint point: CGPoint, clampingToDisplay: Bool) -> RemoteDeviceInputLocations?
    func captureScreenshot() async throws -> CGImage
    func startRecording(displayUniqueID: String?) async throws -> any RemoteScreenRecordingHandle
    func start(events: @escaping @MainActor (RemoteScreenTransportEvent) -> Void) async throws
    func send(_ input: RemoteScreenInput) async throws
    func releaseInputs() async throws
    func stop() async throws
}

extension RemoteScreenTransport {
    var nativeInputView: NSView? { nil }
    var canCaptureScreenshot: Bool { false }
    var canRecordScreen: Bool { false }
    func startRecording(displayUniqueID: String?) async throws -> any RemoteScreenRecordingHandle {
        throw CLIError.unavailable("remote-screen-recording", "This device does not currently provide screen recording.")
    }
    func inputLocations(atWindowPoint point: CGPoint, clampingToDisplay: Bool) -> RemoteDeviceInputLocations? { nil }
    func captureScreenshot() async throws -> CGImage {
        throw CLIError.unavailable("remote-screen-capture", "This screen connection does not provide screenshot capture.")
    }
}
