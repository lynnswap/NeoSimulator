import AppKit

/// A command that acts on the active device window.
///
/// Each command is defined once here: menus, the window toolbar, and their
/// validation are built from the catalog. Titles, shortcuts, and positions
/// follow Simulator.app's MainMenu.nib where Simulator.app has the command.
@MainActor
struct DeviceCommand {
    enum ID: String, CaseIterable {
        case saveScreen, saveScreenAs, recordScreen, recordScreenAs, stopRecording, importFiles, copyScreen
        case getPasteboard, sendPasteboard
        case restart, eraseAllContentAndSettings, shutDown, rotateLeft, rotateRight
        case portrait, landscapeRight, portraitUpsideDown, landscapeLeft, faceUp, faceDown
        case rotateDeviceAutomatically
        case home, lock, alwaysOn, sideButton, actionButtonSting
        case actionButtonStaccato, doubleTap, wristFlick, siri, shake, appSwitcher, triggerScreenshot
        case syncKeyboardLanguage, connectHardwareKeyboard, toggleSoftwareKeyboard
        case useTrackpadForce, shallowPress, deepPress
        case increaseVolume, decreaseVolume, openURL
        case externalDisplayDisabled, externalDisplay640x480, externalDisplay720x480, externalDisplay1024x768
        case externalDisplay1280x720, externalDisplay1920x1080, externalDisplay3840x2160
        case touchIDEnrolled, touchIDMatching, touchIDNonMatching
        case faceIDEnrolled, faceIDMatching, faceIDNonMatching
        case fallConfirmed, fallDismissed, fallRejected, fallUnresponsive
        case authorizeApplePay, toggleAppearance, toggleInCallStatusBar, toggleStandBy
        case increaseTextSize, decreaseTextSize, toggleIncreaseContrast, triggerCloudSync
        case toggleSlowAnimations, graphicsQualityDefault, graphicsQualityLow, graphicsQualityHigh
        case colorBlendedLayers, colorCopiedImages, colorMisalignedImages, colorOffscreenRendered
        case openSystemLog, simulateMemoryWarning
        case stayOnTop, physicalSize, pointAccurate, pixelAccurate, fitScreen
    }

    struct Toolbar {
        /// What a button shows and the command it performs.
        struct Face {
            let id: ID
            let symbol: String
            /// The description of the button's image, which accessibility
            /// reads, or nil for the symbol's own.
            let imageDescription: String?
            /// The button's tooltip, or nil for the item's label.
            var toolTip: String?
        }

        /// The item's label, which is also the button's tooltip while it
        /// performs the command, as in Simulator.app's toolbar nibs, unless
        /// `toolTip` gives another.
        let label: String
        let toolTip: String?
        let symbol: String
        /// The description of the button's image while it performs the
        /// command, by default the label.
        let imageDescription: String
        /// The width of the command's button in Simulator.app's toolbar nib,
        /// which its toolbar style threshold counts (see
        /// `DeviceToolbar.buttonsWidth`).
        let buttonWidth: CGFloat
        /// What the button shows and performs while Option is down with the
        /// pointer over the toolbar, as Simulator.app's `OptionSwitchingButton`
        /// does.
        let optionAlternate: Face?
        /// What the button shows and performs while that command can run,
        /// whether or not Option is down.
        let alternate: Face?

        init(label: String, toolTip: String? = nil, symbol: String, imageDescription: String? = nil,
             buttonWidth: CGFloat, optionAlternate: Face? = nil, alternate: Face? = nil) {
            self.label = label
            self.toolTip = toolTip
            self.symbol = symbol
            self.imageDescription = imageDescription ?? label
            self.buttonWidth = buttonWidth
            self.optionAlternate = optionAlternate
            self.alternate = alternate
        }
    }

    let id: ID
    let title: String
    var key = ""
    var modifiers: NSEvent.ModifierFlags = .command
    /// Whether the menu shows the command in place of the one before it
    /// while the extra modifier is held.
    var isAlternate = false
    /// Whether the key device, or nil without one, gets the command's
    /// shortcut, for commands that share a shortcut with another.
    var hasKey: ((DeviceCapabilities?) -> Bool)?
    var toolbar: Toolbar?
    /// Whether the device supports the command. Unsupported commands are hidden.
    var isSupported: (DeviceCapabilities) -> Bool = { _ in true }
    /// Whether the command can run now. Defaults to a connected, booted device.
    var isEnabled: (DeviceWindowController) -> Bool = { $0.session.canPerformCommands }
    /// The checkmark for the active window, or nil to leave it as it is.
    var state: ((DeviceWindowController) -> NSControl.StateValue?)?
    /// Whether the checkmark stays as it is without an active device window,
    /// instead of turning off.
    var keepsStateWithoutWindow = false
    /// The title for the current state, when it changes with the state.
    var stateTitle: ((DeviceWindowController) -> String)?
    let perform: (DeviceWindowController) -> Void

    static func command(_ id: ID) -> DeviceCommand { catalog[id]! }

    /// Sets the checkmark and title of the command's menu item for the
    /// active device window, or for none, and returns whether the command can
    /// run.
    func validate(_ item: NSMenuItem, for controller: DeviceWindowController?) -> Bool {
        guard let controller else {
            if !keepsStateWithoutWindow { item.state = .off }
            item.title = title
            return false
        }
        if let state {
            if let value = state(controller) { item.state = value }
        } else {
            item.state = .off
        }
        item.title = stateTitle?(controller) ?? title
        return isEnabled(controller)
    }

    static let catalog: [ID: DeviceCommand] = Dictionary(uniqueKeysWithValues: ([
        // File
        // Like Simulator.app's, the Save Screen button records the screen with
        // Option, and stops a recording while it runs, showing `stop.circle`,
        // instead of the toolbar adding an item.
        DeviceCommand(id: .saveScreen, title: "Save Screen", key: "s",
                      toolbar: Toolbar(label: "Save Screen", symbol: "camera.on.rectangle", buttonWidth: 32,
                                       optionAlternate: .init(id: .recordScreen, symbol: "record.circle",
                                                              imageDescription: "Start Recording", toolTip: "Record Screen"),
                                       alternate: .init(id: .stopRecording, symbol: "stop.circle",
                                                        imageDescription: "Stop Recording", toolTip: "Stop Recording")),
                      isEnabled: { $0.session.canPerformToolOperation }) { $0.saveScreen() },
        DeviceCommand(id: .saveScreenAs, title: "Save Screen…", key: "s", modifiers: [.command, .option],
                      isAlternate: true,
                      isEnabled: { $0.session.canPerformToolOperation }) { $0.chooseScreenshotDestination() },
        DeviceCommand(id: .recordScreen, title: "Record Screen", key: "r",
                      isEnabled: { $0.session.canPerformToolOperation && $0.session.recording == nil }) { $0.recordScreen() },
        DeviceCommand(id: .recordScreenAs, title: "Record Screen…", key: "r", modifiers: [.command, .option],
                      isAlternate: true,
                      isEnabled: { $0.session.canPerformToolOperation && $0.session.recording == nil }) { $0.chooseRecordingDestination() },
        DeviceCommand(id: .stopRecording, title: "Stop Recording",
                      isEnabled: { $0.session.recording.map { !$0.isStopping } ?? false }) { $0.session.stopRecording() },
        // NeoSimulator's own command. Shift-Command-I is Trigger iCloud Sync in Simulator.app.
        DeviceCommand(id: .importFiles, title: "Install App or Import Media…",
                      isEnabled: { $0.session.canPerformToolOperation }) { $0.chooseFilesToImport() },
        // Edit
        DeviceCommand(id: .copyScreen, title: "Copy Screen", key: "c", modifiers: [.command, .control],
                      isEnabled: { $0.session.canPerformToolOperation }) { $0.copyScreen() },
        // Like Simulator.app, shown for every device and enabled only where
        // the device can exchange its pasteboard, while pasteboards do not
        // synchronize automatically.
        DeviceCommand(id: .getPasteboard, title: "Get Pasteboard",
                      isEnabled: { $0.session.canTransferPasteboard }) { $0.transferPasteboard(.get) },
        DeviceCommand(id: .sendPasteboard, title: "Send Pasteboard",
                      isEnabled: { $0.session.canTransferPasteboard }) { $0.transferPasteboard(.send) },
        // Device
        DeviceCommand(id: .restart, title: "Restart",
                      isEnabled: { $0.session.canPerformToolOperation }) { $0.restart() },
        DeviceCommand(id: .eraseAllContentAndSettings, title: "Erase All Content and Settings…",
                      isEnabled: { $0.session.canPerformToolOperation }) { $0.eraseAllContentAndSettings() },
        DeviceCommand(id: .shutDown, title: "Shut Down",
                      isEnabled: { $0.session.canPerformToolOperation && $0.session.recording == nil }) { $0.shutDown() },
        DeviceCommand(id: .rotateLeft, title: "Rotate Left", key: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
                      isSupported: { $0.rotates },
                      isEnabled: { $0.session.canPerformToolOperation }) { $0.rotate(left: true) },
        // As in Simulator.app, the button is Rotate, which keeps its tooltip
        // with Option and then shows `rotate.left` with the symbol's own
        // description.
        DeviceCommand(id: .rotateRight, title: "Rotate Right", key: String(UnicodeScalar(NSRightArrowFunctionKey)!),
                      toolbar: Toolbar(label: "Rotate", symbol: "rotate.right", imageDescription: "Rotate Right",
                                       buttonWidth: 25,
                                       optionAlternate: .init(id: .rotateLeft, symbol: "rotate.left", imageDescription: nil)),
                      isSupported: { $0.rotates },
                      isEnabled: { $0.session.canPerformToolOperation }) { $0.rotate(left: false) },
        orientation(.portrait, title: "Portrait"),
        orientation(.landscapeRight, title: "Landscape Right"),
        orientation(.portraitUpsideDown, title: "Portrait Upside Down"),
        orientation(.landscapeLeft, title: "Landscape Left"),
        orientation(.faceUp, title: "Face Up"),
        orientation(.faceDown, title: "Face Down"),
        // An app preference, so it does not need a booted device.
        DeviceCommand(id: .rotateDeviceAutomatically, title: "Rotate Device Automatically",
                      isSupported: { $0.supportsFeature(DeviceCapabilities.displayRotation) },
                      isEnabled: { _ in true },
                      state: { _ in
                          UserDefaults.standard.bool(forKey: HostPreferences.rotateWindowWhenSignaledByGuest) ? .on : .off
                      }) { _ in
            let key = HostPreferences.rotateWindowWhenSignaledByGuest
            UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
        },
        DeviceCommand(id: .home, title: "Home", key: "h", modifiers: [.command, .shift],
                      toolbar: Toolbar(label: "Home", symbol: "house", buttonWidth: 31)) { $0.send(.press(.button(.home))) },
        // Simulator.app shows Lock for iPhones, iPads, and watches.
        DeviceCommand(id: .lock, title: "Lock", key: "l",
                      isSupported: { $0.isPhoneOrPad || $0.family == .watch }) { $0.send(.press(.button(.lock))) },
        // Only a toolbar button, of Simulator.app's IndigoWatchAODToolbar.nib:
        // it presses Lock, and its state is the watch's backlight.
        DeviceCommand(id: .alwaysOn, title: "Always On",
                      toolbar: Toolbar(label: "Always On", toolTip: "Toggle Always On", symbol: "applewatch.watchface",
                                       buttonWidth: 25),
                      isSupported: { $0.family == .watch && $0.supportsFeature(DeviceCapabilities.alwaysOnDisplay) },
                      state: { $0.session.showsAlwaysOn ? .on : .off }) { $0.send(.press(.button(.lock))) },
        DeviceCommand(id: .sideButton, title: "Side Button", key: "b", modifiers: [.command, .shift],
                      isSupported: { $0.family == .watch }) { $0.send(.press(.button(.side))) },
        DeviceCommand(id: .actionButtonSting, title: "Action Button",
                      isSupported: { $0.supportsFeature(DeviceCapabilities.actionButtonSting) }) {
            $0.send(.press(.button(.actionSting)))
        },
        DeviceCommand(id: .actionButtonStaccato, title: "Action Button",
                      isSupported: { $0.supportsFeature(DeviceCapabilities.actionButtonStaccato) }) {
            $0.send(.hold(.button(.actionStaccato), for: .milliseconds(500)))
        },
        watchGesture(.doubleTap, title: "Double Tap", .doubleTap),
        // Simulator.app hides Wrist Flick before watchOS 12.
        watchGesture(.wristFlick, title: "Wrist Flick", .wristFlick, minimumRuntime: 0x0C_00_00),
        DeviceCommand(id: .siri, title: "Siri", key: "h", modifiers: [.command, .option, .shift],
                      isSupported: { $0.supportsFeature(DeviceCapabilities.siri) }) { $0.send(.press(.button(.siri))) },
        DeviceCommand(id: .shake, title: "Shake", key: "z", modifiers: [.command, .control],
                      isSupported: { $0.isPhoneOrPad }) { controller in controller.run { try controller.session.shake() } },
        DeviceCommand(id: .appSwitcher, title: "App Switcher", key: "h", modifiers: [.command, .control, .shift],
                      isSupported: { $0.isPhoneOrPad }) {
            $0.send(.pressTwice(.button(.home), interval: .milliseconds(150)))
        },
        // The guest's screenshot action, unlike Save Screen. It needs iOS 13.
        DeviceCommand(id: .triggerScreenshot, title: "Trigger Screenshot",
                      isSupported: { $0.isPhoneOrPad },
                      isEnabled: { $0.session.canPerformCommands && $0.session.capabilities.runtimeVersion >= 0x0D_00_00 }) {
            $0.send(.press(.screenshot))
        },
        // I/O. Simulator.app shows Keyboard only for a device that takes a
        // hardware keyboard, and Touch Pressure only for one that takes
        // touch pressure. Use the Same Keyboard Language as macOS is an app
        // preference, so it does not need a booted device.
        DeviceCommand(id: .syncKeyboardLanguage, title: "Use the Same Keyboard Language as macOS",
                      isSupported: { $0.supportsFeature(DeviceCapabilities.keyboard) },
                      isEnabled: { _ in true },
                      state: { $0.session.syncsKeyboardLanguage ? .on : .off }) { $0.session.toggleKeyboardLanguageSync() },
        DeviceCommand(id: .connectHardwareKeyboard, title: "Connect Hardware Keyboard", key: "k",
                      modifiers: [.command, .shift],
                      isSupported: { $0.supportsFeature(DeviceCapabilities.keyboard) },
                      state: { $0.session.connectsHardwareKeyboard ? .on : .off }) { $0.toggleHardwareKeyboard() },
        // The software keyboard toggles only beside a hardware keyboard.
        DeviceCommand(id: .toggleSoftwareKeyboard, title: "Toggle Software Keyboard", key: "k",
                      isSupported: { $0.supportsFeature(DeviceCapabilities.keyboard) },
                      isEnabled: { $0.session.canPerformCommands && $0.session.connectsHardwareKeyboard }) {
            $0.send(.press(.button(.softwareKeyboard)))
        },
        // App-wide settings, as Simulator.app keeps them, so they do not need
        // a booted device. Use Trackpad Force needs a Force Touch trackpad.
        DeviceCommand(id: .useTrackpadForce, title: "Use Trackpad Force",
                      isSupported: { $0.supportsFeature(DeviceCapabilities.touchPressure) },
                      isEnabled: { $0.touchPressure.hasForceTouchTrackpad },
                      state: { $0.touchPressure.usesTrackpadForce ? .on : .off }) { $0.touchPressure.toggleTrackpadForce() },
        touchMode(.shallowPress, title: "Shallow Press", key: "1", .shallow),
        touchMode(.deepPress, title: "Deep Press", key: "2", .deep),
        DeviceCommand(id: .increaseVolume, title: "Increase Volume", key: String(UnicodeScalar(NSUpArrowFunctionKey)!),
                      isSupported: { $0.supportsFeature(DeviceCapabilities.routableAudio) }) { $0.send(.press(.volumeUp)) },
        DeviceCommand(id: .decreaseVolume, title: "Decrease Volume", key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                      isSupported: { $0.supportsFeature(DeviceCapabilities.routableAudio) }) { $0.send(.press(.volumeDown)) },
        DeviceCommand(id: .openURL, title: "Open URL…", key: "u", modifiers: [.command, .shift],
                      isEnabled: { $0.session.canPerformToolOperation }) { $0.chooseURLToOpen() },
        // Features
        biometricEnrollment(.touchIDEnrolled, feature: DeviceCapabilities.touchID),
        biometric(.touchIDMatching, title: "Matching Touch", .touchID, matching: true),
        biometric(.touchIDNonMatching, title: "Non-matching Touch", .touchID, matching: false),
        biometricEnrollment(.faceIDEnrolled, feature: DeviceCapabilities.faceID),
        biometric(.faceIDMatching, title: "Matching Face", .faceID, matching: true),
        biometric(.faceIDNonMatching, title: "Non-matching Face", .faceID, matching: false),
        fall(.fallConfirmed, title: "Confirmed", .confirmed),
        fall(.fallDismissed, title: "Dismissed", .dismissed),
        fall(.fallRejected, title: "Rejected", .rejected),
        fall(.fallUnresponsive, title: "Unresponsive", .unresponsive),
        DeviceCommand(id: .authorizeApplePay, title: "Authorize Apple Pay", key: "a", modifiers: [.command, .option],
                      isSupported: { $0.supportsFeature(DeviceCapabilities.applePayAuthorization) }) {
            $0.send(.press(.button(.applePay)))
        },
        DeviceCommand(id: .toggleAppearance, title: "Toggle Appearance", key: "a", modifiers: [.command, .shift],
                      isSupported: { $0.isPhoneOrPad }) { controller in controller.run { try controller.session.toggleAppearance() } },
        DeviceCommand(id: .toggleInCallStatusBar, title: "Toggle In-call Status Bar", key: "y",
                      isSupported: { $0.isPhoneOrPad }) { controller in
            controller.run { try controller.session.toggleInCallStatusBar() }
        },
        DeviceCommand(id: .toggleStandBy, title: "Show StandBy",
                      isSupported: { $0.supportsFeature(DeviceCapabilities.standBy) },
                      stateTitle: { $0.session.showsStandBy ? "Hide StandBy" : "Show StandBy" }) { controller in
            controller.run { try controller.session.toggleStandBy() }
        },
        DeviceCommand(id: .increaseTextSize, title: "Increase Preferred Text Size", key: "+", modifiers: [.command, .option],
                      isSupported: { $0.isPhoneOrPad }) { controller in controller.run { try controller.session.changeTextSize(by: 1) } },
        DeviceCommand(id: .decreaseTextSize, title: "Decrease Preferred Text Size", key: "-", modifiers: [.command, .option],
                      isSupported: { $0.isPhoneOrPad }) { controller in controller.run { try controller.session.changeTextSize(by: -1) } },
        DeviceCommand(id: .toggleIncreaseContrast, title: "Toggle Increase Contrast",
                      isSupported: { $0.isPhoneOrPad }) { controller in controller.run { try controller.session.toggleIncreaseContrast() } },
        DeviceCommand(id: .triggerCloudSync, title: "Trigger iCloud Sync", key: "i", modifiers: [.command, .shift],
                      isEnabled: { $0.session.canPerformToolOperation }) { controller in
            controller.session.run({ [session = controller.session] in try await session.triggerCloudSync() },
                                   failure: { [weak controller] in controller?.present($0) })
        },
        // Debug
        // Simulator.app shows the setting only for a guest that keeps it.
        DeviceCommand(id: .toggleSlowAnimations, title: "Toggle Slow Animations in Frontmost App",
                      state: { $0.session.keepsSlowAnimations && $0.session.slowAnimations ? .on : .off },
                      stateTitle: { $0.session.keepsSlowAnimations ? "Slow Animations" : "Toggle Slow Animations in Frontmost App" }) { controller in
            controller.run { try controller.session.toggleSlowAnimations() }
        },
        graphicsQuality(.graphicsQualityDefault, title: "Device Default", .deviceDefault),
        graphicsQuality(.graphicsQualityLow, title: "Low Quality", .low),
        graphicsQuality(.graphicsQualityHigh, title: "High Quality", .high),
        caDebugOption(.colorBlendedLayers, .colorBlendedLayers),
        caDebugOption(.colorCopiedImages, .colorCopiedImages),
        caDebugOption(.colorMisalignedImages, .colorMisalignedImages),
        caDebugOption(.colorOffscreenRendered, .colorOffscreenRendered),
        DeviceCommand(id: .openSystemLog, title: "Open System Log…", key: "/") { $0.openSystemLog() },
        DeviceCommand(id: .simulateMemoryWarning, title: "Simulate Memory Warning", key: "m",
                      modifiers: [.command, .shift]) { controller in
            controller.run { try controller.session.simulateMemoryWarning() }
        },
        // Window
        DeviceCommand(id: .stayOnTop, title: "Stay On Top",
                      state: { $0.staysOnTop ? .on : .off }) { $0.toggleStayOnTop() },
        scale(.physicalSize, title: "Physical Size", key: "1"),
        scale(.pointAccurate, title: "Point Accurate", key: "2"),
        scale(.pixelAccurate, title: "Pixel Accurate", key: "3"),
        scale(.fitScreen, title: "Fit Screen", key: "4"),
    ] + ExternalDisplayMode.allCases.map { externalDisplay($0) }).map { ($0.id, $0) })

    /// A window scale command. Like Simulator.app, Fit Screen has no checkmark,
    /// and the others keep theirs while they are unavailable, including
    /// without a device window, where Simulator.app does not validate them.
    private static func scale(_ mode: WindowScaleMode, title: String, key: String) -> DeviceCommand {
        DeviceCommand(id: ID(rawValue: mode.rawValue)!, title: title, key: key,
                      isEnabled: { $0.scaledWindow.canSetScale(mode) },
                      state: mode == .fitScreen ? nil : { $0.scaledWindow.scaleState(mode) },
                      keepsStateWithoutWindow: true) { $0.scaledWindow.setScale(mode) }
    }

    /// An I/O ▸ External Displays item, shown, as in Simulator.app, for a
    /// device that supports external displays and has its own screen. Like
    /// Simulator.app, the items stay enabled while the device restarts, and a
    /// choice then applies when it connects. The checkmark is the external
    /// display's actual state, where Simulator.app checks the saved choice.
    private static func externalDisplay(_ mode: ExternalDisplayMode) -> DeviceCommand {
        DeviceCommand(id: mode.commandID, title: mode.title,
                      isSupported: { $0.supportsExternalDisplays },
                      isEnabled: { _ in true },
                      state: { $0.session.externalDisplayMode == mode ? .on : .off }) { $0.chooseExternalDisplay(mode) }
    }

    /// Shallow Press or Deep Press, checked when it is the app's touch mode.
    /// Like Simulator.app, they are available only for a watch, and
    /// choosing one changes every window that takes touch pressure.
    private static func touchMode(_ id: ID, title: String, key: String, _ mode: SimulatedTouchMode) -> DeviceCommand {
        DeviceCommand(id: id, title: title, key: key, modifiers: [.command, .shift],
                      isSupported: { $0.supportsFeature(DeviceCapabilities.touchPressure) },
                      isEnabled: { $0.session.capabilities.family == .watch },
                      state: { $0.session.capabilities.family == .watch && $0.touchPressure.mode == mode ? .on : .off }) {
            $0.touchPressure.setMode(mode)
        }
    }

    /// A Device ▸ Gestures item, for a watch with `SimFeatureWatchGestures`
    /// whose runtime is `minimumRuntime` or later.
    private static func watchGesture(_ id: ID, title: String, _ gesture: WatchGesture,
                                     minimumRuntime: UInt32 = 0) -> DeviceCommand {
        DeviceCommand(id: id, title: title,
                      isSupported: {
                          $0.supportsFeature(DeviceCapabilities.watchGestures) && $0.runtimeVersion >= minimumRuntime
                      }) { $0.send(.watchGesture(gesture)) }
    }

    /// A Features ▸ Simulate Fall item, for a device with `SimFeatureFallDetection`.
    private static func fall(_ id: ID, title: String, _ resolution: FallResolution) -> DeviceCommand {
        DeviceCommand(id: id, title: title,
                      isSupported: { $0.supportsFeature(DeviceCapabilities.fallDetection) }) { controller in
            controller.run { try controller.session.simulateFall(resolution) }
        }
    }

    /// Touch ID ▸ Enrolled or Face ID ▸ Enrolled. The two share one guest state.
    private static func biometricEnrollment(_ id: ID, feature: String) -> DeviceCommand {
        DeviceCommand(id: id, title: "Enrolled", isSupported: { $0.supportsFeature(feature) },
                      state: { $0.session.isBiometricEnrolled ? .on : .off }) { controller in
            controller.run { try controller.session.toggleBiometricEnrollment() }
        }
    }

    /// A matching or non-matching biometric event. Option-Command-M and N go
    /// to Face ID on a device with Face ID, and otherwise to Touch ID, as
    /// Simulator.app assigns them when a device window becomes key.
    private static func biometric(_ id: ID, title: String, _ biometric: DeviceSession.Biometric,
                                  matching: Bool) -> DeviceCommand {
        let feature = biometric == .touchID ? DeviceCapabilities.touchID : DeviceCapabilities.faceID
        return DeviceCommand(id: id, title: title, key: matching ? "m" : "n", modifiers: [.command, .option],
                             hasKey: { capabilities in
                                 let faceID = capabilities?.supportsFeature(DeviceCapabilities.faceID) ?? false
                                 return biometric == .faceID ? faceID : !faceID
                             },
                             isSupported: { $0.supportsFeature(feature) }) { controller in
            controller.run { try controller.session.sendBiometric(biometric, matching: matching) }
        }
    }

    /// Sets a physical orientation. The checkmark shows the orientation last
    /// read from the device; Face Up and Face Down keep the display angle.
    private static func orientation(_ orientation: DeviceOrientation, title: String) -> DeviceCommand {
        DeviceCommand(id: ID(rawValue: orientation.rawValue)!, title: title,
                      isSupported: { $0.rotates },
                      isEnabled: { $0.session.canPerformToolOperation },
                      state: { $0.session.orientation == orientation ? .on : .off }) {
            $0.setOrientation(orientation)
        }
    }

    /// A Graphics Quality Override choice, checked when it is the app's setting.
    /// Like Simulator.app, the change is immediate, except that an Apple TV
    /// then restarts its system UI, a device-tool operation, so the choice
    /// waits there for the running one.
    private static func graphicsQuality(_ id: ID, title: String, _ quality: GraphicsQuality) -> DeviceCommand {
        DeviceCommand(id: id, title: title,
                      isSupported: { $0.supportsFeature(DeviceCapabilities.graphicsQualityOverride) },
                      isEnabled: { $0.session.capabilities.family == .tv ? $0.session.canPerformToolOperation
                                                                         : $0.session.canPerformCommands },
                      state: { $0.session.graphicsQuality == quality ? .on : .off }) { controller in
            let session = controller.session
            guard session.capabilities.family == .tv else {
                return controller.run { try session.setGraphicsQuality(quality) }
            }
            session.run({
                try session.setGraphicsQuality(quality)
                try await session.restartSystemUI()
            }, failure: { [weak controller] in controller?.present($0) })
        }
    }

    /// A Core Animation debug option, checked as the device reports it.
    private static func caDebugOption(_ id: ID, _ option: CADebugOption) -> DeviceCommand {
        DeviceCommand(id: id, title: option.title, state: { $0.session.isOn(option) ? .on : .off }) { controller in
            controller.run { try controller.session.toggle(option) }
        }
    }

    /// Toolbar items in the order of Simulator.app's toolbar nibs: Home, Save
    /// Screen, then Rotate for iPhones and iPads or Always On for watches with
    /// an always-on display. Unsupported items are omitted, so a watch
    /// without one and an Apple TV show Home and Save Screen.
    static let toolbarItems: [ID] = [.home, .saveScreen, .rotateRight, .alwaysOn]
}

/// Splits a device name the way Simulator.app titles its windows: the name up
/// to the first closing parenthesis stays in the title, and later parenthesized
/// groups join the runtime name in the subtitle. A title that starts with
/// "Apple Watch " loses that prefix, as a watch's does in Simulator.app.
func deviceWindowTitles(name: String, runtimeName: String) -> (title: String, subtitle: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    func shown(_ title: Substring) -> String {
        let prefix = "Apple Watch "
        return String(title.hasPrefix(prefix) ? title.dropFirst(prefix.count) : title)
    }
    guard let open = trimmed.firstIndex(of: "("), let close = trimmed.firstIndex(of: ")"),
          open < close, close < trimmed.index(before: trimmed.endIndex) else {
        return (shown(trimmed[...]), runtimeName)
    }
    let suffix = trimmed[trimmed.index(after: close)...]
        .replacingOccurrences(of: ") (", with: " - ")
        .filter { $0 != "(" && $0 != ")" }
        .trimmingCharacters(in: .whitespaces)
    return (shown(trimmed[...close]), suffix.isEmpty ? runtimeName : "\(suffix) – \(runtimeName)")
}

extension ExternalDisplayMode {
    /// The command of the mode's I/O ▸ External Displays item.
    var commandID: DeviceCommand.ID {
        switch self {
        case .disabled: .externalDisplayDisabled
        case .size640x480: .externalDisplay640x480
        case .size720x480: .externalDisplay720x480
        case .size1024x768: .externalDisplay1024x768
        case .size1280x720: .externalDisplay1280x720
        case .size1920x1080: .externalDisplay1920x1080
        case .size3840x2160: .externalDisplay3840x2160
        }
    }
}
