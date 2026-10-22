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
    /// The screen's corner radius in points; 0 for a square screen.
    var screenCornerRadius = 0.0
    /// The screen's points per inch, for Physical Size; nil when unknown.
    var screenPointsPerInch: Double?
    /// Whether the device type has a user-interface plugin, which
    /// SimulatorKit loads for its display, such as Apple Vision Pro's.
    var hasUserInterfacePlugin = false
    /// Whether the guest runs Stage Manager, also on an external display
    /// (`DeviceSupportsEnhancedMultitasking`), as iPads from M1 do.
    var supportsEnhancedMultitasking = false

    var isPhoneOrPad: Bool { family == .iPhone || family == .iPad }
    /// Whether Window ▸ Show Device Bezels applies. Simulator.app hides it for
    /// Apple Vision, whose display has no bezel.
    var supportsDeviceBezels: Bool { family != .vision }
    var rotates: Bool { controlsOrientation && supportsFeature(Self.displayRotation) }
    /// Whether I/O ▸ External Displays applies: like Simulator.app, the device
    /// supports external displays and has its own screen.
    var supportsExternalDisplays: Bool { supportsFeature(Self.externalDisplay) && supportsFeature(Self.integratedDisplay) }
    /// Whether I/O ▸ External Displays ▸ CarPlay applies: like Simulator.app,
    /// the device also supports CarPlay.
    var supportsCarPlay: Bool { supportsExternalDisplays && supportsFeature(Self.carPlay) }
    /// Whether the device has a Digital Crown or Digital Dial, which the
    /// pointer's scrolling turns.
    var hasCrownOrDial: Bool { supportsFeature(Self.digitalCrown) || supportsFeature(Self.digitalDial) }

    /// Why the device cannot show an External Displays item whatever its
    /// external display offers, or nil: iPadOS before 27 on an iPad with Stage
    /// Manager cannot leave a 3840×2160 display at 60 Hz (see
    /// `ExternalDisplayLimit.extendedDisplay`), and at 120 Hz it would show
    /// 720×480.
    func externalDisplayLimit(for mode: ExternalDisplayMode) -> ExternalDisplayLimit? {
        mode == .size3840x2160 && family == .iPad && supportsEnhancedMultitasking && runtimeVersion < 0x1B_00_00
            ? .extendedDisplay : nil
    }

    static let displayRotation = "com.apple.CoreSimulator.display.rotation"
    static let actionButtonSting = "com.apple.hid.sting"
    static let actionButtonStaccato = "com.apple.hid.staccato"
    static let siri = "com.apple.siri"
    static let routableAudio = "com.apple.CoreSimulator.audio.routable"
    static let applePayAuthorization = "com.apple.hid.applepay.authorize"
    static let touchID = "com.apple.touch-id"
    static let faceID = "com.apple.pearl-id"
    /// `SimFeatureOysterID`: Optic ID, Apple Vision Pro's.
    static let opticID = "com.apple.oyster-id"
    /// `SimFeatureHoverboard95880941`, which only Apple Vision Pro's device
    /// types declare. Simulator.app shows Debug ▸ Show Gaze Target only with
    /// it.
    static let hoverboard = "com.apple.hid.hoverboard.95880941"
    static let standBy = "com.apple.display.ambient-overlay"
    /// `SimFeatureUIKitSlowMotionStateful`: the guest keeps slow animations on
    /// until they are turned off.
    static let slowMotionStateful = "com.apple.UIKit.SimulatorSlowMotionStateful"
    /// `SimFeatureUIKitGraphicsQualityOverride`.
    static let graphicsQualityOverride = "com.apple.UIKit.SimulatorGraphicsQualityOverride"
    /// `SimFeatureKeyboard`: the guest takes a hardware keyboard, and the
    /// Mac's keyboard types into it. Simulator.app shows I/O ▸ Keyboard only
    /// with it.
    static let keyboard = "com.apple.hid.keyboard"
    /// `SimFeatureTouchPressure`: the guest takes the pressure of a touch,
    /// such as 3D Touch. Simulator.app shows I/O ▸ Touch Pressure only with it.
    static let touchPressure = "com.apple.hid.touch-pressure"
    /// `SimFeaturePasteboard`: the guest runs the pasteboard service that Get
    /// and Send Pasteboard connect to. `simctl pbsync` requires it.
    static let pasteboard = "com.apple.CoreSimulator.pasteboard"
    /// `SimFeatureExternalDisplay`: the device has an external display port.
    static let externalDisplay = "com.apple.display.supports-external"
    /// `SimFeatureInternalDisplay`: the device has its own screen.
    static let integratedDisplay = "com.apple.display.integrated"
    /// `SimFeatureCarPlay`: the guest runs CarPlay on its external display.
    static let carPlay = "com.apple.carplay"
    /// `SimFeatureAlwaysOnDisplay`: the watch dims its display instead of
    /// turning it off, which Simulator.app's Always On button shows.
    static let alwaysOnDisplay = "com.apple.display.aot"
    /// `SimFeatureWatchGestures`: the watch takes Device ▸ Gestures.
    static let watchGestures = "com.apple.hid.watch.gestures"
    /// `SimFeatureDigitalCrown`, which watches have, and
    /// `SimFeatureDigitalDial`, which Apple Vision Pro has: the device takes
    /// the pointer's scrolling as turns of the crown or dial.
    static let digitalCrown = "com.apple.hid.digital-crown"
    static let digitalDial = "com.apple.hid.digital-dial"
    /// `SimFeatureFallDetection`: the watch takes Features ▸ Simulate Fall.
    static let fallDetection = "com.apple.motion.fall-detection"
}

/// Preferences Simulator.app keeps in its standard user defaults.
enum HostPreferences {
    /// Device ▸ Rotate Device Automatically. SimulatorKit reads this key from
    /// the host's standard defaults and rotates the display when the guest
    /// changes its interface orientation.
    static let rotateWindowWhenSignaledByGuest = "RotateWindowWhenSignaledByGuest"
    /// Debug ▸ Show Parallel Testing Devices, on unless turned off.
    static let showTestingDevices = "ShowTestingDevices"
    /// Window ▸ Show Device Bezels, on unless turned off. It applies to every
    /// device window: see `PreferenceStore.showsDeviceBezels`.
    static let showChrome = "ShowChrome"
    /// The style of each device window's title bar, which Simulator.app's
    /// geometry update reads: with `UseCompactTitleBar`, off unless turned on,
    /// the compact unified style; otherwise, with `UseMonobar`, on unless
    /// turned off, the unified style while the window is wide enough for its
    /// toolbar, and the expanded style below that. See `DeviceToolbar.style`.
    static let useMonobar = "UseMonobar"
    static let useCompactTitleBar = "UseCompactTitleBar"
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
    /// Debug ▸ Slow Animations, which connecting applies to each device that
    /// keeps the setting.
    static let slowMotionAnimation = "SlowMotionAnimation"
    /// Debug ▸ Graphics Quality Override, a `GraphicsQuality` value, which
    /// connecting applies to each device that supports it unless it is the default.
    static let graphicsQualityOverride = "GraphicsQualityOverride"
    /// Animated GIF export from a recording's thumbnail.
    static let gifMaxFramerate = "GifMaxFramerate"
    static let gifMaxFrameSize = "GifMaxFrameSize"
    static let gifUseDither = "GifUseDither"
    static let gifDitherDepth = "GifDitherDepth"
    /// The last Features ▸ Location choice, which each connection restores:
    /// see `LocationSelection`.
    static let locationMode = "LocationMode"
    static let locationScenario = "LocationScenario"
    /// The coordinate Custom Location… last set.
    static let locationLatitude = "LocationLatitude"
    static let locationLongitude = "LocationLongitude"
    /// A dictionary of each device's own preferences, by UDID: see
    /// `PreferenceStore.windowGeometry(forDevice:screens:)` and
    /// `PreferenceStore.connectsHardwareKeyboard(forDevice:)`.
    static let devicePreferences = "DevicePreferences"
    /// I/O ▸ Keyboard ▸ Use the Same Keyboard Language as macOS, on unless
    /// turned off: see `PreferenceStore.syncsKeyboardLanguage`.
    static let enableKeyboardSync = "EnableKeyboardSync"
    /// I/O ▸ Keyboard ▸ Connect Hardware Keyboard, on unless turned off. The
    /// command saves each device's choice under this key in its
    /// `DevicePreferences`; see `PreferenceStore.connectsHardwareKeyboard(forDevice:)`.
    static let connectHardwareKeyboard = "ConnectHardwareKeyboard"
    /// I/O ▸ Touch Pressure ▸ Use Trackpad Force, on unless turned off; it
    /// applies only with a Force Touch trackpad. See `TouchPressure`.
    static let useTrackpadForce = "UseTrackpadForce"
    /// The touch indicators every device window draws: see `TouchIndicator`.
    static let showSingleTouches = "ShowSingleTouches"
    static let showPinches = "ShowPinches"
    static let showPinchPivotPoint = "ShowPinchPivotPoint"
    static let highlightEdgeGestures = "HighlightEdgeGestures"
    /// The arrangements of the Mac's screens that device windows were saved
    /// in, by UUID: see `PreferenceStore.screenConfiguration(for:)`.
    static let screenConfigurations = "ScreenConfigurations"
    /// I/O ▸ Audio Input's and Audio Output's recent routes, which every
    /// device follows: see `PreferenceStore.recentAudioRoutes(in:)`.
    static let recentAudioInputDeviceUIDs = "RecentAudioInputDeviceUIDs"
    static let recentAudioOutputDeviceUIDs = "RecentAudioOutputDeviceUIDs"
    /// Edit ▸ Automatically Sync Pasteboard: see `PasteboardSync`.
    static let pasteboardAutomaticSync = "PasteboardAutomaticSync"
    /// Whether a drag on a device window's bezel outside its corners moves
    /// the window, on unless turned off: see
    /// `PreferenceStore.movesWindowByDraggingBezel`.
    static let allowsMoveByDragOnWindowChrome = "AllowsMoveByDragOnWindowChrome"

    /// Registers Simulator.app's defaults for these preferences. Show Pinch
    /// Gestures is on: Simulator.app registers it so, and its Settings.bundle's
    /// `false` only applies to a key without a value, which a registered key
    /// never is. Automatically Sync Pasteboard is off, although Simulator.app
    /// registers it on: NeoSimulator exchanges pasteboards only when chosen.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            showTestingDevices: true, showChrome: true, useMonobar: true, useCompactTitleBar: false,
            detachOnWindowClose: false, detachOnAppQuit: false,
            attachBootedOnStart: true, sessionOnLaunch: true, startLastDeviceOnLaunch: true,
            terminationTimeout: 60.0, screenShotSaveLocation: defaultScreenshotLocation(), screenShotUseMask: false,
            slowMotionAnimation: false, graphicsQualityOverride: GraphicsQuality.deviceDefault.rawValue,
            gifMaxFramerate: 10, gifMaxFrameSize: 640, gifUseDither: true, gifDitherDepth: 4.0,
            locationMode: LocationSelection.customMode, locationLatitude: 37.785834, locationLongitude: -122.406417,
            enableKeyboardSync: true, connectHardwareKeyboard: true, useTrackpadForce: true,
            showSingleTouches: false, showPinches: true, showPinchPivotPoint: false, highlightEdgeGestures: false,
            pasteboardAutomaticSync: false, allowsMoveByDragOnWindowChrome: true,
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

/// A device's Features ▸ Location choice. Simulator.app keeps it per device
/// and saves the last choice app-wide, as its menu tag in `LocationMode` and a
/// scenario's name in `LocationScenario`.
enum LocationSelection: Equatable {
    case none, custom
    /// A runtime scenario, by its `LocationScenario.name`.
    case scenario(String)

    static let noneMode = 5101, customMode = 5102
    /// Simulator.app saves a scenario's menu tag, which is above Custom's.
    static let scenarioMode = 5103

    /// The saved choice for a device with `scenarios`. A saved scenario the
    /// device does not have, and a mode Simulator.app does not use, are None.
    static func saved(among scenarios: [LocationScenario]) -> Self {
        let defaults = UserDefaults.standard
        let mode = defaults.integer(forKey: HostPreferences.locationMode)
        guard mode > customMode else { return mode == customMode ? .custom : .none }
        guard let name = defaults.string(forKey: HostPreferences.locationScenario),
              scenarios.contains(where: { $0.name == name }) else { return .none }
        return .scenario(name)
    }

    /// Saves this choice for the next connection. Choosing None keeps the
    /// saved scenario name, as in Simulator.app.
    func save() {
        let defaults = UserDefaults.standard
        switch self {
        case .none: defaults.set(Self.noneMode, forKey: HostPreferences.locationMode)
        case .custom: defaults.set(Self.customMode, forKey: HostPreferences.locationMode)
        case .scenario(let name):
            defaults.set(name, forKey: HostPreferences.locationScenario)
            defaults.set(Self.scenarioMode, forKey: HostPreferences.locationMode)
        }
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

/// Debug ▸ Graphics Quality Override, as the guest's
/// `com.apple.UIKit.ForceGraphicsQuality` state numbers it.
enum GraphicsQuality: Int {
    case deviceDefault = 0, low = 10, high = 100
}

/// Edit ▸ Get Pasteboard or Send Pasteboard: a one-time copy of a whole
/// pasteboard, with all its types, between the Mac and the device.
enum PasteboardTransfer {
    /// Replaces the Mac pasteboard with the device's: SimPasteboardPlus `pull`.
    case get
    /// Replaces the device's pasteboard with the Mac's: `push`.
    case send
}

/// How Simulator.app times the events of a hardware input.
enum HardwareInput {
    /// Pressed and released at once.
    case press(HIDInput)
    /// Pressed, then released after a delay.
    case hold(HIDInput, for: Duration)
    /// Pressed and released twice, the second time after a delay.
    case pressTwice(HIDInput, interval: Duration)
    /// A watch gesture, sent as one message.
    case watchGesture(WatchGesture)
}

/// How a simulated fall ended, Features ▸ Simulate Fall, as the state of the
/// guest's `com.apple.sos.user-fell` notification numbers it, which is also
/// Simulator.app's menu tag.
enum FallResolution: UInt64 {
    case confirmed = 0, dismissed = 1, rejected = 2, unresponsive = 3
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
    /// Keeps the device's keyboard preferences and the app-wide ones.
    @ObservationIgnored private let preferences: any PreferenceStore
    /// The Mac keyboard's language, which Use the Same Keyboard Language as
    /// macOS gives the guest, or nil when it cannot be determined.
    @ObservationIgnored private let hostKeyboardLanguage: @MainActor () -> String?
    @ObservationIgnored private let recordings: RecordingStore
    @ObservationIgnored private let makeRecordingProcess: (URL, DeviceTools.ScreenMask) -> Process
    @ObservationIgnored private let openLog: (URL) async throws -> Void
    /// The Mac pasteboard that Get Pasteboard replaces and Send Pasteboard
    /// sends, or nil for the general pasteboard.
    @ObservationIgnored private let hostPasteboard: NSPasteboard?
    /// Edit ▸ Automatically Sync Pasteboard, or nil when the session never
    /// synchronizes.
    @ObservationIgnored private let pasteboardSync: PasteboardSync?
    /// The device's pasteboard connection, from the first transfer, or while
    /// synchronizing, until the device closes it or the session disconnects.
    @ObservationIgnored private var pasteboardConnection: (any SimulatorPasteboard)?
    /// The Mac pasteboard's change count when the device's pasteboard last
    /// replaced it, Simulator.app's `lastSyncedPasteboardSnapshotLocalGeneration`,
    /// or nil after a failed replacement.
    @ObservationIgnored private var lastReceivedGeneration: Int?
    /// Whether the connection reported its first activation, after which each
    /// activation completes a push.
    @ObservationIgnored private var isPasteboardActive = false
    /// The failure handlers of transfers the device has not completed, oldest first.
    @ObservationIgnored private var pendingPulls: [(Error) -> Void] = []
    @ObservationIgnored private var pendingPushes: [(Error) -> Void] = []
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
    /// The angle the display is shown at, which a guest-initiated rotation
    /// can set without changing `orientation`.
    @ObservationIgnored private(set) var displayAngle: Double = 0
    /// The guest's interface orientation angle last observed, so that only its
    /// changes rotate the display. A manual rotation does not change it.
    @ObservationIgnored private var guestAngle: Double?
    /// The location routes the device's runtime listed when this session connected.
    private(set) var locationScenarios: [LocationScenario] = []
    /// The Features ▸ Location choice for this device, which its checkmark
    /// shows. CoreSimulator does not report the guest's location, so this is
    /// what the host last applied.
    private(set) var location: LocationSelection?

    /// - Parameters:
    ///   - recordingProcess: Creates the recording process for a destination
    ///     and mask. Defaults to the device's direct `simctl` recorder.
    ///   - openLog: Opens the device's system log. Defaults to Console.
    ///   - preferences: Where the keyboard preferences are kept.
    ///   - hostKeyboardLanguage: Reads the Mac keyboard's language.
    ///   - pasteboard: The Mac pasteboard that the device's pasteboard is
    ///     exchanged with. Defaults to the general pasteboard, which the
    ///     session uses only once a transfer or synchronization starts.
    ///   - pasteboardSync: Edit ▸ Automatically Sync Pasteboard, which every
    ///     device shares. Without it, the session never synchronizes.
    ///   - externalScreenLookUp: How often and how long to look for the
    ///     external display after the device connects. Defaults to the host's
    ///     wait for the device's own screen.
    init(device: AvailableDevice, capabilities: DeviceCapabilities, display: any SimulatorDisplay,
         tools: DeviceTools, recordings: RecordingStore = RecordingStore(),
         recordingProcess: ((URL, DeviceTools.ScreenMask) -> Process)? = nil,
         openLog: @escaping (URL) async throws -> Void = DeviceSession.openInConsole,
         preferences: any PreferenceStore = UserDefaults.standard,
         hostKeyboardLanguage: @escaping @MainActor () -> String? = HostKeyboard.language,
         pasteboard: NSPasteboard? = nil, pasteboardSync: PasteboardSync? = nil,
         externalDisplayChanges: ExternalDisplayChanges = ExternalDisplayChanges(),
         externalScreenLookUp: (attempts: Int, interval: Duration) = (40, .milliseconds(250))) {
        self.device = device
        self.externalDisplayChanges = externalDisplayChanges
        externalScreenLookUpSchedule = externalScreenLookUp
        self.capabilities = capabilities
        self.display = display
        self.tools = tools
        self.preferences = preferences
        self.hostKeyboardLanguage = hostKeyboardLanguage
        hostPasteboard = pasteboard
        self.pasteboardSync = pasteboardSync
        self.recordings = recordings
        // Simulator.app records Apple Vision Pro in HEVC and other devices in H.264.
        let codec: DeviceTools.VideoCodec = capabilities.family == .vision ? .hevc : .h264
        makeRecordingProcess = recordingProcess ?? { tools.recordingProcess(to: $0, mask: $1, codec: codec) }
        self.openLog = openLog
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
        case .watchGesture(let gesture):
            do {
                try display.send(gesture) { error in
                    if let error { report(error) }
                }
            } catch {
                report(error)
            }
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

    /// The state of a watch's Always On button. Like Simulator.app's, it
    /// follows the screen's backlight: on while the backlight is 0 or 1, off
    /// at 2, and unchanged at other values; it starts off.
    private(set) var showsAlwaysOn = false

    /// Reads the backlight of a watch for its Always On button, as
    /// Simulator.app does when the display connects and when the screen's
    /// properties change.
    func followBacklight() {
        guard capabilities.family == .watch, !isDisconnected else { return }
        switch display.backlightState {
        case 0, 1: showsAlwaysOn = true
        case 2: showsAlwaysOn = false
        default: break
        }
    }

    func toggleAppearance() throws {
        guard canPerformCommands else { return }
        try display.toggleAppearance()
    }

    // MARK: Guest features

    enum Biometric {
        case touchID, faceID, opticID

        /// The `SimDevice` feature of the biometric.
        var feature: String {
            switch self {
            case .touchID: DeviceCapabilities.touchID
            case .faceID: DeviceCapabilities.faceID
            case .opticID: DeviceCapabilities.opticID
            }
        }
    }

    private static let biometricEnrollment = "com.apple.BiometricKit.enrollmentChanged"
    private static let standBy = "com.apple.springboard.ambient.presentation"

    /// Whether biometrics are enrolled. Touch ID, Face ID, and Optic ID share
    /// this guest state.
    var isBiometricEnrolled: Bool {
        canPerformCommands && (try? display.notificationState(Self.biometricEnrollment)) == 1
    }

    func toggleBiometricEnrollment() throws {
        guard canPerformCommands else { return }
        try toggleState(of: Self.biometricEnrollment)
    }

    /// Presents a matching or non-matching finger, face, or eye to the guest.
    func sendBiometric(_ biometric: Biometric, matching: Bool) throws {
        guard canPerformCommands else { return }
        let source = switch biometric {
        case .touchID: "fingerTouch"
        case .faceID: "pearl"
        case .opticID: "oyster"
        }
        try display.postNotification("com.apple.BiometricKit_Sim.\(source).\(matching ? "match" : "nomatch")")
    }

    func toggleInCallStatusBar() throws {
        guard canPerformCommands else { return }
        try display.postNotification("com.apple.iphonesimulator.toggleincallstatusbar")
    }

    /// Features ▸ Simulate Fall: tells the guest that its user fell and how
    /// the fall ended, as Simulator.app does.
    func simulateFall(_ resolution: FallResolution) throws {
        guard canPerformCommands else { return }
        try send(resolution.rawValue, to: "com.apple.sos.user-fell")
    }

    var showsStandBy: Bool { canPerformCommands && (try? display.notificationState(Self.standBy)) == 1 }

    func toggleStandBy() throws {
        guard canPerformCommands else { return }
        try toggleState(of: Self.standBy)
    }

    /// Flips a guest notification's state between 0 and 1 and posts it.
    private func toggleState(of name: String) throws {
        try send(display.notificationState(name) == 1 ? 0 : 1, to: name)
    }

    /// Sets a guest notification's state and posts it. `didSet` runs once the
    /// state is set, also when the post then fails.
    private func send(_ state: UInt64, to name: String, didSet: () -> Void = {}) throws {
        try display.setNotificationState(name, to: state)
        didSet()
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

    // MARK: Keyboard

    /// Whether the device takes a hardware keyboard, which Simulator.app's
    /// I/O ▸ Keyboard needs.
    var supportsKeyboard: Bool { capabilities.supportsFeature(DeviceCapabilities.keyboard) }

    /// Connect Hardware Keyboard's checkmark: the device's choice. Like
    /// Simulator.app's keyboard controller, the Mac's keyboard types into the
    /// device only while it is on, and Toggle Software Keyboard needs it.
    var connectsHardwareKeyboard: Bool {
        supportsKeyboard && preferences.connectsHardwareKeyboard(forDevice: device.id)
    }

    /// Connect Hardware Keyboard: flips the device's choice and saves it, as
    /// Simulator.app does, then connects or disconnects the guest's keyboard.
    /// The choice is saved first, so it stays when applying fails, and
    /// choosing again retries. Simulator.app only logs the failure.
    func toggleHardwareKeyboard() async throws {
        guard canPerformCommands else { return }
        let connects = !preferences.connectsHardwareKeyboard(forDevice: device.id)
        preferences.setConnectsHardwareKeyboard(connects, forDevice: device.id)
        try await display.setHardwareKeyboardConnected(connects)
    }

    /// Use the Same Keyboard Language as macOS, an app-wide preference.
    var syncsKeyboardLanguage: Bool { preferences.syncsKeyboardLanguage }

    /// Like Simulator.app, changes only the preference. The guest takes the
    /// Mac's language on its next connection or input-source change.
    func toggleKeyboardLanguageSync() {
        preferences.set(!preferences.syncsKeyboardLanguage, forKey: HostPreferences.enableKeyboardSync)
    }

    /// Gives the guest's keyboard the language of the Mac's while Use the
    /// Same Keyboard Language as macOS is on, as Simulator.app does when the
    /// device connects and when the Mac's input source changes.
    func syncKeyboardLanguage() async throws {
        guard canPerformCommands, preferences.syncsKeyboardLanguage else { return }
        guard let language = hostKeyboardLanguage() else {
            throw HostError.operation("Could not determine the language of the Mac's keyboard.")
        }
        try await display.setKeyboardLanguage(language)
    }

    /// Applies the keyboard settings to a device that was just connected, as
    /// Simulator.app does on each connection: the hardware keyboard, then the
    /// Mac's keyboard language. Each failure goes to `failure`, and one does
    /// not stop the other.
    ///
    /// Simulator.app connects the hardware keyboard as the app-wide
    /// `ConnectHardwareKeyboard` says, while its checkmark and keyboard input
    /// follow the device's choice, so a device whose keyboard was disconnected
    /// gets it back on its next connection. NeoSimulator applies the choice
    /// the checkmark shows, which the app-wide value only stands in for.
    func applyKeyboardSettings(failure: (Error) -> Void) async {
        guard canPerformCommands else { return }
        do { try await display.setHardwareKeyboardConnected(preferences.connectsHardwareKeyboard(forDevice: device.id)) }
        catch { failure(error) }
        do { try await syncKeyboardLanguage() } catch { failure(error) }
    }

    // MARK: Debug

    private static let slowMotionAnimation = "com.apple.UIKit.SimulatorSlowMotionAnimationState"
    private static let forceGraphicsQuality = "com.apple.UIKit.ForceGraphicsQuality"

    /// Whether Debug ▸ Slow Animations shows its state: the guest keeps slow
    /// animations on. Otherwise Simulator.app offers a toggle for the frontmost app.
    var keepsSlowAnimations: Bool { capabilities.supportsFeature(DeviceCapabilities.slowMotionStateful) }

    /// Like Simulator.app, the app's setting rather than the guest's state.
    var slowAnimations: Bool { UserDefaults.standard.bool(forKey: HostPreferences.slowMotionAnimation) }

    /// Flips `SlowMotionAnimation` and sends it to the guest, also when the
    /// guest does not keep it, as Simulator.app does.
    func toggleSlowAnimations() throws {
        guard canPerformCommands else { return }
        let enabled = !slowAnimations
        try send(enabled ? 1 : 0, to: Self.slowMotionAnimation) {
            UserDefaults.standard.set(enabled, forKey: HostPreferences.slowMotionAnimation)
        }
    }

    var graphicsQuality: GraphicsQuality? {
        GraphicsQuality(rawValue: UserDefaults.standard.integer(forKey: HostPreferences.graphicsQualityOverride))
    }

    /// Sends the quality to the guest and saves it as `GraphicsQualityOverride`.
    func setGraphicsQuality(_ quality: GraphicsQuality) throws {
        guard canPerformCommands else { return }
        try send(UInt64(quality.rawValue), to: Self.forceGraphicsQuality) {
            UserDefaults.standard.set(quality.rawValue, forKey: HostPreferences.graphicsQualityOverride)
        }
    }

    /// Stops PineBoard, an Apple TV's system UI, which launchd restarts. After a
    /// graphics-quality change, Simulator.app does this so that it takes effect.
    func restartSystemUI() async throws { try await tools.stopSystemUI() }

    /// Applies the app's slow-animation and graphics-quality settings to a
    /// device that was just connected, as Simulator.app does: slow animations
    /// when the guest keeps them, and a quality other than the default.
    func applyDebugSettings() throws {
        if keepsSlowAnimations { try send(slowAnimations ? 1 : 0, to: Self.slowMotionAnimation) }
        if capabilities.supportsFeature(DeviceCapabilities.graphicsQualityOverride),
           let quality = graphicsQuality, quality != .deviceDefault {
            try send(UInt64(quality.rawValue), to: Self.forceGraphicsQuality)
        }
    }

    /// Whether a Core Animation debug option is on, as the device reports it.
    func isOn(_ option: CADebugOption) -> Bool {
        canPerformCommands && (try? display.caDebugOption(option)) == true
    }

    /// Turns a Core Animation debug option on or off. CoreSimulator reports no
    /// failure of the change, so the option is read back.
    func toggle(_ option: CADebugOption) throws {
        guard canPerformCommands else { return }
        let enabled = try !display.caDebugOption(option)
        try display.setCADebugOption(option, enabled: enabled)
        guard try display.caDebugOption(option) == enabled else {
            throw HostError.operation("The device did not turn \(enabled ? "on" : "off") \(option.title).")
        }
    }

    /// Debug ▸ Open System Log…: opens the device's `system.log` with `openLog`.
    func openSystemLog() async throws {
        let log = try display.logDirectory().appendingPathComponent("system.log")
        guard FileManager.default.fileExists(atPath: log.path) else {
            throw HostError.operation("The device has no system log at \(log.path).")
        }
        try await openLog(log)
    }

    /// Opens a log in Console, as Simulator.app does.
    static func openInConsole(_ log: URL) async throws {
        guard let console = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else {
            throw HostError.unavailable("Console is not installed.")
        }
        _ = try await NSWorkspace.shared.open([log], withApplicationAt: console,
                                              configuration: NSWorkspace.OpenConfiguration())
    }

    /// Debug ▸ Simulate Memory Warning: writes the empty trigger file that
    /// `SimDevice.simulateMemoryWarning` writes, non-atomically like it, but
    /// reports a failed write, which that method discards. A successful write
    /// does not mean that an app handled the warning.
    func simulateMemoryWarning() throws {
        guard canPerformCommands else { return }
        try Data().write(to: display.memoryWarningFile())
    }

    // MARK: Location

    /// Restores the saved Location choice when the session connects, as
    /// Simulator.app does when it lists the runtime's scenarios: a device that
    /// lists none gets no choice and no location.
    func restoreLocation() async throws {
        let scenarios = try await display.locationScenarios()
        // Right after a boot, listing takes up to a second. The session can
        // end meanwhile, and a choice made meanwhile is kept.
        guard !isDisconnected else { return }
        locationScenarios = scenarios
        guard !scenarios.isEmpty, location == nil else { return }
        try await use(.saved(among: scenarios))
    }

    /// Features ▸ Location ▸ None or a scenario, for this device only; the
    /// choice is also saved for later connections.
    func selectLocation(_ selection: LocationSelection) async throws {
        guard canPerformCommands else { return }
        try await use(selection)
    }

    /// Custom Location…'s OK: saves the coordinate and selects it.
    func setCustomLocation(latitude: Double, longitude: Double) async throws {
        guard canPerformCommands else { return }
        UserDefaults.standard.set(latitude, forKey: HostPreferences.locationLatitude)
        UserDefaults.standard.set(longitude, forKey: HostPreferences.locationLongitude)
        try await use(.custom)
    }

    // Like Simulator.app, the choice is kept and saved before it is applied,
    // so it stays when applying fails, and choosing it again retries.
    private func use(_ selection: LocationSelection) async throws {
        location = selection
        selection.save()
        switch selection {
        case .none: try await display.clearSimulatedLocation()
        case .custom:
            try await display.setLocation(
                latitude: UserDefaults.standard.double(forKey: HostPreferences.locationLatitude),
                longitude: UserDefaults.standard.double(forKey: HostPreferences.locationLongitude))
        case .scenario(let name): try await display.setLocationScenario(name)
        }
    }

    // MARK: Pasteboard

    /// Whether the device exchanges its pasteboard with the Mac: like
    /// Simulator.app, a booted iPhone, iPad, or Apple Vision. Simulator.app
    /// also needs the device's pasteboard connected; since NeoSimulator
    /// connects only once a transfer or synchronization needs it, it needs
    /// the device's pasteboard feature instead.
    private var exchangesPasteboard: Bool {
        canPerformCommands && [.iPhone, .iPad, .vision].contains(capabilities.family)
            && capabilities.supportsFeature(DeviceCapabilities.pasteboard)
    }

    /// Whether Edit ▸ Get Pasteboard and Send Pasteboard are available. Like
    /// Simulator.app, they are not while pasteboards synchronize automatically.
    var canTransferPasteboard: Bool { exchangesPasteboard && !synchronizesPasteboard }

    /// Whether Edit ▸ Automatically Sync Pasteboard is on for this session.
    var synchronizesPasteboard: Bool { pasteboardSync?.isOn == true }

    /// Get Pasteboard or Send Pasteboard. Without automatic synchronization,
    /// nothing crosses between the Mac and the device otherwise. The first
    /// transfer connects to the device's pasteboard service. The connection
    /// stays open for later transfers and for data that the Mac pasteboard
    /// reads from the device only when an app pastes it. A failure, also one
    /// the device reports later, goes to `failure`.
    func transferPasteboard(_ transfer: PasteboardTransfer, failure: @escaping @MainActor (Error) -> Void) {
        guard canTransferPasteboard else { return }
        let report = { (reason: Error) in
            failure(HostError.operation(transfer == .get
                ? "Could not get the simulator's pasteboard: \(reason.localizedDescription)"
                : "Could not send the pasteboard to the simulator: \(reason.localizedDescription)"))
        }
        do {
            let connection = try pasteboardConnection ?? connectPasteboard()
            switch transfer {
            case .get:
                pendingPulls.append(report)
                do { try connection.pull() } catch { pendingPulls.removeLast(); throw error }
            case .send:
                pendingPushes.append(report)
                do { try connection.push() } catch { pendingPushes.removeLast(); throw error }
            }
        } catch {
            report(error)
        }
    }

    /// Starts synchronizing a device that just connected, while Automatically
    /// Sync Pasteboard is on: like Simulator.app when a device connects, it
    /// connects to the device's pasteboard and sends the Mac's.
    func startPasteboardSync() {
        guard synchronizesPasteboard, exchangesPasteboard, pasteboardConnection == nil else { return }
        do { try connectPasteboard().push() } catch {
            hostLog("Could not synchronize the pasteboard of \(device.name): \(error.localizedDescription)")
        }
    }

    /// Tells the device's pasteboard connection whether to synchronize, as
    /// Simulator.app's `updatePasteboardAutosyncStatus:` does after
    /// Automatically Sync Pasteboard changes and when a connected device is
    /// chosen again. Turning synchronization on connects a device that has no
    /// connection yet, which transfers nothing; turning it off keeps the
    /// connection for Get and Send Pasteboard.
    func updatePasteboardSync() {
        if let pasteboardConnection {
            setAutomaticSync(of: pasteboardConnection)
        } else if synchronizesPasteboard, exchangesPasteboard {
            do { _ = try connectPasteboard() } catch {
                hostLog("Could not synchronize the pasteboard of \(device.name): \(error.localizedDescription)")
            }
        }
    }

    /// Sends the Mac pasteboard after another device's pasteboard replaced
    /// it, as Simulator.app's `sendPasteboard:` does for synchronization. A
    /// Mac pasteboard that still holds what this device sent last is not sent
    /// back to it.
    func sendSynchronizedPasteboard() {
        guard let pasteboardConnection else { return }
        guard (hostPasteboard ?? .general).changeCount != lastReceivedGeneration else {
            hostLog("The Mac pasteboard still holds the pasteboard of \(device.name); it is not sent back")
            return
        }
        do { try pasteboardConnection.push() } catch {
            hostLog("Could not synchronize the pasteboard of \(device.name): \(error.localizedDescription)")
        }
    }

    private func connectPasteboard() throws -> any SimulatorPasteboard {
        let connection = try display.connectPasteboard(hostPasteboard ?? .general) { [weak self] in
            self?.handlePasteboard($0)
        }
        pasteboardConnection = connection
        isPasteboardActive = false
        // Like Simulator.app, each connection is told whether to synchronize.
        setAutomaticSync(of: connection)
        return connection
    }

    private func setAutomaticSync(of connection: any SimulatorPasteboard) {
        let enabled = synchronizesPasteboard
        do { try connection.setAutomaticSync(enabled) } catch {
            hostLog("Could not turn \(enabled ? "on" : "off") pasteboard synchronization of \(device.name): \(error.localizedDescription)")
        }
    }

    private func handlePasteboard(_ event: SimulatorPasteboardEvent) {
        switch event {
        case .activated:
            if isPasteboardActive, !pendingPushes.isEmpty { pendingPushes.removeFirst() }
            isPasteboardActive = true
        case .applied(let generation):
            if !pendingPulls.isEmpty { pendingPulls.removeFirst() }
            lastReceivedGeneration = generation
            pasteboardSync?.devicePasteboardDidReplaceHost(self)
        case .failedToApply(let error):
            lastReceivedGeneration = nil
            if pendingPulls.isEmpty {
                hostLog("Could not apply the pasteboard of \(device.name): \(error.localizedDescription)")
            } else {
                pendingPulls.removeFirst()(error)
            }
        case .lostConnection:
            let pending = pendingPulls + pendingPushes
            closePasteboard()
            hostLog("The pasteboard connection of \(device.name) closed")
            let error = HostError.operation("The simulator closed its pasteboard connection.")
            for report in pending { report(error) }
            // Like Simulator.app, a synchronized device connects again at
            // once, without sending the Mac's pasteboard. Otherwise the next
            // transfer connects.
            updatePasteboardSync()
        case .synchronizationChanged(let enabled):
            // Simulator.app asserts this; a late callback is only logged.
            if enabled != synchronizesPasteboard {
                hostLog("The pasteboard synchronization of \(device.name) turned \(enabled ? "on" : "off") while Automatically Sync Pasteboard is \(synchronizesPasteboard ? "on" : "off")")
            }
        }
    }

    private func closePasteboard() {
        pasteboardConnection?.disconnect()
        pasteboardConnection = nil
        pendingPulls.removeAll()
        pendingPushes.removeAll()
    }

    // MARK: Audio routes

    /// Whether I/O ▸ Audio Input and Audio Output apply to the device:
    /// `SimFeatureRoutableAudio`.
    var routesAudio: Bool { capabilities.supportsFeature(DeviceCapabilities.routableAudio) }

    /// The device's audio routes as its audio port last reported them; nil
    /// until the port connects, and when it cannot.
    private(set) var audioRoutes: AudioRouteState?
    @ObservationIgnored private var audioConnection: (any SimulatorAudioRoutes)?
    /// Why the device's audio port could not connect.
    @ObservationIgnored private var audioConnectionFailure: Error?

    /// Connects to the device's audio port and routes the guest to the app's
    /// recent routes, as Simulator.app does when a device connects. Each
    /// change the port then reports, of the Mac's devices or of the guest's
    /// routes, is shown and routed in the same way. The failures of these
    /// routes go to `failure`.
    func connectAudioRoutes(failure: @escaping @MainActor (Error) -> Void) {
        guard routesAudio, audioConnection == nil, !isDisconnected else { return }
        do {
            audioConnection = try display.connectAudioRoutes { [weak self] in self?.audioRoutesChanged(failure: failure) }
        } catch {
            audioConnectionFailure = error
            failure(error)
            return
        }
        audioRoutesChanged(failure: failure)
    }

    /// Like the handler of Simulator.app's audio client: shows the port's
    /// state, then synchronizes both directions with the recent routes.
    private func audioRoutesChanged(failure: @escaping @MainActor (Error) -> Void) {
        guard let audioConnection else { return }
        do {
            audioRoutes = try audioConnection.state()
        } catch {
            failure(HostError.operation("Could not read the audio routes of \(device.name): \(error.localizedDescription)"))
            return
        }
        synchronizeAudioRoute(in: .input, failure: failure)
        synchronizeAudioRoute(in: .output, failure: failure)
    }

    /// Routes `scope` to the first of the app's recent routes that the guest
    /// already uses or that the Mac has, as Simulator.app does for every
    /// device after a choice. When none is available, the route stays, as
    /// there. A device that routes audio but whose port did not connect
    /// reports why.
    func synchronizeAudioRoute(in scope: AudioScope, failure: @escaping @MainActor (Error) -> Void) {
        guard routesAudio, !isDisconnected else { return }
        let name = device.name
        guard let audioConnection, let state = audioRoutes else {
            let reason = audioConnectionFailure?.localizedDescription ?? "Its audio routes are unavailable."
            failure(HostError.operation("Could not change the audio \(scope.noun) of \(name): \(reason)"))
            return
        }
        switch state.decision(among: preferences.recentAudioRoutes(in: scope), in: scope) {
        case .current:
            break
        case .unavailable:
            hostLog("None of the recent audio \(scope.noun) devices is available for \(name)")
        case .route(let route):
            let title = route == AudioRouting.systemDefault
                ? "System" : state.devices(in: scope).first { $0.uid == route }?.name ?? route
            let report = { (error: Error) in
                failure(HostError.operation(
                    "Could not route the audio \(scope.noun) of \(name) to \(title): \(error.localizedDescription)"))
            }
            do {
                try audioConnection.route(scope, to: route) { error in
                    if let error { report(error) }
                }
            } catch {
                report(error)
            }
        }
    }

    // MARK: External displays

    /// The device's external display as CoreSimulator last reported it; nil
    /// before it connects, after the session disconnects, and for a device
    /// without one.
    private(set) var externalScreen: ExternalScreenState?
    /// The session's connection to the device's external display.
    @ObservationIgnored private var externalScreenConnection: (any SimulatorExternalScreen)?
    /// The modes the external display advertises, read when the session
    /// connects to it; nil before then or when they cannot be read.
    private var externalScreenModes: [ExternalScreenMode]?
    /// The changes sent to the device's external display, which the device's
    /// sessions share.
    @ObservationIgnored private let externalDisplayChanges: ExternalDisplayChanges
    /// Whether the session is looking for the external display, which
    /// SimulatorKit's screen adapter may not have listed yet, and the task
    /// that looks.
    @ObservationIgnored private var isLookingUpExternalScreen = false
    @ObservationIgnored private var externalScreenLookUp: Task<Void, Never>?
    /// The latest choice made while the session looks, which it applies when it ends.
    @ObservationIgnored private var choiceDuringLookUp: (mode: ExternalDisplayMode, failure: @MainActor (Error) -> Void)?
    @ObservationIgnored private let externalScreenLookUpSchedule: (attempts: Int, interval: Duration)
    /// Runs on the main actor after `externalScreen` changes.
    @ObservationIgnored var onExternalScreenChange: (() -> Void)?

    /// The External Displays item that the external display's actual state
    /// checks, or nil when no item does. Simulator.app checks the device's
    /// saved choice instead, which a failure or `simctl` leaves behind.
    var externalDisplayMode: ExternalDisplayMode? { externalScreen?.mode }

    /// Why the device cannot show `mode`, which its item then says and a
    /// choice of it reports, or nil when it can, or when the session has not
    /// read the external display's modes yet and so cannot tell.
    /// Simulator.app offers every item and sets the size anyway.
    func externalDisplayLimit(for mode: ExternalDisplayMode) -> ExternalDisplayLimit? {
        if let limit = capabilities.externalDisplayLimit(for: mode) { return limit }
        guard let size = mode.pixelSize, let modes = externalScreenModes else { return nil }
        do throws(ExternalDisplayLimit) {
            _ = try ExternalScreenMode.choice(for: size, scale: mode.scale, current: nil, among: modes)
            return nil
        } catch {
            return error
        }
    }

    /// The size the guest shows on the external display in `state` when it
    /// is not the display's size, as when another tool set a 120 Hz mode or
    /// 640×480 (see `ExternalScreenMode.guestSize(for:refreshRate:among:)`),
    /// or nil. A CarPlay screen shows the guest's CarPlay.
    func externalDisplayGuestSize(for state: ExternalScreenState) -> CGSize? {
        guard state.isPoweredOn, !state.isCarPlay, let modes = externalScreenModes else { return nil }
        let shown = ExternalScreenMode.guestSize(for: state.pixelSize, refreshRate: state.refreshRate, among: modes)
        return shown == state.pixelSize ? nil : shown
    }

    /// Connects to the device's external display and applies the device's
    /// saved choice, as Simulator.app does when a device connects: a size
    /// sets the display's mode, which also turns it on. Disabled leaves the
    /// display as it is, so a display that another tool turned on keeps its
    /// window, as in Simulator.app. Failures go to `failure`.
    ///
    /// SimulatorKit's screen adapter lists a device's screens from an
    /// enumeration that ends asynchronously, possibly after the device's own
    /// screen connects. A device's screens exist from its creation, so the
    /// external display is in that enumeration or the device has none. The
    /// session therefore looks for it as long as the host waits for the
    /// device's own screen, and applies the saved choice, or a choice made
    /// meanwhile, when it appears or the look-up ends.
    func connectExternalDisplay(failure: @escaping @MainActor (Error) -> Void) {
        guard capabilities.supportsExternalDisplays, !isDisconnected, externalScreenConnection == nil,
              !isLookingUpExternalScreen else { return }
        isLookingUpExternalScreen = true
        let schedule = externalScreenLookUpSchedule
        let name = device.name
        externalScreenLookUp = Task.immediate { [weak self] in
            var attempt = 1
            while true {
                guard let self, !Task.isCancelled, !self.isDisconnected else { return }
                let found: Bool
                do { found = try self.attachExternalScreen() } catch {
                    self.isLookingUpExternalScreen = false
                    let choice = self.choiceDuringLookUp
                    self.choiceDuringLookUp = nil
                    let reason = HostError.operation(
                        "Could not connect to the external display of \(name): \(error.localizedDescription)")
                    (choice?.failure ?? failure)(reason)
                    return
                }
                if found || attempt == schedule.attempts { break }
                attempt += 1
                try? await Task.sleep(for: schedule.interval)
            }
            self?.externalScreenLookUpEnded(failure: failure)
        }
    }

    private func externalScreenLookUpEnded(failure: @escaping @MainActor (Error) -> Void) {
        isLookingUpExternalScreen = false
        if let choice = choiceDuringLookUp {
            choiceDuringLookUp = nil
            applyExternalDisplay(choice.mode, failure: choice.failure)
        } else if let mode = ExternalDisplayMode(rawValue: preferences.externalDisplayTag(forDevice: device.id)),
                  mode != .disabled, mode != .carPlay || capabilities.supportsCarPlay {
            applyExternalDisplay(mode, failure: failure)
        }
    }

    /// I/O ▸ External Displays: saves the choice for the device, as
    /// Simulator.app does, then sets the external display's mode, which also
    /// turns it on, or turns it off for Disabled; CarPlay also starts the
    /// guest's CarPlay (see `ExternalDisplayChanges`). Because the choice is
    /// saved first, a device that is restarting applies it when it connects,
    /// and choosing again retries a failure. Failures, also those CoreSimulator
    /// reports later, go to `failure`, those of one choice together.
    func chooseExternalDisplay(_ mode: ExternalDisplayMode, failure: @escaping @MainActor (Error) -> Void) {
        guard capabilities.supportsExternalDisplays, mode != .carPlay || capabilities.supportsCarPlay else { return }
        preferences.setExternalDisplayTag(mode.rawValue, forDevice: device.id)
        guard canPerformCommands else { return }
        guard !isLookingUpExternalScreen else {
            choiceDuringLookUp = (mode, failure)
            return
        }
        applyExternalDisplay(mode, failure: failure)
    }

    /// A display of the external display for its window.
    func makeExternalDisplay() throws -> any SimulatorDisplay {
        guard let externalScreenConnection else { throw HostError.unavailable("The external display is not connected.") }
        return try externalScreenConnection.makeDisplay()
    }

    private func applyExternalDisplay(_ mode: ExternalDisplayMode, failure: @escaping @MainActor (Error) -> Void) {
        let name = device.name
        let report: @MainActor ([ExternalDisplayFailure]) -> Void = { failures in
            failure(Self.describe(failures, of: mode, deviceName: name))
        }
        do {
            // A device whose external display was not listed is asked again.
            if externalScreenConnection == nil { _ = try attachExternalScreen() }
            guard let externalScreenConnection else { throw HostError.unavailable("The device has no external display port.") }
            // Unlike Simulator.app, a size the device cannot show changes nothing.
            if let limit = externalDisplayLimit(for: mode) { throw limit }
            // Like Simulator.app, a choice on a device with CarPlay writes its
            // CarPlay configuration.
            externalDisplayChanges.apply(mode, through: externalScreenConnection,
                                         savesCarPlayConfiguration: capabilities.supportsCarPlay, report: report)
        } catch {
            report([ExternalDisplayFailure(step: .screen, error: error)])
        }
    }

    /// One error for the failures of a change to `mode`, a line for each.
    private static func describe(_ failures: [ExternalDisplayFailure], of mode: ExternalDisplayMode,
                                 deviceName name: String) -> HostError {
        HostError.operation(failures.map { failure in
            let reason = failure.error.localizedDescription
            return switch failure.step {
            case .carPlayConfiguration: "Could not save the CarPlay configuration of \(name): \(reason)"
            case .screen where mode == .disabled: "Could not turn off the external display of \(name): \(reason)"
            case .screen: "Could not set the external display of \(name) to \(mode.title): \(reason)"
            case .carPlaySession(starting: true): "Could not start CarPlay on \(name): \(reason)"
            case .carPlaySession(starting: false): "Could not stop CarPlay on \(name): \(reason)"
            case .carPlayService(creating: true): "Could not connect the CarPlay touch screen of \(name): \(reason)"
            case .carPlayService(creating: false): "Could not disconnect the CarPlay touch screen of \(name): \(reason)"
            }
        }.joined(separator: "\n"))
    }

    /// Connects to the external display when SimulatorKit lists it, and
    /// returns whether it did.
    private func attachExternalScreen() throws -> Bool {
        guard let screen = try display.connectExternalScreen(changed: { [weak self] in self?.externalScreenChanged() })
        else { return false }
        externalScreenConnection = screen
        do { externalScreenModes = try screen.supportedModes() } catch {
            hostLog("Could not read the external display modes of \(device.name): \(error.localizedDescription)")
        }
        externalScreenChanged()
        return true
    }

    private func externalScreenChanged() {
        guard let externalScreenConnection, !isDisconnected else { return }
        let state: ExternalScreenState?
        do { state = try externalScreenConnection.state() } catch {
            hostLog("Could not read the external display of \(device.name): \(error.localizedDescription)")
            state = nil
        }
        guard state != externalScreen else { return }
        externalScreen = state
        onExternalScreenChange?()
    }

    /// Whether the session has an external display, which disconnecting turns
    /// off, as quitting waits for.
    var hasExternalDisplay: Bool { externalScreenConnection != nil }

    /// Like Simulator.app, a disconnecting window turns off the external
    /// display of a device that stays booted, after a change in flight,
    /// keeping the device's choice and CarPlay configuration for its next
    /// connection; unlike Simulator.app, also a display that is off (see
    /// `ExternalDisplayChanges`), and ending the CarPlay that this host
    /// started, which Simulator.app's disconnection leaves to the guest.
    /// Simulator.app only logs a failure.
    private func disconnectExternalScreen() {
        externalScreenLookUp?.cancel()
        externalScreenLookUp = nil
        isLookingUpExternalScreen = false
        choiceDuringLookUp = nil
        let name = device.name
        if let externalScreenConnection {
            externalScreenConnection.disconnect()
            if display.isBooted {
                externalDisplayChanges.apply(.disabled, through: externalScreenConnection,
                                             savesCarPlayConfiguration: false) { failures in
                    hostLog(Self.describe(failures, of: .disabled, deviceName: name).localizedDescription)
                }
            } else {
                // The device shut down, so the changes sent through this
                // connection may never complete.
                externalDisplayChanges.abandon(changesThrough: externalScreenConnection)
            }
        }
        externalScreenConnection = nil
        externalScreenModes = nil
        externalScreen = nil
        onExternalScreenChange = nil
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
        rotateDisplay(followsGuest ? guestAngle ?? reading.displayAngle : reading.displayAngle)
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
        rotateDisplay(angle)
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
        rotateDisplay(reading.displayAngle)
    }

    private func rotateDisplay(_ degrees: Double) {
        displayAngle = degrees
        display.setRotation(degrees: degrees)
    }

    /// Saves the screen to a file chosen in a save panel, replacing it.
    func saveScreenshot(to destination: URL, mask: DeviceTools.ScreenMask) async throws {
        try await CaptureFile.write(to: destination, extension: "png") { temporary in
            try await tools.screenshot(to: temporary, mask: mask)
            try Self.checkPNG(at: temporary)
        }
    }

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

    /// Starts recording the screen. Like Simulator.app, the session announces
    /// the recording's start and end for the device's user-interface plugin.
    func startRecording(to destination: RecordingStore.Destination, mask: DeviceTools.ScreenMask) throws {
        guard canPerformCommands, recording == nil else { return }
        recording = try recordings.start(to: destination, process: { [makeRecordingProcess] in
            makeRecordingProcess($0, mask)
        }) { [weak self] in
            self?.recording = nil
            self?.display.announceRecording(started: false)
        }
        display.announceRecording(started: true)
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
        closePasteboard()
        audioConnection?.disconnect()
        audioConnection = nil
        // While the display is connected, its device reports whether it is booted.
        disconnectExternalScreen()
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
