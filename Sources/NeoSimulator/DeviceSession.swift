import AppKit
import Observation

/// Capabilities used for command visibility and availability.
struct DeviceCapabilities {
    /// `SimDeviceType.productFamilyID`.
    enum Family: Int { case iPhone = 1, iPad = 2, tv = 3, watch = 4, vision = 7 }

    var family: Family?
    /// `SimRuntime.version`, packed as major << 16 | minor << 8 | patch.
    var runtimeVersion: UInt32
    /// `SimDevice supportsFeature:`, which combines device-type and runtime support.
    var supportsFeature: (String) -> Bool
    /// Whether this presentation controls orientation through `devicectl`.
    /// Native compositions own their rotation; custom device sets are not addressable by this API.
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
    /// Vision displays have no bezel.
    var supportsDeviceBezels: Bool { family != .vision }
    var rotates: Bool { controlsOrientation && supportsFeature(Self.displayRotation) }
    var supportsExternalDisplays: Bool { supportsFeature(Self.externalDisplay) && supportsFeature(Self.integratedDisplay) }
    var supportsCarPlay: Bool { supportsExternalDisplays && supportsFeature(Self.carPlay) }
    /// Whether the device has a Digital Crown or Digital Dial, which the
    /// pointer's scrolling turns.
    var hasCrownOrDial: Bool { supportsFeature(Self.digitalCrown) || supportsFeature(Self.digitalDial) }

    /// Limits that apply regardless of the external screen's advertised modes.
    /// See `ExternalDisplayLimit.extendedDisplay` for the pre-iPadOS 27 failure.
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
    /// Apple Vision Pro's `SimFeatureHoverboard95880941`, required by Show Gaze Target.
    static let hoverboard = "com.apple.hid.hoverboard.95880941"
    static let standBy = "com.apple.display.ambient-overlay"
    /// `SimFeatureUIKitSlowMotionStateful`: the guest keeps slow animations on
    /// until they are turned off.
    static let slowMotionStateful = "com.apple.UIKit.SimulatorSlowMotionStateful"
    /// `SimFeatureUIKitGraphicsQualityOverride`.
    static let graphicsQualityOverride = "com.apple.UIKit.SimulatorGraphicsQualityOverride"
    /// `SimFeatureKeyboard`, required for hardware keyboard input.
    static let keyboard = "com.apple.hid.keyboard"
    /// SimFeatureTouchPressure, including 3D Touch.
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
    /// SimFeatureAlwaysOnDisplay; the watch dims instead of turning off.
    static let alwaysOnDisplay = "com.apple.display.aot"
    /// SimFeatureTVRemote.
    static let tvRemote = "com.apple.hid.tv-remote"
    /// `SimFeatureWatchGestures`: the watch takes Device ▸ Gestures.
    static let watchGestures = "com.apple.hid.watch.gestures"
    /// Digital Crown or Digital Dial input consumes pointer scrolling.
    static let digitalCrown = "com.apple.hid.digital-crown"
    static let digitalDial = "com.apple.hid.digital-dial"
    /// `SimFeatureFallDetection`: the watch takes Features ▸ Simulate Fall.
    static let fallDetection = "com.apple.motion.fall-detection"
}

/// Simulator-compatible standard-defaults keys.
enum HostPreferences {
    // UserDefaults provides thread-safe access; the suite itself is fixed for the process.
    nonisolated(unsafe) static let defaults: UserDefaults = {
#if NEOSIMULATOR_MANAGER
        UserDefaults(suiteName: "dev.lynnswap.NeoSimulator.Renderer") ?? .standard
#else
        .standard
#endif
    }()

    /// Moving the renderer into the app changes its defaults domain.
    /// Existing renderer settings remain editable in the new domain after this one-time copy.
    static func migrateStandalonePreferences(defaults: UserDefaults = .standard,
                                             sourceDomain: String = "dev.lynnswap.NeoSimulator",
                                             targetDomain: String = "dev.lynnswap.NeoSimulator.Renderer") {
        SimulatorPreferences.migrateStandalonePreferences(defaults: defaults, sourceDomain: sourceDomain,
                                                          targetDomain: targetDomain)
    }

    /// SimulatorKit reads this standard-defaults key to follow the guest's interface orientation.
    static let rotateWindowWhenSignaledByGuest = "RotateWindowWhenSignaledByGuest"
    /// Debug ▸ Show Parallel Testing Devices, on unless turned off.
    static let showTestingDevices = "ShowTestingDevices"
    /// Window ▸ Show Device Bezels, on unless turned off. It applies to every
    /// device window: see `PreferenceStore.showsDeviceBezels`.
    static let showChrome = "ShowChrome"
    /// Title-bar style preferences; see `DeviceToolbar.style`.
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
    /// Per-device preferences keyed by UDID.
    static let devicePreferences = "DevicePreferences"
    /// I/O ▸ Keyboard ▸ Use the Same Keyboard Language as macOS, on unless
    /// turned off: see `PreferenceStore.syncsKeyboardLanguage`.
    static let enableKeyboardSync = "EnableKeyboardSync"
    /// Per-device hardware keyboard preference, with an app-wide default.
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
    /// Whether dragging the bezel moves the window; defaults to on.
    static let allowsMoveByDragOnWindowChrome = "AllowsMoveByDragOnWindowChrome"

    /// Registers shared defaults. Pasteboard synchronization is opt-in.
    /// Show Pinch Gestures follows Simulator.app's registered default, not its Settings.bundle fallback.
    static func registerDefaults() {
        HostPreferences.defaults.register(defaults: [
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

    /// Uses an existing macOS screenshot folder, otherwise Desktop.
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

/// Per-device location selection, persisted as the last app-wide choice.
enum LocationSelection: Equatable {
    case none, custom
    /// A runtime scenario, by its `LocationScenario.name`.
    case scenario(String)

    static let noneMode = 5101, customMode = 5102
    /// Scenario menu tag stored in Simulator.app preferences.
    static let scenarioMode = 5103

    /// Unknown modes or scenarios unavailable to this device restore as None.
    static func saved(among scenarios: [LocationScenario]) -> Self {
        let defaults = HostPreferences.defaults
        let mode = defaults.integer(forKey: HostPreferences.locationMode)
        guard mode > customMode else { return mode == customMode ? .custom : .none }
        guard let name = defaults.string(forKey: HostPreferences.locationScenario),
              scenarios.contains(where: { $0.name == name }) else { return .none }
        return .scenario(name)
    }

    /// Persists for the next connection. None retains the previous scenario name.
    func save() {
        let defaults = HostPreferences.defaults
        switch self {
        case .none: defaults.set(Self.noneMode, forKey: HostPreferences.locationMode)
        case .custom: defaults.set(Self.customMode, forKey: HostPreferences.locationMode)
        case .scenario(let name):
            defaults.set(name, forKey: HostPreferences.locationScenario)
            defaults.set(Self.scenarioMode, forKey: HostPreferences.locationMode)
        }
    }
}

/// Shared desired locations survive a renderer handoff without replacing another device's choice.
struct DeviceLocationPreset {
    let selection: LocationSelection
    let coordinate: (latitude: Double, longitude: Double)?

    static func load(for identifier: String, among scenarios: [LocationScenario]) throws -> Self? {
        let defaults = try store()
        guard defaults.synchronize() else { throw HostError.operation("Could not read the saved simulator location.") }
        let key = "DeviceLocationPreset.\(identifier)"
        guard let value = defaults.object(forKey: key) else { return nil }
        guard let record = value as? [String: Any], let mode = record["mode"] as? String else {
            throw HostError.operation("The saved simulator location is invalid.")
        }
        switch mode {
        case "none": return Self(selection: .none, coordinate: nil)
        case "custom":
            guard let latitude = record["latitude"] as? Double, let longitude = record["longitude"] as? Double,
                  (-90...90).contains(latitude), (-180...180).contains(longitude) else {
                throw HostError.operation("The saved simulator coordinates are invalid.")
            }
            return Self(selection: .custom, coordinate: (latitude, longitude))
        case "scenario":
            guard let name = record["scenario"] as? String else {
                throw HostError.operation("The saved simulator location scenario is invalid.")
            }
            return Self(selection: scenarios.contains { $0.name == name } ? .scenario(name) : .none, coordinate: nil)
        default: throw HostError.operation("The saved simulator location is invalid.")
        }
    }

    func save(for identifier: String) throws {
        let defaults = try Self.store()
        var record: [String: Any]
        switch selection {
        case .none: record = ["mode": "none"]
        case .custom:
            guard let coordinate else { throw HostError.operation("No simulator coordinates were provided.") }
            record = ["mode": "custom", "latitude": coordinate.latitude, "longitude": coordinate.longitude]
        case .scenario(let name): record = ["mode": "scenario", "scenario": name]
        }
        defaults.set(record, forKey: "DeviceLocationPreset.\(identifier)")
        guard defaults.synchronize() else { throw HostError.operation("Could not save the simulator location.") }
    }

    private static func store() throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: "dev.lynnswap.NeoSimulator") else {
            throw HostError.operation("The simulator location settings are unavailable.")
        }
        return defaults
    }
}

/// A physical device orientation, named as `devicectl` names it.
enum DeviceOrientation: String, CaseIterable {
    case portrait, landscapeRight, portraitUpsideDown, landscapeLeft, faceUp, faceDown

    /// Display rotation for an upright view of this orientation. Flat orientations keep the previous angle.
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

/// Hardware-input event timing.
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

/// The guest's `com.apple.sos.user-fell` state and Simulator.app menu tags.
enum FallResolution: UInt64 {
    case confirmed = 0, dismissed = 1, rejected = 2, unresponsive = 3
}

/// Owns a connected device's display, input, tools, and device-changing operations.
/// Window controllers present this state and report its failures.
@MainActor @Observable
final class DeviceSession {
    let device: AvailableDevice
    let capabilities: DeviceCapabilities
    @ObservationIgnored let primaryDisplay: any SimulatorDisplay
    @ObservationIgnored private var appDisplay: (any SimulatorDisplay)?
    var display: any SimulatorDisplay { appDisplay ?? primaryDisplay }
    @ObservationIgnored var onDisplayWillChange: (() -> Void)?
    @ObservationIgnored var onDisplayChange: (() -> Void)?
    @ObservationIgnored var onAppResizeGeometryChange: (() -> Void)?
    @ObservationIgnored var onAppResizeError: ((any Error) -> Void)?
    @ObservationIgnored private var resizeTransport: (any SimulatorAppResizeTransport)?
    @ObservationIgnored private var resizePreparation: Task<Void, Never>?
    @ObservationIgnored private var resizeObservation: Task<Void, Never>?
    @ObservationIgnored private var resizeStart: Task<Void, Never>?
    @ObservationIgnored private var resizeUpdates: Task<Void, Never>?
    @ObservationIgnored private var resizeInvalidation: Task<Void, Never>?
    @ObservationIgnored private var resizeAdjustment: Task<Void, Never>?
    @ObservationIgnored private var resizeLease: (any SimulatorAppResizeLease)?
    @ObservationIgnored private var resizeGeneration = 0
    @ObservationIgnored private var pendingAppSize: CGSize?
    private(set) var supportsAppResize = false
    private(set) var appResizeEligibility = AppResizeEligibility.unavailable
    private(set) var isStartingAppResize = false
    private(set) var appResizeGeometry: AppResizeGeometry?
    private(set) var isResizingApp = false
    var canResizeApp: Bool {
        canPerformToolOperation && recording == nil && supportsAppResize
            && (isResizingApp || isStartingAppResize || appResizeEligibility == .eligible)
    }
    @ObservationIgnored let tools: DeviceTools
    /// Keeps the device's keyboard preferences and the app-wide ones.
    @ObservationIgnored private let preferences: any PreferenceStore
    /// The Mac keyboard's language, which Use the Same Keyboard Language as
    /// macOS gives the guest, or nil when it cannot be determined.
    @ObservationIgnored private let hostKeyboardLanguage: @MainActor () -> String?
    @ObservationIgnored private let recordings: RecordingStore
    @ObservationIgnored private let makeRecordingProcess: (URL, DeviceTools.ScreenMask, UInt32?) -> Process
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
    /// Mac pasteboard generation last received from this device; nil after a failed replacement.
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
    /// The generation of each input's release that SimulatorKit has not
    /// reported on yet, which `releaseHeldInput(_:report:)` does not send again.
    @ObservationIgnored private var releasesInFlight: [HIDInput: Int] = [:]
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
    /// Last location applied by the host; CoreSimulator does not report the guest's location.
    private(set) var location: LocationSelection?

    /// The pasteboard is untouched until a transfer or synchronization starts.
    /// `externalScreenTimeout` defaults to the host's wait for the primary screen.
    init(device: AvailableDevice, capabilities: DeviceCapabilities, display: any SimulatorDisplay,
         tools: DeviceTools, recordings: RecordingStore = RecordingStore(),
         recordingProcess: ((URL, DeviceTools.ScreenMask) -> Process)? = nil,
         openLog: @escaping (URL) async throws -> Void = DeviceSession.openInConsole,
         preferences: any PreferenceStore = HostPreferences.defaults,
         hostKeyboardLanguage: @escaping @MainActor () -> String? = HostKeyboard.language,
         pasteboard: NSPasteboard? = nil, pasteboardSync: PasteboardSync? = nil,
         externalDisplayChanges: ExternalDisplayChanges = ExternalDisplayChanges(),
         externalScreenTimeout: Duration = .seconds(10),
         appResizeTransport: (@MainActor () async throws -> (any SimulatorAppResizeTransport)?)? = nil) {
        self.device = device
        self.externalDisplayChanges = externalDisplayChanges
        self.externalScreenTimeout = externalScreenTimeout
        self.capabilities = capabilities
        self.primaryDisplay = display
        self.tools = tools
        self.preferences = preferences
        self.hostKeyboardLanguage = hostKeyboardLanguage
        hostPasteboard = pasteboard
        self.pasteboardSync = pasteboardSync
        self.recordings = recordings
        let codec: DeviceTools.VideoCodec = capabilities.family == .vision ? .hevc : .h264
        if let recordingProcess { makeRecordingProcess = { url, mask, _ in recordingProcess(url, mask) } }
        else { makeRecordingProcess = { tools.recordingProcess(to: $0, mask: $1, codec: codec, displayID: $2) } }
        self.openLog = openLog
        if let appResizeTransport { prepareAppResize(appResizeTransport) }
    }

    private func prepareAppResize(_ make: @escaping @MainActor () async throws -> (any SimulatorAppResizeTransport)?) {
        resizePreparation = Task { [weak self] in
            do {
                guard let transport = try await make() else { return }
                try Task.checkCancellation()
                guard let self, !self.isDisconnected else { return }
                self.resizeTransport = transport
                self.supportsAppResize = true
                self.resizeObservation = Task { [weak self] in
                    do {
                        let stream = try await transport.eligibility()
                        for try await state in stream {
                            try Task.checkCancellation()
                            guard let self, !self.isDisconnected else { return }
                            self.appResizeEligibility = state
                            if state == .unavailable { self.stopAppResize() }
                        }
                        guard let self, !self.isDisconnected, !Task.isCancelled else { return }
                        self.supportsAppResize = false
                        self.stopAppResize()
                        self.onAppResizeError?(HostError.unavailable("App resize observation ended."))
                    } catch {
                        guard let self, !self.isDisconnected, !(error is CancellationError) else { return }
                        self.supportsAppResize = false
                        self.stopAppResize()
                        self.onAppResizeError?(error)
                    }
                }
            } catch {
                guard let self, !self.isDisconnected, !(error is CancellationError) else { return }
                self.onAppResizeError?(error)
            }
        }
    }

    func toggleAppResize(size: CGSize) {
        if isResizingApp || isStartingAppResize || resizeLease != nil { stopAppResize(); return }
        guard canResizeApp, let resizeTransport else { return }
        resizeGeneration += 1
        let token = resizeGeneration
        isStartingAppResize = true
        resizeStart = Task { [weak self, primaryDisplay] in
            var lease: (any SimulatorAppResizeLease)?
            var display: (any SimulatorDisplay)?
            do {
                let created = try await resizeTransport.start(size: size, cornerRadius: 0)
                lease = created
                try Task.checkCancellation()
                guard let self, !self.isDisconnected, self.resizeGeneration == token else { throw CancellationError() }
                self.resizeLease = created
                // Observe invalidation before waiting for the screen: the guest can end
                // the session while SimulatorKit is still publishing the display.
                self.resizeInvalidation = Task { [weak self] in
                    do { try await created.awaitInvalidation() }
                    catch { if !(error is CancellationError) { self?.onAppResizeError?(error) } }
                    guard let self, self.resizeGeneration == token, !Task.isCancelled else { return }
                    self.stopAppResize()
                }
                let connected = try await primaryDisplay.connectAppDisplay(uniqueID: created.displayUniqueID)
                display = connected
                try Task.checkCancellation()
                guard !self.isDisconnected, self.resizeGeneration == token else { throw CancellationError() }
                self.releaseInputsForDisplayChange()
                self.onDisplayWillChange?()
                self.appDisplay = connected
                self.isResizingApp = true
                self.isStartingAppResize = false
                self.appResizeGeometry = created.geometry
                self.onDisplayChange?()
                self.resizeUpdates = Task { [weak self] in
                    do {
                        for try await geometry in try created.updates() {
                            try Task.checkCancellation()
                            guard let self, self.resizeGeneration == token else { return }
                            self.appResizeGeometry = geometry
                            self.onAppResizeGeometryChange?()
                        }
                    } catch {
                        guard let self, self.resizeGeneration == token, !(error is CancellationError) else { return }
                        self.stopAppResize()
                        self.onAppResizeError?(error)
                    }
                }
            } catch {
                display?.disconnect()
                if let lease {
                    do { try lease.invalidate() }
                    catch let cleanup { self?.onAppResizeError?(HostError.operation("\(error.localizedDescription)\nResize cleanup failed: \(cleanup.localizedDescription)")) }
                }
                guard let self, self.resizeGeneration == token else { return }
                self.stopAppResize()
                if !(error is CancellationError) { self.onAppResizeError?(error) }
            }
        }
    }

    /// Requests guest point geometry; native scene feedback remains authoritative.
    func resizeApp(to size: CGSize) {
        guard isResizingApp, let geometry = appResizeGeometry,
              size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        pendingAppSize = CGSize(width: min(max(size.width, geometry.minimumSize.width), geometry.maximumSize.width),
                                height: min(max(size.height, geometry.minimumSize.height), geometry.maximumSize.height))
        guard resizeAdjustment == nil, let lease = resizeLease else { return }
        let token = resizeGeneration
        resizeAdjustment = Task { [weak self] in
            defer { if let self, self.resizeGeneration == token { self.resizeAdjustment = nil } }
            do {
                while let self, self.resizeGeneration == token, let size = self.pendingAppSize {
                    self.pendingAppSize = nil
                    try await lease.adjust(size: size, cornerRadius: 0)
                    try Task.checkCancellation()
                }
            } catch {
                guard let self, self.resizeGeneration == token, !(error is CancellationError) else { return }
                self.stopAppResize()
                self.onAppResizeError?(error)
            }
        }
    }

    func stopAppResize() {
        resizeGeneration += 1
        resizeStart?.cancel(); resizeStart = nil
        resizeUpdates?.cancel(); resizeUpdates = nil
        resizeInvalidation?.cancel(); resizeInvalidation = nil
        resizeAdjustment?.cancel(); resizeAdjustment = nil
        pendingAppSize = nil
        isStartingAppResize = false
        if let appDisplay {
            recording?.stop()
            releaseInputsForDisplayChange()
            onDisplayWillChange?()
            self.appDisplay = nil
            isResizingApp = false
            appResizeGeometry = nil
            primaryDisplay.setRotation(degrees: displayAngle)
            onDisplayChange?()
            appDisplay.disconnect()
        }
        if let resizeLease {
            do { try resizeLease.invalidate(); self.resizeLease = nil }
            catch { onAppResizeError?(error) }
        }
    }

    private func releaseInputsForDisplayChange() {
        for event in downInputs.keys {
            if let up = try? releaseMessage(for: event) { try? display.send(up, completion: nil) }
        }
        pendingHolds.removeAll()
        downInputs.removeAll()
        releasesInFlight.removeAll()
        remoteReports.removeAll()
        isTouchingRemote = false
        inputSteps.values.forEach { $0.cancel() }
        inputSteps.removeAll()
    }

    var canPerformCommands: Bool { isConnected && display.isBooted }
    var canPerformToolOperation: Bool { canPerformCommands && !isBusy }
    var canStartRecording: Bool { canPerformToolOperation && recording == nil && !isStartingAppResize }

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

    /// Creates both events before sending either, so construction failure cannot leave the input down.
    @discardableResult
    private func press(_ event: HIDInput, _ report: FirstFailure) -> Bool {
        guard canPerformCommands, let down = message(event, .down, report),
              let up = message(event, .up, report), send(down, report) else { return false }
        return sendRelease(up, generation: markDown(event), report)
    }

    // Release remains available during shutdown because shutdown can fail.
    // Construct the release at hold end so its timestamp includes the hold duration.
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

    /// The input remains down until delivery of this release, unless a newer press or hold keeps it down.
    @discardableResult
    private func sendRelease(_ up: HIDMessage, generation: Int, _ report: FirstFailure) -> Bool {
        let event = up.input
        releasesInFlight[event] = generation
        do {
            try display.send(up) { [weak self] error in
                if let self, self.releasesInFlight[event] == generation { self.releasesInFlight[event] = nil }
                if let error {
                    report(error)
                } else if let self, self.downInputs[event] == generation, self.pendingHolds[event] == nil {
                    self.downInputs[event] = nil
                }
            }
            return true
        } catch {
            if releasesInFlight[event] == generation { releasesInFlight[event] = nil }
            report(error)
            return false
        }
    }

    /// Retries an undelivered release, but never duplicates one still awaiting delivery.
    private func releaseHeldInput(_ event: HIDInput, report: FirstFailure) {
        guard !isDisconnected, display.isBooted, let generation = downInputs[event],
              releasesInFlight[event] != generation else { return }
        let up: HIDMessage
        do { up = try releaseMessage(for: event) } catch {
            report(error)
            return
        }
        sendRelease(up, generation: generation, report)
    }

    /// The release of a held input: its up event, or for the remote's touch
    /// the end at its last point.
    private func releaseMessage(for event: HIDInput) throws -> HIDMessage {
        guard event == .tvRemoteTouch else { return try display.message(for: event, .up) }
        return try display.message(for: TVRemoteTouch(phase: .ended, point: remoteTouchPoint))
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

    // MARK: Apple TV Remote

    /// First failure per held remote input; release delivery removes it from `downInputs`.
    @ObservationIgnored private var remoteReports: [HIDInput: FirstFailure] = [:]
    /// Whether the remote is touching its surface, and the touch's last
    /// point, which its end repeats.
    @ObservationIgnored private var isTouchingRemote = false
    @ObservationIgnored private var remoteTouchPoint = CGPoint.zero

    /// Only Apple TV accepts remote input.
    private var takesTVRemote: Bool { capabilities.family == .tv }

    /// Holds a remote button until `releaseRemoteButton(_:)`.
    func pressRemoteButton(_ button: TVRemoteButton, failure: @escaping @MainActor (Error) -> Void) {
        guard canPerformCommands, takesTVRemote else { return }
        let report = FirstFailure(failure)
        let event = HIDInput.tvRemote(button)
        guard let down = message(event, .down, report), send(down, report) else { return }
        markDown(event)
        remoteReports[event] = report
    }

    /// Releases a remote button. An undelivered release is retried by the next release or disconnection.
    func releaseRemoteButton(_ button: TVRemoteButton) {
        let event = HIDInput.tvRemote(button)
        guard let report = remoteReports[event] else { return }
        releaseHeldInput(event, report: report)
    }

    /// Starts or moves a remote touch, in normalized coordinates from the top-left corner.
    func touchRemote(at point: CGPoint, failure: @escaping @MainActor (Error) -> Void) {
        guard canPerformCommands, takesTVRemote, !isTouchingRemote || point != remoteTouchPoint else { return }
        let report = isTouchingRemote ? remoteReports[.tvRemoteTouch] ?? FirstFailure(failure) : FirstFailure(failure)
        let touch = TVRemoteTouch(phase: isTouchingRemote ? .moved : .began, point: point)
        let message: HIDMessage
        do { message = try display.message(for: touch) } catch {
            report(error)
            return
        }
        guard send(message, report) else { return }
        if touch.phase == .began {
            markDown(.tvRemoteTouch)
            remoteReports[.tvRemoteTouch] = report
            isTouchingRemote = true
        }
        remoteTouchPoint = point
    }

    /// Releases held remote inputs, including failed releases. Also called during disconnection.
    func releaseRemoteInputs() {
        isTouchingRemote = false
        for (event, report) in remoteReports { releaseHeldInput(event, report: report) }
    }

    /// Ends the remote touch. An undelivered end is retried by the next release or disconnection.
    func liftRemoteTouch(at point: CGPoint) {
        guard let report = remoteReports[.tvRemoteTouch] else { return }
        if isTouchingRemote {
            isTouchingRemote = false
            remoteTouchPoint = point
        }
        releaseHeldInput(.tvRemoteTouch, report: report)
    }

    /// Watch backlight state: 0 or 1 means Always On is selected; 2 clears it. Other values preserve it.
    private(set) var showsAlwaysOn = false

    /// Refreshes Always On when the display connects or its properties change.
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

    /// Reports a simulated fall and its resolution to the guest.
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

    /// Changes text size, clamped to the supported accessibility range.
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

    var supportsKeyboard: Bool { capabilities.supportsFeature(DeviceCapabilities.keyboard) }

    /// The per-device keyboard preference controls both host typing and the guest keyboard.
    var connectsHardwareKeyboard: Bool {
        supportsKeyboard && preferences.connectsHardwareKeyboard(forDevice: device.identity.preferenceIdentifier)
    }

    /// Saves the choice before applying it, so a failed change remains selected and can be retried.
    func toggleHardwareKeyboard() async throws {
        guard canPerformCommands else { return }
        let connects = !preferences.connectsHardwareKeyboard(forDevice: device.identity.preferenceIdentifier)
        preferences.setConnectsHardwareKeyboard(connects, forDevice: device.identity.preferenceIdentifier)
        try await display.setHardwareKeyboardConnected(connects)
    }

    /// Use the Same Keyboard Language as macOS, an app-wide preference.
    var syncsKeyboardLanguage: Bool { preferences.syncsKeyboardLanguage }

    /// Updates only the preference; language applies at the next connection or input-source change.
    func toggleKeyboardLanguageSync() {
        preferences.set(!preferences.syncsKeyboardLanguage, forKey: HostPreferences.enableKeyboardSync)
    }

    /// Applies the Mac input-source language while keyboard-language synchronization is enabled.
    func syncKeyboardLanguage() async throws {
        guard canPerformCommands, preferences.syncsKeyboardLanguage else { return }
        guard let language = hostKeyboardLanguage() else {
            throw HostError.operation("Could not determine the language of the Mac's keyboard.")
        }
        try await display.setKeyboardLanguage(language)
    }

    /// Applies the per-device keyboard choice, then the Mac input-source language.
    /// Each failure is reported independently; the app-wide choice is only a fallback.
    func applyKeyboardSettings(failure: (Error) -> Void) async {
        guard canPerformCommands else { return }
        do { try await display.setHardwareKeyboardConnected(preferences.connectsHardwareKeyboard(forDevice: device.identity.preferenceIdentifier)) }
        catch { failure(error) }
        do { try await syncKeyboardLanguage() } catch { failure(error) }
    }

    // MARK: Debug

    private static let slowMotionAnimation = "com.apple.UIKit.SimulatorSlowMotionAnimationState"
    private static let forceGraphicsQuality = "com.apple.UIKit.ForceGraphicsQuality"

    /// Stateful slow animations, as opposed to a frontmost-app toggle.
    var keepsSlowAnimations: Bool { capabilities.supportsFeature(DeviceCapabilities.slowMotionStateful) }

    /// The app preference, independent of guest state.
    var slowAnimations: Bool { HostPreferences.defaults.bool(forKey: HostPreferences.slowMotionAnimation) }

    /// Toggles the preference and sends it to the guest.
    func toggleSlowAnimations() throws {
        guard canPerformCommands else { return }
        let enabled = !slowAnimations
        try send(enabled ? 1 : 0, to: Self.slowMotionAnimation) {
            HostPreferences.defaults.set(enabled, forKey: HostPreferences.slowMotionAnimation)
        }
    }

    var graphicsQuality: GraphicsQuality? {
        GraphicsQuality(rawValue: HostPreferences.defaults.integer(forKey: HostPreferences.graphicsQualityOverride))
    }

    /// Sends the quality to the guest and saves it as `GraphicsQualityOverride`.
    func setGraphicsQuality(_ quality: GraphicsQuality) throws {
        guard canPerformCommands else { return }
        try send(UInt64(quality.rawValue), to: Self.forceGraphicsQuality) {
            HostPreferences.defaults.set(quality.rawValue, forKey: HostPreferences.graphicsQualityOverride)
        }
    }

    /// Stops PineBoard so launchd restarts it with the new graphics quality.
    func restartSystemUI() async throws { try await tools.stopSystemUI() }

    /// Applies slow animations and non-default graphics quality when the device connects.
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

    static func openInConsole(_ log: URL) async throws {
        guard let console = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Console") else {
            throw HostError.unavailable("Console is not installed.")
        }
        _ = try await NSWorkspace.shared.open([log], withApplicationAt: console,
                                              configuration: NSWorkspace.OpenConfiguration())
    }

    /// Writes the guest's memory-warning trigger file and reports write failures.
    /// A successful write does not establish that an app handled the warning.
    func simulateMemoryWarning() throws {
        guard canPerformCommands else { return }
        try Data().write(to: display.memoryWarningFile())
    }

    // MARK: Location

    /// Reflects a location already applied by the manager without applying it again.
    func refreshLocationSelection() throws {
        if let preset = try DeviceLocationPreset.load(for: device.identity.preferenceIdentifier, among: locationScenarios) {
            location = preset.selection
        }
    }

    /// Restores the saved location after loading the runtime's scenarios. No scenarios means no selection.
    func restoreLocation() async throws {
        let scenarios = try await display.locationScenarios()
        // Right after a boot, listing takes up to a second. The session can
        // end meanwhile, and a choice made meanwhile is kept.
        guard !isDisconnected else { return }
        locationScenarios = scenarios
        guard !scenarios.isEmpty, location == nil else { return }
        if let preset = try DeviceLocationPreset.load(for: device.identity.preferenceIdentifier, among: scenarios) {
            try await use(preset.selection, coordinate: preset.coordinate, savesDevicePreset: false)
        } else {
            try await use(.saved(among: scenarios), savesDevicePreset: false)
        }
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
        HostPreferences.defaults.set(latitude, forKey: HostPreferences.locationLatitude)
        HostPreferences.defaults.set(longitude, forKey: HostPreferences.locationLongitude)
        try await use(.custom, coordinate: (latitude, longitude))
    }

    // Save before applying so failure preserves the choice for retry.
    private func use(_ selection: LocationSelection, coordinate: (latitude: Double, longitude: Double)? = nil,
                     savesDevicePreset: Bool = true) async throws {
        location = selection
        selection.save()
        var savedCoordinate = coordinate
        if savedCoordinate == nil, selection == .custom {
            savedCoordinate = try DeviceLocationPreset.load(for: device.identity.preferenceIdentifier, among: locationScenarios)?.coordinate
        }
        let coordinate = savedCoordinate ?? (HostPreferences.defaults.double(forKey: HostPreferences.locationLatitude),
                                              HostPreferences.defaults.double(forKey: HostPreferences.locationLongitude))
        if savesDevicePreset {
            try DeviceLocationPreset(selection: selection, coordinate: selection == .custom ? coordinate : nil).save(for: device.identity.preferenceIdentifier)
        }
        switch selection {
        case .none: try await display.clearSimulatedLocation()
        case .custom:
            try await display.setLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        case .scenario(let name): try await display.setLocationScenario(name)
        }
    }

    // MARK: Pasteboard

    /// Requires a booted iPhone, iPad, or Vision device with the pasteboard feature.
    /// The service connects lazily on the first transfer or synchronization.
    private var exchangesPasteboard: Bool {
        canPerformCommands && [.iPhone, .iPad, .vision].contains(capabilities.family)
            && capabilities.supportsFeature(DeviceCapabilities.pasteboard)
    }

    /// Manual transfer is unavailable during automatic synchronization.
    var canTransferPasteboard: Bool { exchangesPasteboard && !synchronizesPasteboard }

    /// Whether Edit ▸ Automatically Sync Pasteboard is on for this session.
    var synchronizesPasteboard: Bool { pasteboardSync?.isOn == true }

    /// Transfers the pasteboard, connecting lazily and reporting immediate or later failures.
    /// The connection stays open for subsequent transfers and lazy pasteboard data.
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

    /// Starts synchronization on connection by sending the Mac pasteboard to the device.
    func startPasteboardSync() {
        guard synchronizesPasteboard, exchangesPasteboard, pasteboardConnection == nil else { return }
        do { try connectPasteboard().push() } catch {
            hostLog("Could not synchronize the pasteboard of \(device.name): \(error.localizedDescription)")
        }
    }

    /// Updates synchronization without transferring data. Enabling connects lazily;
    /// disabling keeps the connection available for manual transfers.
    func updatePasteboardSync() {
        if let pasteboardConnection {
            setAutomaticSync(of: pasteboardConnection)
        } else if synchronizesPasteboard, exchangesPasteboard {
            do { _ = try connectPasteboard() } catch {
                hostLog("Could not synchronize the pasteboard of \(device.name): \(error.localizedDescription)")
            }
        }
    }

    /// Sends changes received from another device without echoing this device's last pasteboard back.
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
            // Reconnect synchronization immediately; manual transfers reconnect on demand.
            updatePasteboardSync()
        case .synchronizationChanged(let enabled):
            // A late callback can disagree with the current synchronization preference.
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

    /// Connects the audio port and restores the device's route initially and when host devices change.
    /// Routing failures go to `failure`.
    func connectAudioRoutes(failure: @escaping @MainActor (Error) -> Void) {
        guard routesAudio, audioConnection == nil, !isDisconnected else { return }
        do {
            audioConnection = try display.connectAudioRoutes { [weak self] change in
                self?.audioRoutesChanged(change, failure: failure)
            }
        } catch {
            audioConnectionFailure = error
            failure(error)
            return
        }
        audioRoutesChanged(.availableDevices, failure: failure)
    }

    /// Guest route reports are observations, including changes made by the manager or other tools.
    private func audioRoutesChanged(_ change: AudioRouteChange, failure: @escaping @MainActor (Error) -> Void) {
        guard let audioConnection else { return }
        do {
            audioRoutes = try audioConnection.state()
        } catch {
            failure(HostError.operation("Could not read the audio routes of \(device.name): \(error.localizedDescription)"))
            return
        }
        if case .availableDevices = change {
            synchronizeAudioRoute(in: .input, failure: failure)
            synchronizeAudioRoute(in: .output, failure: failure)
        }
    }

    /// An explicit app-menu command applies to every window and becomes that device's saved choice.
    func applyChosenAudioRoute(in scope: AudioScope, failure: @escaping @MainActor (Error) -> Void) {
        guard routesAudio, !isDisconnected else { return }
        do {
            if let route = preferences.recentAudioRoutes(in: scope).first {
                try preferences.saveAudioRoute(route, forDevice: device.identity.preferenceIdentifier, in: scope)
            }
            synchronizeAudioRoute(in: scope, failure: failure)
        } catch { failure(error) }
    }

    /// Prefers the device's saved route, falling back to recent routes available on the Mac.
    /// Keeps the current route when none is available; reports a failed port connection.
    func synchronizeAudioRoute(in scope: AudioScope, failure: @escaping @MainActor (Error) -> Void) {
        guard routesAudio, !isDisconnected else { return }
        let name = device.name
        guard let audioConnection, let state = audioRoutes else {
            let reason = audioConnectionFailure?.localizedDescription ?? "Its audio routes are unavailable."
            failure(HostError.operation("Could not change the audio \(scope.noun) of \(name): \(reason)"))
            return
        }
        let preferred: [String]
        do { preferred = try preferences.preferredAudioRoutes(forDevice: device.identity.preferenceIdentifier, in: scope) }
        catch { failure(error); return }
        switch state.decision(among: preferred, in: scope) {
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

    /// Last external screen state; nil while disconnected or unavailable.
    private(set) var externalScreen: ExternalScreenState?
    /// The session's connection to the device's external display.
    @ObservationIgnored private var externalScreenConnection: (any SimulatorExternalScreen)?
    /// The modes the external display advertises, read when the session
    /// connects to it; nil before then or when they cannot be read.
    private var externalScreenModes: [ExternalScreenMode]?
    /// The changes sent to the device's external display, which the device's
    /// sessions share.
    @ObservationIgnored private let externalDisplayChanges: ExternalDisplayChanges
    /// Held until the adapter reports the external display or this session disconnects.
    @ObservationIgnored private var externalScreenRegistration: AnyObject?
    /// Ends the session's wait for the adapter's report after
    /// `externalScreenTimeout`; nil when the session does not wait.
    @ObservationIgnored private var externalScreenWait: Task<Void, Never>?
    /// The latest choice made while the session waits, which it applies when the wait ends.
    @ObservationIgnored private var choiceDuringWait: (mode: ExternalDisplayMode, failure: @MainActor (Error) -> Void)?
    @ObservationIgnored private let externalScreenTimeout: Duration
    /// Runs on the main actor after `externalScreen` changes.
    @ObservationIgnored var onExternalScreenChange: (() -> Void)?

    /// Menu selection derived from the actual display, which other tools may also change.
    var externalDisplayMode: ExternalDisplayMode? { externalScreen?.mode }

    /// Why `mode` cannot be displayed; nil if supported or advertised modes are not yet known.
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

    /// Whether the guest renders at the screen's reported size. Unknown and CarPlay states pass.
    /// See `ExternalScreenMode.guestSize(for:refreshRate:among:)` for guest mode substitution.
    func externalDisplayShowsItsSize(in state: ExternalScreenState) -> Bool {
        guard state.isPoweredOn, !state.isCarPlay, let modes = externalScreenModes else { return true }
        return ExternalScreenMode.guestSize(for: state.pixelSize, refreshRate: state.refreshRate, among: modes)
            == state.pixelSize
    }

    /// Waits for the adapter's asynchronous enumeration, then applies the latest pending or saved choice.
    /// A saved Disabled choice leaves an externally enabled display alone on connection.
    /// Late reports still connect; failures go to `failure`.
    func connectExternalDisplay(failure: @escaping @MainActor (Error) -> Void) {
        guard capabilities.supportsExternalDisplays, !isDisconnected, externalScreenConnection == nil,
              externalScreenRegistration == nil else { return }
        waitForExternalScreen(failure: failure)
    }

    /// Waits for the external screen or timeout, retaining only the latest choice.
    /// Reports failure to that choice's handler, or to `failure` if no choice is pending.
    private func waitForExternalScreen(failure: @escaping @MainActor (Error) -> Void) {
        do {
            externalScreenRegistration = try display.registerForExternalScreen(
                changed: { [weak self] in self?.externalScreenChanged() },
                found: { [weak self] in self?.externalScreenReported($0, failure: failure) })
        } catch {
            let choice = choiceDuringWait
            choiceDuringWait = nil
            return (choice?.failure ?? failure)(Self.connectionFailure(error, deviceName: device.name))
        }
        // A device without a screen adapter has no external display.
        guard externalScreenRegistration != nil else { return applyExternalDisplayAfterWait(failure: failure) }
        let timeout = externalScreenTimeout
        externalScreenWait = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            externalScreenWait = nil
            applyExternalDisplayAfterWait(failure: failure)
        }
    }

    /// Consumes the first adapter report and releases the registration; ignores queued later reports.
    private func externalScreenReported(_ result: Result<any SimulatorExternalScreen, any Error>,
                                        failure: @escaping @MainActor (Error) -> Void) {
        guard externalScreenRegistration != nil else { return }
        externalScreenRegistration = nil
        externalScreenWait?.cancel()
        externalScreenWait = nil
        switch result {
        case .success(let screen):
            externalScreenConnection = screen
            do { externalScreenModes = try screen.supportedModes() } catch {
                hostLog("Could not read the external display modes of \(device.name): \(error.localizedDescription)")
            }
            externalScreenChanged()
            applyExternalDisplayAfterWait(failure: failure)
        case .failure(let error):
            let choice = choiceDuringWait
            choiceDuringWait = nil
            (choice?.failure ?? failure)(Self.connectionFailure(error, deviceName: device.name))
        }
    }

    private static func connectionFailure(_ error: any Error, deviceName name: String) -> HostError {
        HostError.operation("Could not connect to the external display of \(name): \(error.localizedDescription)")
    }

    /// Applies the last choice made while the session waited for the
    /// external display, or else the device's saved choice.
    private func applyExternalDisplayAfterWait(failure: @escaping @MainActor (Error) -> Void) {
        if let choice = choiceDuringWait {
            choiceDuringWait = nil
            applyExternalDisplay(choice.mode, failure: choice.failure)
        } else if let mode = ExternalDisplayMode(rawValue: preferences.externalDisplayTag(forDevice: device.identity.preferenceIdentifier)),
                  mode != .disabled, mode != .carPlay || capabilities.supportsCarPlay {
            applyExternalDisplay(mode, failure: failure)
        }
    }

    /// Saves the choice before applying it, preserving it across restarts and failures.
    /// Retries external-screen discovery when needed. Reports all failures for a choice together.
    func chooseExternalDisplay(_ mode: ExternalDisplayMode, failure: @escaping @MainActor (Error) -> Void) {
        guard capabilities.supportsExternalDisplays, mode != .carPlay || capabilities.supportsCarPlay else { return }
        preferences.setExternalDisplayTag(mode.rawValue, forDevice: device.identity.preferenceIdentifier)
        guard canPerformCommands else { return }
        if externalScreenConnection == nil, externalScreenRegistration == nil {
            choiceDuringWait = (mode, failure)
            return waitForExternalScreen(failure: failure)
        }
        guard externalScreenWait == nil else {
            choiceDuringWait = (mode, failure)
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
            guard let externalScreenConnection else { throw HostError.unavailable("The device has no external display port.") }
            if let limit = externalDisplayLimit(for: mode) { throw limit }
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

    /// Queues power-off and ends this host's CarPlay session before disconnecting.
    /// Keeps the saved choice and CarPlay configuration for the next connection.
    private func disconnectExternalScreen() {
        // Releasing the registration ends the adapter's reports.
        externalScreenRegistration = nil
        externalScreenWait?.cancel()
        externalScreenWait = nil
        choiceDuringWait = nil
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

    /// Reads physical orientation; automatic rotation subsequently follows guest interface orientation.
    func readOrientation() async throws {
        let reading = try await tools.orientation()
        try Task.checkCancellation()
        orientation = reading.physical
        guestAngle = display.guestInterfaceAngle
        let followsGuest = HostPreferences.defaults.bool(forKey: HostPreferences.rotateWindowWhenSignaledByGuest)
        rotateDisplay(followsGuest ? guestAngle ?? reading.displayAngle : reading.displayAngle)
    }

    /// Applies a changed guest interface orientation in a deterministic order.
    /// Resuming automatic rotation reapplies it even after a manual display rotation.
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
            try await tools.screenshot(to: temporary, mask: mask, displayID: display.captureDisplayID)
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
            try await tools.screenshot(to: temporary, mask: mask, displayID: display.captureDisplayID)
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

    /// Announces recording state changes to the device plugin.
    func startRecording(to destination: RecordingStore.Destination, mask: DeviceTools.ScreenMask) throws {
        guard canPerformCommands, recording == nil else { return }
        guard !isStartingAppResize else {
            throw HostError.operation("Wait for the app display to connect before starting a recording.")
        }
        let displayID = try display.captureDisplayID
        recording = try recordings.start(to: destination, process: { [makeRecordingProcess] in
            makeRecordingProcess($0, mask, displayID)
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
        // Release held inputs, the remote's touch included, while the input
        // client can still send.
        for event in downInputs.keys {
            if let up = try? releaseMessage(for: event) { try? display.send(up, completion: nil) }
        }
        pendingHolds.removeAll()
        downInputs.removeAll()
        releasesInFlight.removeAll()
        remoteReports.removeAll()
        isTouchingRemote = false
        inputSteps.values.forEach { $0.cancel() }
        inputSteps.removeAll()
        stopAppResize()
        resizePreparation?.cancel(); resizePreparation = nil
        resizeObservation?.cancel(); resizeObservation = nil
        resizeTransport = nil
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
