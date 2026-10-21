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
    /// Whether `devicectl` can read and set the physical orientation. It
    /// reaches only devices in the default device set.
    var controlsOrientation = true
    /// Whether the device type has a framebuffer mask that captures can apply.
    var hasFramebufferMask = false

    var isPhoneOrPad: Bool { family == .iPhone || family == .iPad }
    var rotates: Bool { controlsOrientation && supportsFeature(Self.displayRotation) }

    static let displayRotation = "com.apple.CoreSimulator.display.rotation"
    static let actionButtonSting = "com.apple.hid.sting"
    static let actionButtonStaccato = "com.apple.hid.staccato"
    static let siri = "com.apple.siri"
    static let routableAudio = "com.apple.CoreSimulator.audio.routable"
    static let applePayAuthorization = "com.apple.hid.applepay.authorize"
    static let touchID = "com.apple.touch-id"
    static let faceID = "com.apple.pearl-id"
    static let standBy = "com.apple.display.ambient-overlay"
}

/// Preferences Simulator.app keeps in its standard user defaults.
enum HostPreferences {
    /// Device ▸ Rotate Device Automatically. SimulatorKit reads this key from
    /// the host's standard defaults and rotates the display when the guest
    /// changes its interface orientation.
    static let rotateWindowWhenSignaledByGuest = "RotateWindowWhenSignaledByGuest"
    /// Debug ▸ Show Parallel Testing Devices, on unless turned off.
    static let showTestingDevices = "ShowTestingDevices"
    /// Overrides the path of Xcode's parallel testing device set.
    static let testingDeviceSetPath = "TestingDeviceSetPath"
    /// Whether closing a device window leaves the device running instead of
    /// shutting it down.
    static let detachOnWindowClose = "DetachOnWindowClose"
    /// Whether quitting leaves devices running instead of shutting them down.
    static let detachOnAppQuit = "DetachOnAppQuit"
    /// Whether launching shows windows for devices that are already booted.
    static let attachBootedOnStart = "AttachBootedOnStart"
    /// Whether launching starts the last chosen device; both must be on.
    static let sessionOnLaunch = "SessionOnLaunch"
    static let startLastDeviceOnLaunch = "StartLastDeviceOnLaunch"
    /// The device last chosen to open, which launching starts.
    static let currentDeviceUDID = "CurrentDeviceUDID"
    /// How long quitting waits for devices to disconnect and shut down, in seconds.
    static let terminationTimeout = "TerminationTimeout"
    /// The folder Save Screen saves into.
    static let screenShotSaveLocation = "ScreenShotSaveLocation"
    /// Whether Save Screen and Record Screen apply the device's mask.
    static let screenShotUseMask = "ScreenShotUseMask"
    /// Animated GIF export from a recording's thumbnail.
    static let gifMaxFramerate = "GifMaxFramerate"
    static let gifMaxFrameSize = "GifMaxFrameSize"
    static let gifUseDither = "GifUseDither"
    static let gifDitherDepth = "GifDitherDepth"

    /// Registers Simulator.app's defaults for these preferences.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showTestingDevices: true, detachOnWindowClose: false, detachOnAppQuit: false,
            attachBootedOnStart: true, sessionOnLaunch: true, startLastDeviceOnLaunch: true,
            terminationTimeout: 60.0, screenShotSaveLocation: defaultScreenshotLocation(), screenShotUseMask: false,
            gifMaxFramerate: 10, gifMaxFrameSize: 640, gifUseDither: true, gifDitherDepth: 4.0,
        ])
    }

    /// Like Simulator.app: the macOS screenshot location when it is an
    /// existing folder, and otherwise the Desktop.
    private static func defaultScreenshotLocation() -> String {
        var isDirectory: ObjCBool = false
        if let location = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString)
            as? String, FileManager.default.fileExists(atPath: NSString(string: location).expandingTildeInPath,
                                                       isDirectory: &isDirectory), isDirectory.boolValue {
            return location
        }
        return CaptureFile.desktop?.path ?? NSString(string: "~/Desktop").expandingTildeInPath
    }
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
    @ObservationIgnored private let makeRecordingProcess: (URL, DeviceTools.ScreenMask) -> Process
    @ObservationIgnored private var operation: Task<Void, Never>?
    /// The delayed steps of hardware inputs, which a disconnect cancels.
    @ObservationIgnored private var inputSteps: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var nextInputStep = 0
    /// How many holds of each input are still pending. HID button state is
    /// not counted, so overlapping holds keep the input down until the last ends.
    @ObservationIgnored private var pendingHolds: [HIDInput: Int] = [:]
    /// Inputs sent down whose release SimulatorKit has not yet delivered, with
    /// the generation of their latest down event. Closing the window releases them.
    @ObservationIgnored private var downInputs: [HIDInput: Int] = [:]
    @ObservationIgnored private var lastDownGeneration = 0
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
    ///   destination and mask. Defaults to the device's direct `simctl` recorder.
    init(device: AvailableDevice, capabilities: DeviceCapabilities, display: any SimulatorDisplay,
         tools: DeviceTools, recordings: RecordingStore = RecordingStore(),
         recordingProcess: ((URL, DeviceTools.ScreenMask) -> Process)? = nil) {
        self.device = device
        self.capabilities = capabilities
        self.display = display
        self.tools = tools
        self.recordings = recordings
        // Simulator.app records Apple Vision Pro in HEVC and other devices in H.264.
        let codec: DeviceTools.VideoCodec = capabilities.family == .vision ? .hevc : .h264
        makeRecordingProcess = recordingProcess ?? { tools.recordingProcess(to: $0, mask: $1, codec: codec) }
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
            guard let down = message(event, .down, report), send(down, report) else { return }
            markDown(event)
            pendingHolds[event, default: 0] += 1
            after(delay) { session in session.release(event, report) }
        case .pressTwice(let event, let interval):
            guard press(event, report) else { return }
            after(interval) { session in session.press(event, report) }
        }
    }

    /// Presses and releases an input, and returns whether both events were sent.
    /// Both messages are created first, so that a failure cannot leave the
    /// input down.
    @discardableResult
    private func press(_ event: HIDInput, _ report: FirstFailure) -> Bool {
        guard canPerformCommands, let down = message(event, .down, report),
              let up = message(event, .up, report), send(down, report) else { return false }
        return sendRelease(up, generation: markDown(event), report)
    }

    // A held input is released while the device is booted, even when a
    // shutdown in progress makes other commands unavailable: the shutdown can
    // fail and leave the device running. The release is created when the hold
    // ends, so that its timestamp records the hold.
    private func release(_ event: HIDInput, _ report: FirstFailure) {
        guard let count = pendingHolds[event] else { return }
        guard count == 1 else {
            pendingHolds[event] = count - 1
            return
        }
        pendingHolds[event] = nil
        guard !isDisconnected, display.isBooted, let generation = downInputs[event] else {
            downInputs[event] = nil
            return
        }
        if let up = message(event, .up, report) { sendRelease(up, generation: generation, report) }
    }

    @discardableResult
    private func markDown(_ event: HIDInput) -> Int {
        lastDownGeneration += 1
        downInputs[event] = lastDownGeneration
        return lastDownGeneration
    }

    /// Sends the release of the down event with `generation`. The input stays
    /// down until SimulatorKit delivers that release, unless a later down event
    /// or a pending hold keeps it down anyway.
    @discardableResult
    private func sendRelease(_ up: HIDMessage, generation: Int, _ report: FirstFailure) -> Bool {
        let event = up.input
        do {
            try display.send(up) { [weak self] error in
                if let error {
                    report(error)
                } else if let self, self.downInputs[event] == generation, self.pendingHolds[event] == nil {
                    self.downInputs[event] = nil
                }
            }
            return true
        } catch {
            report(error)
            return false
        }
    }

    private func message(_ event: HIDInput, _ state: HIDState, _ report: FirstFailure) -> HIDMessage? {
        do {
            return try display.message(for: event, state)
        } catch {
            report(error)
            return nil
        }
    }

    private func send(_ message: HIDMessage, _ report: FirstFailure) -> Bool {
        do {
            try display.send(message) { error in
                if let error { report(error) }
            }
            return true
        } catch {
            report(error)
            return false
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
        try display.postNotification("com.apple.UIKit.SimulatorShake")
    }

    func toggleAppearance() throws {
        guard canPerformCommands else { return }
        try display.toggleAppearance()
    }

    // MARK: Guest features

    enum Biometric { case touchID, faceID }

    private static let biometricEnrollment = "com.apple.BiometricKit.enrollmentChanged"
    private static let standBy = "com.apple.springboard.ambient.presentation"

    /// Whether biometrics are enrolled. Touch ID and Face ID share this guest state.
    var isBiometricEnrolled: Bool {
        canPerformCommands && (try? display.notificationState(Self.biometricEnrollment)) == 1
    }

    func toggleBiometricEnrollment() throws {
        guard canPerformCommands else { return }
        try toggleState(of: Self.biometricEnrollment)
    }

    /// Presents a matching or non-matching finger or face to the guest.
    func sendBiometric(_ biometric: Biometric, matching: Bool) throws {
        guard canPerformCommands else { return }
        let source = biometric == .touchID ? "fingerTouch" : "pearl"
        try display.postNotification("com.apple.BiometricKit_Sim.\(source).\(matching ? "match" : "nomatch")")
    }

    func toggleInCallStatusBar() throws {
        guard canPerformCommands else { return }
        try display.postNotification("com.apple.iphonesimulator.toggleincallstatusbar")
    }

    var showsStandBy: Bool { canPerformCommands && (try? display.notificationState(Self.standBy)) == 1 }

    func toggleStandBy() throws {
        guard canPerformCommands else { return }
        try toggleState(of: Self.standBy)
    }

    /// Flips a guest notification's state between 0 and 1 and posts it.
    private func toggleState(of name: String) throws {
        let state: UInt64 = try display.notificationState(name) == 1 ? 0 : 1
        try display.setNotificationState(name, to: state)
        do { try display.postNotification(name) } catch {
            throw HostError.operation("The device's state changed, but it was not notified: \(error.localizedDescription)")
        }
    }

    /// Moves the preferred text size `delta` steps. Like Simulator.app, it
    /// stops at the smallest and the largest accessibility size.
    func changeTextSize(by delta: Int) throws {
        guard canPerformCommands else { return }
        let sizes = 1...12
        let category = try display.contentSizeCategory()
        guard sizes.contains(category) else {
            throw HostError.operation("The device did not report its preferred text size.")
        }
        guard sizes.contains(category + delta) else { return }
        try display.setContentSizeCategory(category + delta)
    }

    func toggleIncreaseContrast() throws {
        guard canPerformCommands else { return }
        switch try display.increaseContrastMode() {
        case 1: try display.setIncreaseContrast(true)
        case 2: try display.setIncreaseContrast(false)
        default: throw HostError.operation("The device did not report whether Increase Contrast is on.")
        }
    }

    func triggerCloudSync() async throws { try await display.triggerCloudSync() }

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
    /// deterministic. While following is off, the display can rotate without
    /// the guest, so the next change after following resumes is applied.
    func followGuestInterfaceOrientation(enabled: Bool) -> Bool {
        guard enabled else {
            guestAngle = nil
            return false
        }
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

    /// Saves the screen to a file chosen in a save panel, replacing it.
    func saveScreenshot(to destination: URL, mask: DeviceTools.ScreenMask) async throws {
        try await CaptureFile.write(to: destination, extension: "png") { temporary in
            try await tools.screenshot(to: temporary, mask: mask)
            try Self.checkPNG(at: temporary)
        }
    }

    /// Saves the screen into `folder` under `name`, numbering the name when
    /// it is taken, and returns the saved file.

    /// The screen as a PNG, without the device's mask, for Edit ▸ Copy Screen.
    func screenPNG() async throws -> Data {
        let temporary = try await screenshot(mask: .ignored)
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try Data(contentsOf: temporary)
    }

    /// Takes a screenshot into a new temporary PNG, which the caller owns.
    func screenshot(mask: DeviceTools.ScreenMask) async throws -> URL {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("simulator_screenshot_\(UUID().uuidString).png")
        do {
            try await tools.screenshot(to: temporary, mask: mask)
            try Self.checkPNG(at: temporary)
            return temporary
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func checkPNG(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 8) == Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else {
            throw HostError.operation("The screenshot tool did not produce a PNG file")
        }
    }

    /// Whether a recording to a chosen file will replace `file` when it finishes.
    func isRecordingDestination(_ file: URL) -> Bool { recordings.isReserved(file) }

    func startRecording(to destination: RecordingStore.Destination, mask: DeviceTools.ScreenMask) throws {
        guard canPerformCommands, recording == nil else { return }
        recording = try recordings.start(to: destination, process: { [makeRecordingProcess] in
            makeRecordingProcess($0, mask)
        }) { [weak self] in
            self?.recording = nil
        }
    }

    func stopRecording() { recording?.stop() }

    /// Stops an active recording and waits until it is finalized, so that a
    /// restart does not cut it off. The recording store reports its errors.
    func finishRecording() async {
        guard let recording else { return }
        recording.stop()
        try? await recording.waitUntilFinished()
    }

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
        for event in downInputs.keys {
            if let up = try? display.message(for: event, .up) { try? display.send(up, completion: nil) }
        }
        pendingHolds.removeAll()
        downInputs.removeAll()
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
