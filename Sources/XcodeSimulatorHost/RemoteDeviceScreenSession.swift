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
    /// Root of the native input hierarchy; its focused responder handles AppKit events.
    /// Media streams use the explicit HID methods below.
    public var nativeInputView: NSView? { transport?.nativeInputView }
    public var canCaptureScreenshot: Bool { state == .connected && !isChangingDisplay && transport?.canCaptureScreenshot == true }
    public var canRecordScreen: Bool { state == .connected && !isChangingDisplay && transport?.canRecordScreen == true }
    public var recordingState: RemoteDeviceRecordingState { recording.state }
    /// The start time while a native recording is active.
    public var recordingStartDate: Date? { recording.startDate }
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
        state == .connected && !isChangingDisplay ? transport?.inputCapabilities ?? [] : []
    }
    public var onStateChange: (() -> Void)?
    /// Drains input already accepted by the presentation's existing queue.
    @_spi(NeoSimulator) public var prepareForDisplayChange: (() async -> Void)?
    /// Called when native HID services disappear. Geometry readiness changes do not invoke this callback.
    public var onInputCapabilitiesLost: ((Set<RemoteDeviceInputKind>) -> Void)?

    private let makeTransport: @MainActor (CoreDeviceDevice, NSView, String?) async throws -> any RemoteScreenTransport
    private let makeResizeTransport: @MainActor (CoreDeviceDevice) async throws -> (any AppResizeTransport)?
    private var transport: (any RemoteScreenTransport)?
    private var starting: Task<Void, any Error>?
    private var stopping: Task<Void, any Error>?
    private var generation = 0
    private let recording = RemoteScreenRecording()
    private var resizeTransport: (any AppResizeTransport)?
    private var resizeSession: (any AppResizeSession)?
    private var resizeEligibility = AppResizeEligibility.unavailable
    private var resizeEligibilityTask: Task<Void, Never>?
    private var resizeUpdates: Task<Void, Never>?
    private var resizeInvalidation: Task<Void, Never>?
    private var resizeOperation: Task<Void, any Error>?
    private var resizeAdjustment: Task<Void, Never>?
    private var pendingAppSize: CGSize?
    private var frameWaiter: CheckedContinuation<Void, any Error>?
    private var frameWaitIdentifier: UUID?
    private var capturesInFlight = 0
    private var captureWaiters: [CheckedContinuation<Void, Never>] = []
    @_spi(NeoSimulator) public private(set) var isChangingDisplay = false
    @_spi(NeoSimulator) public var supportsAppResize: Bool { resizeTransport != nil || resizeSession != nil }
    @_spi(NeoSimulator) public var isResizingApp: Bool { resizeSession != nil }
    @_spi(NeoSimulator) public private(set) var appResizeGeometry: AppResizeGeometry?
    @_spi(NeoSimulator) public var canResizeApp: Bool {
        !isChangingDisplay && !hasUnfinishedRecording
            && (resizeSession != nil || state == .connected && resizeEligibility == .eligible)
    }

    public convenience init(device: CoreDeviceDevice) {
        self.init(device: device, makeResizeTransport: CoreDeviceScreenTransport.resizeTransport,
                  makeTransport: CoreDeviceScreenTransport.make)
    }

    init(device: CoreDeviceDevice,
         makeResizeTransport: @escaping @MainActor (CoreDeviceDevice) async throws -> (any AppResizeTransport)? = { _ in nil },
         makeTransport: @escaping @MainActor (CoreDeviceDevice, NSView, String?) async throws -> any RemoteScreenTransport) {
        self.device = device
        self.makeTransport = makeTransport
        self.makeResizeTransport = makeResizeTransport
        contentView = NSView(frame: .zero)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.black.cgColor
        recording.onChange = { [weak self] in self?.onStateChange?() }
    }

    isolated deinit {
        starting?.cancel()
        resizeOperation?.cancel()
        resizeAdjustment?.cancel()
        resizeEligibilityTask?.cancel()
        resizeUpdates?.cancel()
        resizeInvalidation?.cancel()
        let resizeSession = resizeSession
        let transport = transport
        let recording = recording
        Task { @MainActor in
            do {
                _ = try await recording.stop()
                try await transport?.stop()
                try resizeSession?.invalidate()
            }
            catch { NSLog("NeoSimulator remote screen cleanup failed: %@", String(describing: error)) }
        }
    }

    public func start() async throws {
        if let stopping { try await stopping.value }
        if let starting { try await starting.value; return }
        if state == .connected { return }
        if transport != nil || resizeSession != nil { try await stop() }
        generation += 1
        let token = generation
        lastError = nil
        hasReceivedFrame = false
        state = .connecting
        onStateChange?()
        let task = Task { [self] in
            let transport = try await makeTransport(device, contentView, nil)
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
                do {
                    resizeTransport = try await makeResizeTransport(device)
                    try Task.checkCancellation()
                    guard generation == token else { throw CancellationError() }
                    if let resizeTransport { try await observeResizability(resizeTransport) }
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    resizeTransport = nil
                    resizeEligibility = .unavailable
                    lastError = error
                }
                try Task.checkCancellation()
                guard generation == token else { throw CancellationError() }
                onStateChange?()
            } catch {
                do {
                    try await transport.stop()
                    if self.transport === transport { self.transport = nil }
                }
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
        let beginning = starting
        beginning?.cancel()
        let resizing = resizeOperation
        resizing?.cancel()
        finishFrameWait(.failure(CancellationError()))
        resizeEligibilityTask?.cancel()
        resizeEligibilityTask = nil
        state = .stopping
        onStateChange?()
        let task = Task { [self] in
            await finishResizeAdjustment()
            _ = try await recording.stop()
            await waitForCaptures()
            var failure: (any Error)?
            var cancellation: (any Error)?
            var failedTransport: (any RemoteScreenTransport)?
            if let transport {
                do { try await transport.stop(); self.transport = nil }
                catch { failure = error; failedTransport = transport }
            }
            do { try await resizing?.value }
            catch {
                if error is CancellationError {
                    if cancellation == nil {
                        cancellation = error
                        if let cleanup = failure { failure = Self.combining(error, cleanup: cleanup) }
                    }
                } else { failure = failure.map { Self.combining(error, cleanup: $0) } ?? error }
            }
            do { try await beginning?.value }
            catch {
                if error is CancellationError {
                    if cancellation == nil {
                        cancellation = error
                        if let cleanup = failure { failure = Self.combining(error, cleanup: cleanup) }
                    }
                } else { failure = failure.map { Self.combining(error, cleanup: $0) } ?? error }
            }
            // A cancellation recovery can return a new transport after the first stop.
            generation += 1
            if let transport, transport !== failedTransport {
                do { try await transport.stop(); self.transport = nil }
                catch { failure = (failure ?? cancellation).map { Self.combining($0, cleanup: error) } ?? error }
            }
            if transport == nil {
                do { try endResizeAssertion() }
                catch { failure = (failure ?? cancellation).map { Self.combining($0, cleanup: error) } ?? error }
            }
            if let failure { throw failure }
        }
        stopping = task
        defer { stopping = nil }
        do {
            try await task.value
            resizeTransport = nil
            resizeEligibility = .unavailable
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
        guard state == .connected, !isChangingDisplay, let transport else {
            throw CLIError.unavailable("remote-screen-connection", "Connect the device screen before capturing it.")
        }
        capturesInFlight += 1
        defer {
            capturesInFlight -= 1
            if capturesInFlight == 0 {
                let waiters = captureWaiters
                captureWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        return try await transport.captureScreenshot()
    }

    /// Starts native recording with CoreDevice's default codec and mask policy.
    /// A nil identifier selects the active resize display, or CoreDevice's primary display.
    public func startRecording(displayUniqueID: String? = nil) async throws {
        guard state == .connected, !isChangingDisplay, let transport else {
            throw CLIError.unavailable("remote-screen-connection", "Connect the device screen before recording it.")
        }
        if let active = resizeSession?.displayUniqueID, let displayUniqueID, displayUniqueID != active {
            throw CLIError.configuration("remote-recording-display", "A recording must use the active app display.")
        }
        let identifier = displayUniqueID ?? resizeSession?.displayUniqueID
        try await recording.start { try await transport.startRecording(displayUniqueID: identifier) }
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
        guard state == .connected, !isChangingDisplay else { return nil }
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
        guard state == .connected, !isChangingDisplay, let transport else {
            throw CLIError.unavailable("remote-screen-connection", "Connect the device screen before sending input.")
        }
        try await transport.send(input)
    }

    private func receive(_ event: RemoteScreenTransportEvent) {
        switch event {
        case .connected: state = .connected
        case .attributes(let attributes):
            videoAttributes = attributes
            if hasReceivedFrame { finishFrameWait(.success(())) }
        case .frameReceived:
            hasReceivedFrame = true
            if videoAttributes != nil { finishFrameWait(.success(())) }
        case .failure(let error):
            lastError = error
            state = .failed
            finishFrameWait(.failure(error))
            if resizeSession != nil, !isChangingDisplay { returnFromInvalidatedDisplay() }
        case .disconnected:
            state = .stopped
            finishFrameWait(.failure(CLIError.unavailable("remote-display-ended", "The display connection ended.")))
            if resizeSession != nil, !isChangingDisplay { returnFromInvalidatedDisplay() }
        case .inputGeometryChanged: break
        case .inputCapabilitiesLost(let kinds): onInputCapabilitiesLost?(kinds)
        }
        onStateChange?()
    }

    private func observeResizability(_ source: any AppResizeTransport) async throws {
        let stream = try await source.eligibility()
        resizeEligibilityTask = Task { [weak self] in
            do {
                for try await eligibility in stream {
                    guard !Task.isCancelled, let self else { return }
                    self.resizeEligibility = eligibility
                    self.onStateChange?()
                }
                try Task.checkCancellation()
                throw CLIError.unavailable("app-resize-observation", "App resize observation ended.")
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.resizeTransport = nil
                self.resizeEligibility = .unavailable
                self.lastError = error
                if self.resizeSession != nil { self.returnFromInvalidatedDisplay() }
                self.onStateChange?()
            }
        }
    }

    /// Replaces the primary transport with the resize assertion's display. Accepted captures
    /// finish first; active or failed-stop recordings must be explicitly finished by the caller.
    @_spi(NeoSimulator)
    public func startAppResize(size: CGSize, cornerRadius: CGFloat = 0) async throws {
        guard canResizeApp, resizeSession == nil, let resizeTransport else {
            throw CLIError.unavailable("app-resize", "The foreground app is not currently available for resizing.")
        }
        try await changeDisplay { [self] in
            try await retireTransport()
            do {
                let assertion = try await resizeTransport.start(size: size, cornerRadius: cornerRadius)
                resizeSession = assertion
                appResizeGeometry = assertion.geometry
                try Task.checkCancellation()
                try observeResize(assertion)
                try await connectDisplay(assertion.displayUniqueID, waitForFrame: true)
            } catch {
                let original = error
                do {
                    try await retireTransport()
                    try endResizeAssertion()
                    // Disconnection owns restoration once it cancels this operation.
                    if stopping == nil {
                        try await Task { @MainActor [self] in try await connectDisplay(nil, waitForFrame: false) }.value
                    }
                } catch {
                    if stopping != nil, error is CancellationError { throw original }
                    throw Self.combining(original, cleanup: error)
                }
                throw original
            }
        }
    }

    /// Ends resizing and reconnects primary. A failed teardown retains its resources for retry.
    @_spi(NeoSimulator)
    public func stopAppResize() async throws {
        guard canResizeApp, resizeSession != nil else {
            throw CLIError.unavailable("app-resize", "Finish recording before changing the app display.")
        }
        try await changeDisplay { [self] in try await restorePrimary(finalizeRecording: false) }
    }

    /// Requests native point geometry, keeping only the latest pending size. Accepted
    /// geometry comes from appResizeGeometry; adjustment errors are reported in lastError.
    @_spi(NeoSimulator)
    public func resizeApp(to size: CGSize) {
        guard state == .connected, !isChangingDisplay, let assertion = resizeSession, let geometry = appResizeGeometry,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        pendingAppSize = CGSize(width: min(geometry.maximumSize.width, max(geometry.minimumSize.width, size.width)),
                                height: min(geometry.maximumSize.height, max(geometry.minimumSize.height, size.height)))
        guard resizeAdjustment == nil else { return }
        resizeAdjustment = Task { [weak self] in
            defer { if let self, self.resizeSession === assertion { self.resizeAdjustment = nil } }
            do {
                while !Task.isCancelled, let self, self.resizeSession === assertion,
                      let size = self.pendingAppSize, let geometry = self.appResizeGeometry {
                    self.pendingAppSize = nil
                    try await assertion.adjust(size: size, cornerRadius: geometry.cornerRadius)
                    try Task.checkCancellation()
                }
            } catch {
                guard !Task.isCancelled, let self, self.resizeSession === assertion else { return }
                self.pendingAppSize = nil
                self.lastError = error
                self.onStateChange?()
            }
        }
    }

    private func finishResizeAdjustment() async {
        pendingAppSize = nil
        let adjustment = resizeAdjustment
        adjustment?.cancel()
        await adjustment?.value
        resizeAdjustment = nil
    }

    private func changeDisplay(_ operation: @escaping @MainActor () async throws -> Void) async throws {
        guard resizeOperation == nil else { throw CLIError.unavailable("app-resize", "The display is already changing.") }
        isChangingDisplay = true
        lastError = nil
        onInputCapabilitiesLost?([.keyboard, .pointer, .digitizer, .button])
        onStateChange?()
        let task = Task { [self] in
            await finishResizeAdjustment()
            await prepareForDisplayChange?()
            try Task.checkCancellation()
            try await operation()
        }
        resizeOperation = task
        defer { resizeOperation = nil; isChangingDisplay = false; onStateChange?() }
        do { try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch {
            lastError = error is CancellationError ? nil : error
            if state != .connected || resizeSession != nil { state = .failed }
            onStateChange?()
            throw error
        }
    }

    private func retireTransport() async throws {
        await waitForCaptures()
        generation += 1
        state = .connecting
        videoAttributes = nil
        hasReceivedFrame = false
        onStateChange?()
        finishFrameWait(.failure(CancellationError()))
        if let transport {
            try await transport.releaseInputs()
            try await transport.stop()
            self.transport = nil
        }
    }

    private func connectDisplay(_ identifier: String?, waitForFrame: Bool) async throws {
        generation += 1
        let token = generation
        let connection = try await makeTransport(device, contentView, identifier)
        transport = connection
        try Task.checkCancellation()
        guard generation == token, stopping == nil else { throw CancellationError() }
        try await connection.start { [weak self] event in
            guard let self, self.generation == token, self.stopping == nil else { return }
            self.receive(event)
        }
        try Task.checkCancellation()
        guard generation == token, stopping == nil else { throw CancellationError() }
        if waitForFrame { try await waitForFirstFrame() }
        guard generation == token, stopping == nil else { throw CancellationError() }
        guard state == .connected else {
            throw lastError ?? CLIError.unavailable("remote-display-ended", "The display connection ended while connecting.")
        }
    }

    private func observeResize(_ assertion: any AppResizeSession) throws {
        let stream = try assertion.updates()
        resizeUpdates = Task { [weak self, weak assertion] in
            do {
                for try await geometry in stream {
                    guard !Task.isCancelled, let self, self.resizeSession === assertion else { return }
                    self.appResizeGeometry = geometry
                    self.onStateChange?()
                }
            } catch {
                guard !Task.isCancelled, let self, self.resizeSession === assertion else { return }
                self.lastError = error
                self.returnFromInvalidatedDisplay()
            }
        }
        resizeInvalidation = Task { [weak self, weak assertion] in
            guard let assertion else { return }
            do { try await assertion.awaitInvalidation() }
            catch {
                guard !Task.isCancelled, let self, self.resizeSession === assertion else { return }
                self.lastError = error
            }
            guard !Task.isCancelled, let self, self.resizeSession === assertion else { return }
            self.returnFromInvalidatedDisplay()
        }
    }

    private func returnFromInvalidatedDisplay() {
        if let resizeOperation {
            resizeOperation.cancel()
            finishFrameWait(.failure(CLIError.unavailable("app-resize-ended", "The app resize session ended.")))
            return
        }
        let cause = lastError
        Task { [weak self] in
            guard let self, self.resizeSession != nil, self.stopping == nil, self.resizeOperation == nil else { return }
            do {
                try await self.changeDisplay { [self] in try await restorePrimary(finalizeRecording: true) }
                self.lastError = cause
                self.onStateChange?()
            } catch {
                self.lastError = cause.map { Self.combining($0, cleanup: error) } ?? error
                self.state = .failed
                self.onStateChange?()
            }
        }
    }

    private func restorePrimary(finalizeRecording: Bool) async throws {
        if finalizeRecording { _ = try await recording.stop() }
        try await retireTransport()
        try endResizeAssertion()
        try Task.checkCancellation()
        try await connectDisplay(nil, waitForFrame: false)
    }

    private func endResizeAssertion() throws {
        resizeUpdates?.cancel()
        resizeUpdates = nil
        resizeInvalidation?.cancel()
        resizeInvalidation = nil
        try resizeSession?.invalidate()
        resizeSession = nil
        appResizeGeometry = nil
    }

    private func waitForCaptures() async {
        if capturesInFlight != 0 { await withCheckedContinuation { captureWaiters.append($0) } }
    }

    private func waitForFirstFrame() async throws {
        guard state == .connected else {
            throw lastError ?? CLIError.unavailable("remote-display-ended", "The display connection ended before its first frame.")
        }
        if hasReceivedFrame, videoAttributes != nil { return }
        let identifier = UUID()
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.finishFrameWait(.failure(CLIError.unavailable("remote-display-frame", "The app display did not provide a decoded frame.")), identifier: identifier)
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                frameWaitIdentifier = identifier
                frameWaiter = $0
            }
        } onCancel: { Task { @MainActor [weak self] in self?.finishFrameWait(.failure(CancellationError()), identifier: identifier) } }
    }

    private func finishFrameWait(_ result: Result<Void, any Error>, identifier: UUID? = nil) {
        if let identifier, frameWaitIdentifier != identifier { return }
        let waiter = frameWaiter
        frameWaiter = nil
        frameWaitIdentifier = nil
        waiter?.resume(with: result)
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
    case inputCapabilitiesLost(Set<RemoteDeviceInputKind>)
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
