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

/// Preferences Simulator.app keeps in its standard user defaults.
enum HostPreferences {
    /// Device ▸ Rotate Device Automatically. SimulatorKit reads this key from
    /// the host's standard defaults and rotates the display when the guest
    /// changes its interface orientation.
    static let rotateWindowWhenSignaledByGuest = "RotateWindowWhenSignaledByGuest"
}

/// A physical device orientation, named as `devicectl` names it.
enum DeviceOrientation: String, CaseIterable {
    case portrait, landscapeRight, portraitUpsideDown, landscapeLeft, faceUp, faceDown

    /// The `SimDisplayView.deviceRotation` angle that shows this orientation
    /// upright: a device turned counterclockwise (landscape left) is shown
    /// turned 90° counterclockwise. A flat device keeps its last angle.
    var displayAngle: Double? {
        switch self {
        case .portrait: 0
        case .landscapeLeft: 90
        case .portraitUpsideDown: 180
        case .landscapeRight: -90
        case .faceUp, .faceDown: nil
        }
    }
}

/// The device's orientation and the display angle that follows it.
struct OrientationReading: Equatable {
    var physical: DeviceOrientation
    /// The angle of the last upright orientation, kept while the device is flat.
    var displayAngle: Double

    /// Reads the JSON output of `devicectl device orientation get`.
    init(devicectlOutput data: Data) throws {
        struct Output: Decodable {
            struct Result: Decodable {
                var deviceOrientation: String
                var deviceOrientationNonFlat: String
            }
            var result: Result
        }
        let result = try JSONDecoder().decode(Output.self, from: data).result
        guard let upright = DeviceOrientation(rawValue: result.deviceOrientationNonFlat),
              let angle = upright.displayAngle else {
            throw HostError.operation("Unsupported orientation: \(result.deviceOrientationNonFlat)")
        }
        // Before an orientation is set, devicectl reports `unknown` for the
        // physical orientation; the device is then upright.
        physical = DeviceOrientation(rawValue: result.deviceOrientation) ?? upright
        displayAngle = angle
    }
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
    /// The orientation last read from the device.
    private(set) var orientation: DeviceOrientation?
    /// The guest's interface orientation angle last observed, so that only its
    /// changes rotate the display. A manual rotation does not change it.
    @ObservationIgnored private var guestAngle: Double?

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
            guard send(event, .down, report) else { return }
            heldInputs[event, default: 0] += 1
            after(delay) { session in session.release(event, report) }
        case .pressTwice(let event, let interval):
            press(event, report)
            after(interval) { session in session.press(event, report) }
        }
    }

    private func press(_ event: HIDInput, _ report: FirstFailure) {
        if send(event, .down, report) { send(event, .up, report) }
    }

    @discardableResult
    private func send(_ event: HIDInput, _ state: HIDState, _ report: FirstFailure) -> Bool {
        guard canPerformCommands else { return false }
        do {
            try display.send(event, state) { error in
                if let error { report(error) }
            }
            return true
        } catch {
            report(error)
            return false
        }
    }

    // A held input is released while the device is booted, even when a
    // shutdown in progress makes other commands unavailable: the shutdown can
    // fail and leave the device running.
    private func release(_ event: HIDInput, _ report: FirstFailure) {
        heldInputs[event] = heldInputs[event].flatMap { $0 > 1 ? $0 - 1 : nil }
        guard heldInputs[event] == nil, !isDisconnected, display.isBooted else { return }
        do {
            try display.send(event, .up) { error in
                if let error { report(error) }
            }
        } catch {
            report(error)
        }
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

    /// Reads the device orientation and shows the display at its angle. With
    /// Rotate Device Automatically on, the display keeps following the guest's
    /// interface orientation, which can differ from the physical one.
    func readOrientation() async throws {
        let reading = try await tools.orientation()
        try Task.checkCancellation()
        orientation = reading.physical
        guestAngle = display.guestInterfaceAngle
        let followsGuest = UserDefaults.standard.bool(forKey: HostPreferences.rotateWindowWhenSignaledByGuest)
        display.setRotation(degrees: followsGuest ? guestAngle ?? reading.displayAngle : reading.displayAngle)
    }

    /// Shows the display at the guest's interface orientation when that
    /// changed, and returns whether it did. SimulatorKit also applies it with
    /// Rotate Device Automatically on; applying it here keeps the order
    /// deterministic.
    func followGuestInterfaceOrientation() -> Bool {
        guard canPerformCommands, let angle = display.guestInterfaceAngle, angle != guestAngle else { return false }
        guestAngle = angle
        display.setRotation(degrees: angle)
        return true
    }

    func rotate(left: Bool) async throws {
        try apply(await tools.rotate(left: left))
    }

    func setOrientation(_ orientation: DeviceOrientation) async throws {
        try apply(await tools.setOrientation(orientation))
    }

    private func apply(_ reading: OrientationReading) throws {
        try Task.checkCancellation()
        orientation = reading.physical
        display.setRotation(degrees: reading.displayAngle)
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
            try? display.send(event, .up, completion: nil)
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
