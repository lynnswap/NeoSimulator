import AppKit
import Observation

/// Device properties Simulator.app uses to show, hide, or enable commands.
struct DeviceCapabilities {
    /// `SimDeviceType.productFamilyID`.
    enum Family: Int { case iPhone = 1, iPad = 2, tv = 3, watch = 4, vision = 7 }

    var family: Family?
    /// `SimRuntime.version`, packed as major << 16 | minor << 8 | patch.
    var runtimeVersion: UInt32
    /// `SimDevice supportsFeature:`, which combines device-type and runtime support.
    var supportsFeature: (String) -> Bool

    var isPhoneOrPad: Bool { family == .iPhone || family == .iPad }

    static let displayRotation = "com.apple.CoreSimulator.display.rotation"
    static let actionButtonSting = "com.apple.hid.sting"
    static let actionButtonStaccato = "com.apple.hid.staccato"
    static let siri = "com.apple.siri"
    static let routableAudio = "com.apple.CoreSimulator.audio.routable"
    static let applePayAuthorization = "com.apple.hid.applepay.authorize"
}

/// How Simulator.app times the events of a hardware input.
enum HardwareInput {
    /// Pressed and released at once.
    case press(HIDInput)
    /// Pressed, then released after a delay.
    case hold(HIDInput, for: Duration)
    /// Pressed and released twice, the second time after a delay.
    case pressTwice(HIDInput, interval: Duration)
}

/// One connected simulator: its display and input, its device tools, and every
/// operation that changes the device. Window controllers present a session and
/// report its failures; they do not run device work themselves.
@MainActor @Observable
final class DeviceSession {
    let device: AvailableDevice
    let capabilities: DeviceCapabilities
    @ObservationIgnored let display: any SimulatorDisplay
    @ObservationIgnored let tools: DeviceTools
    @ObservationIgnored private let recordings: RecordingStore
    @ObservationIgnored private let makeRecordingProcess: (URL) -> Process
    @ObservationIgnored private var operation: Task<Void, Never>?
    /// The delayed steps of hardware inputs, which a disconnect cancels.
    @ObservationIgnored private var inputSteps: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextInputStep = 0
    /// How many holds of each input are still pending. HID button state is
    /// not counted, so overlapping holds keep the input down until the last ends.
    @ObservationIgnored private var heldInputs: [HIDInput: Int] = [:]
    @ObservationIgnored private var isDisconnected = false
    /// A tool operation or a modal step that leads to one is in progress.
    private(set) var isBusy = false
    private(set) var isConnected = true
    private(set) var recording: VideoRecording?

    /// - Parameter recordingProcess: Creates the recording process for a
    ///   destination. Defaults to the device's direct `simctl` recorder.
    init(device: AvailableDevice, capabilities: DeviceCapabilities, display: any SimulatorDisplay,
         tools: DeviceTools, recordings: RecordingStore = RecordingStore(),
         recordingProcess: ((URL) -> Process)? = nil) {
        self.device = device
        self.capabilities = capabilities
        self.display = display
        self.tools = tools
        self.recordings = recordings
        makeRecordingProcess = recordingProcess ?? tools.recordingProcess(to:)
    }

    var canPerformCommands: Bool { isConnected && display.isBooted }
    var canPerformToolOperation: Bool { canPerformCommands && !isBusy }

    // MARK: Immediate device input

    /// Sends a hardware input. The first failure of its events, including a
    /// delivery failure SimulatorKit reports later, goes to `failure`.
    func send(_ input: HardwareInput, failure: @escaping @MainActor (Error) -> Void) {
        guard canPerformCommands else { return }
        let report = FirstFailure(failure)
        switch input {
        case .press(let event):
            press(event, report)
        case .hold(let event, let delay):
            guard let (down, up) = messages(event, report), send(down, report) else { return }
            heldInputs[event, default: 0] += 1
            after(delay) { session in session.release(event, up, report) }
        case .pressTwice(let event, let interval):
            guard press(event, report) else { return }
            after(interval) { session in session.press(event, report) }
        }
    }

    /// Presses and releases an input, and returns whether both events were sent.
    @discardableResult
    private func press(_ event: HIDInput, _ report: FirstFailure) -> Bool {
        guard canPerformCommands, let (down, up) = messages(event, report), send(down, report) else { return false }
        // If the release is not sent or not delivered, the input stays down
        // and closing the window releases it.
        let undelivered: @MainActor () -> Void = { [weak self] in self?.heldInputs[event, default: 0] += 1 }
        guard send(up, report, undelivered: undelivered) else {
            undelivered()
            return false
        }
        return true
    }

    // Both events are created before either is sent, so that a failure cannot
    // leave the input down.
    private func messages(_ event: HIDInput, _ report: FirstFailure) -> (down: HIDMessage, up: HIDMessage)? {
        do {
            return (try display.message(for: event, .down), try display.message(for: event, .up))
        } catch {
            report(error)
            return nil
        }
    }

    /// Sends a message and returns whether it was sent. `undelivered` runs when
    /// SimulatorKit later reports that delivery failed.
    private func send(_ message: HIDMessage, _ report: FirstFailure,
                      undelivered: @escaping @MainActor () -> Void = {}) -> Bool {
        do {
            try display.send(message) { error in
                guard let error else { return }
                undelivered()
                report(error)
            }
            return true
        } catch {
            report(error)
            return false
        }
    }

    // A held input is released while the device is booted, even when a
    // shutdown in progress makes other commands unavailable: the shutdown can
    // fail and leave the device running. The input stays tracked until its
    // release is sent, so that closing the window can still release it.
    private func release(_ event: HIDInput, _ up: HIDMessage, _ report: FirstFailure) {
        guard let count = heldInputs[event] else { return }
        // HID button state is not counted: the last overlapping hold releases.
        guard count == 1 else {
            heldInputs[event] = count - 1
            return
        }
        guard !isDisconnected, display.isBooted else {
            heldInputs[event] = nil
            return
        }
        heldInputs[event] = nil
        let undelivered: @MainActor () -> Void = { [weak self] in self?.heldInputs[event, default: 0] += 1 }
        if !send(up, report, undelivered: undelivered) { undelivered() }
    }

    private func after(_ delay: Duration, _ step: @escaping @MainActor (DeviceSession) -> Void) {
        let id = nextInputStep
        nextInputStep += 1
        inputSteps[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.inputSteps[id] = nil
            step(self)
        }
    }

    func shake() throws {
        guard canPerformCommands else { return }
        try display.shake()
    }

    func toggleAppearance() throws {
        guard canPerformCommands else { return }
        try display.toggleAppearance()
    }

    // MARK: Device tool operations

    /// Holds the single device-operation slot for a modal step, such as a save
    /// panel, that precedes a tool operation. Returns false when it is taken.
    func reserve() -> Bool {
        guard canPerformToolOperation else { return false }
        isBusy = true
        return true
    }

    func release() {
        guard operation == nil else { return }
        isBusy = false
    }

    /// Runs one device tool operation at a time. The caller must hold no
    /// reservation. Errors other than cancellation are passed to `failure`.
    func run(_ body: @escaping @MainActor () async throws -> Void,
             failure: @escaping @MainActor (Error) -> Void) {
        guard canPerformToolOperation else { return }
        isBusy = true
        operation = Task { [weak self] in
            defer {
                if let self {
                    self.operation = nil
                    self.isBusy = false
                    // A failed shutdown leaves a booted device usable again.
                    self.isConnected = !self.isDisconnected && self.display.isBooted
                }
            }
            do { try await body() }
            catch is CancellationError {}
            catch { failure(error) }
        }
    }

    /// Reads the device orientation and returns the display angle in degrees.
    func readOrientation() async throws -> Double {
        let angle = try await tools.orientation()
        try Task.checkCancellation()
        display.setRotation(degrees: angle)
        return angle
    }

    func rotate(left: Bool) async throws {
        let angle = try await tools.rotate(left: left)
        try Task.checkCancellation()
        display.setRotation(degrees: angle)
    }

    func saveScreenshot(to destination: URL) async throws {
        try await CaptureFile.write(to: destination, extension: "png") { temporary in
            try await tools.screenshot(to: temporary)
            let handle = try FileHandle(forReadingFrom: temporary)
            defer { try? handle.close() }
            guard try handle.read(upToCount: 8) == Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else {
                throw HostError.operation("The screenshot tool did not produce a PNG file")
            }
        }
    }

    func startRecording(to destination: URL) throws {
        guard canPerformCommands, recording == nil else { return }
        recording = try recordings.start(to: destination, process: makeRecordingProcess) { [weak self] in
            self?.recording = nil
        }
    }

    func stopRecording() { recording?.stop() }

    func importFiles(_ urls: [URL]) async throws {
        try await SimulatorFileImport.perform(urls) { url, kind in
            switch kind {
            case .application: try await tools.installApplication(at: url)
            case .media: try await tools.importMedia(at: url)
            }
        }
    }

    func openURL(_ url: URL) async throws { try await tools.openURL(url) }

    func shutDown() async throws {
        isConnected = false
        try await tools.shutdown()
    }

    // MARK: Lifetime

    func disconnect() {
        guard !isDisconnected else { return }
        // Release held inputs while the input client can still send.
        for event in heldInputs.keys {
            if let up = try? display.message(for: event, .up) { try? display.send(up, completion: nil) }
        }
        heldInputs.removeAll()
        inputSteps.values.forEach { $0.cancel() }
        inputSteps.removeAll()
        isDisconnected = true
        isConnected = false
        operation?.cancel()
        tools.cancel()
        recording?.stop()
        display.disconnect()
    }

    isolated deinit { disconnect() }
}

/// Forwards only the first failure of an input whose events fail together.
@MainActor
private final class FirstFailure {
    private var failure: ((Error) -> Void)?
    init(_ failure: @escaping @MainActor (Error) -> Void) { self.failure = failure }
    func callAsFunction(_ error: Error) {
        failure?(error)
        failure = nil
    }
}
