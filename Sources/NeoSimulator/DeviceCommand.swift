import AppKit

/// Catalog shared by device menus, toolbars, and validation.
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
        case syncKeyboardLanguage, connectHardwareKeyboard, captureKeyboard, toggleSoftwareKeyboard
        case useTrackpadForce, shallowPress, deepPress
        case increaseVolume, decreaseVolume, openURL
        case externalDisplayDisabled, externalDisplay640x480, externalDisplay720x480, externalDisplay1024x768
        case externalDisplay1280x720, externalDisplay1920x1080, externalDisplay3840x2160, externalDisplayCarPlay
        case touchIDEnrolled, touchIDMatching, touchIDNonMatching
        case faceIDEnrolled, faceIDMatching, faceIDNonMatching
        case opticIDEnrolled, opticIDMatching, opticIDNonMatching
        case fallConfirmed, fallDismissed, fallRejected, fallUnresponsive
        case authorizeApplePay, toggleAppearance, toggleInCallStatusBar, toggleStandBy
        case increaseTextSize, decreaseTextSize, toggleIncreaseContrast, triggerCloudSync
        case toggleSlowAnimations, graphicsQualityDefault, graphicsQualityLow, graphicsQualityHigh
        case colorBlendedLayers, colorCopiedImages, colorMisalignedImages, colorOffscreenRendered
        case openSystemLog, simulateMemoryWarning
        case resizeApp, appleTVRemote, stayOnTop, physicalSize, pointAccurate, pixelAccurate, fitScreen
    }

    /// Device Hub's canvas rotates left by default; Option reverses it.
    static func canvasRotation(modifierFlags: NSEvent.ModifierFlags) -> ID {
        modifierFlags.contains(.option) ? .rotateRight : .rotateLeft
    }

    struct Toolbar {
        /// A toolbar button's appearance and action.
        struct Face {
            let id: ID
            let symbol: String
            /// Accessibility image description; nil uses the symbol's own description.
            let imageDescription: String?
            /// Tooltip override; nil uses the label.
            var toolTip: String?
        }

        /// Item label and default tooltip.
        let label: String
        let toolTip: String?
        let symbol: String
        /// Accessibility image description, defaulting to the label.
        let imageDescription: String
        /// Simulator.app toolbar width, used by `DeviceToolbar.buttonsWidth`.
        let buttonWidth: CGFloat
        /// Alternate shown while Option is held over the toolbar.
        let optionAlternate: Face?
        /// Alternate shown whenever its command can run, regardless of Option.
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
    /// Replaces the preceding menu item while the extra modifier is held.
    var isAlternate = false
    /// Assigns shortcuts shared by commands according to the key device.
    var hasKey: ((DeviceCapabilities?) -> Bool)?
    var toolbar: Toolbar?
    /// Unsupported commands are hidden.
    var isSupported: (DeviceCapabilities) -> Bool = { _ in true }
    /// Defaults to a connected, booted device.
    var isEnabled: (DeviceWindowController) -> Bool = { $0.session.canPerformCommands }
    /// Nil preserves the current checkmark.
    var state: ((DeviceWindowController) -> NSControl.StateValue?)?
    /// Preserves the checkmark when no device window is active.
    var keepsStateWithoutWindow = false
    /// Dynamic title.
    var stateTitle: ((DeviceWindowController) -> String)?
    /// Dynamic subtitle; nil clears it.
    var stateSubtitle: ((DeviceWindowController) -> String?)?
    let perform: (DeviceWindowController) -> Void

    static func command(_ id: ID) -> DeviceCommand { catalog[id]! }

    /// Updates menu state and returns availability for the active device window.
    func validate(_ item: NSMenuItem, for controller: DeviceWindowController?) -> Bool {
        guard let controller else {
            if !keepsStateWithoutWindow { item.state = .off }
            item.title = title
            if stateSubtitle != nil { item.subtitle = nil }
            return false
        }
        if let state {
            if let value = state(controller) { item.state = value }
        } else {
            item.state = .off
        }
        item.title = stateTitle?(controller) ?? title
        if let stateSubtitle { item.subtitle = stateSubtitle(controller) }
        return isEnabled(controller)
    }

    static let catalog: [ID: DeviceCommand] = Dictionary(uniqueKeysWithValues: ([
        DeviceCommand(id: .resizeApp, title: "Resize App",
                      toolbar: Toolbar(label: "Resize App", symbol: "aspectratio", buttonWidth: 32),
                      isEnabled: { $0.session.canResizeApp },
                      state: { $0.session.isResizingApp || $0.session.isStartingAppResize ? .on : .off }) { $0.toggleAppResize() },
        // File: Save Screen becomes Record Screen with Option, or Stop Recording while recording.
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
                      isEnabled: { $0.session.canStartRecording }) { $0.recordScreen() },
        DeviceCommand(id: .recordScreenAs, title: "Record Screen…", key: "r", modifiers: [.command, .option],
                      isAlternate: true,
                      isEnabled: { $0.session.canStartRecording }) { $0.chooseRecordingDestination() },
        DeviceCommand(id: .stopRecording, title: "Stop Recording",
                      isEnabled: { $0.session.recording.map { !$0.isStopping } ?? false }) { $0.session.stopRecording() },
        // NeoSimulator shortcut; Simulator.app assigns it to Trigger iCloud Sync.
        DeviceCommand(id: .importFiles, title: "Install App or Import Media…",
                      isEnabled: { $0.session.canPerformToolOperation }) { $0.chooseFilesToImport() },
        // Edit
        DeviceCommand(id: .copyScreen, title: "Copy Screen", key: "c", modifiers: [.command, .control],
                      isEnabled: { $0.session.canPerformToolOperation }) { $0.copyScreen() },
        // Manual pasteboard transfers are unavailable during automatic synchronization.
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
        // Option changes rotation direction while preserving the Rotate tooltip.
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
                          HostPreferences.defaults.bool(forKey: HostPreferences.rotateWindowWhenSignaledByGuest) ? .on : .off
                      }) { _ in
            let key = HostPreferences.rotateWindowWhenSignaledByGuest
            HostPreferences.defaults.set(!HostPreferences.defaults.bool(forKey: key), forKey: key)
        },
        DeviceCommand(id: .home, title: "Home", key: "h", modifiers: [.command, .shift],
                      toolbar: Toolbar(label: "Home", symbol: "house", buttonWidth: 31)) { $0.send(.press(.button(.home))) },
        DeviceCommand(id: .lock, title: "Lock", key: "l",
                      isSupported: { $0.isPhoneOrPad || $0.family == .watch }) { $0.send(.press(.button(.lock))) },
        // Watch-only Lock button whose state follows the backlight.
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
        watchGesture(.wristFlick, title: "Wrist Flick", .wristFlick, minimumRuntime: 0x0C_00_00),
        DeviceCommand(id: .siri, title: "Siri", key: "h", modifiers: [.command, .option, .shift],
                      isSupported: { $0.supportsFeature(DeviceCapabilities.siri) }) { $0.send(.press(.button(.siri))) },
        DeviceCommand(id: .shake, title: "Shake", key: "z", modifiers: [.command, .control],
                      isSupported: { $0.isPhoneOrPad }) { controller in controller.run { try controller.session.shake() } },
        DeviceCommand(id: .appSwitcher, title: "App Switcher", key: "h", modifiers: [.command, .control, .shift],
                      isSupported: { $0.isPhoneOrPad }) {
            $0.send(.pressTwice(.button(.home), interval: .milliseconds(150)))
        },
        // Guest screenshot action, requiring iOS 13.
        DeviceCommand(id: .triggerScreenshot, title: "Trigger Screenshot",
                      isSupported: { $0.isPhoneOrPad },
                      isEnabled: { $0.session.canPerformCommands && $0.session.capabilities.runtimeVersion >= 0x0D_00_00 }) {
            $0.send(.press(.screenshot))
        },
        // I/O: app preferences remain available without a booted device.
        DeviceCommand(id: .syncKeyboardLanguage, title: "Use the Same Keyboard Language as macOS",
                      isSupported: { $0.supportsFeature(DeviceCapabilities.keyboard) },
                      isEnabled: { _ in true },
                      state: { $0.session.syncsKeyboardLanguage ? .on : .off }) { $0.session.toggleKeyboardLanguageSync() },
        DeviceCommand(id: .connectHardwareKeyboard, title: "Connect Hardware Keyboard", key: "k",
                      modifiers: [.command, .shift],
                      isSupported: { $0.supportsFeature(DeviceCapabilities.keyboard) },
                      state: { $0.session.connectsHardwareKeyboard ? .on : .off }) { $0.toggleHardwareKeyboard() },
        DeviceCommand(id: .captureKeyboard, title: "Capture Keyboard",
                      toolbar: Toolbar(label: "Capture Keyboard", toolTip: "Capture Keyboard — hold Escape for one second to release.",
                                       symbol: "keyboard", buttonWidth: 32),
                      isSupported: { $0.supportsFeature(DeviceCapabilities.keyboard) },
                      isEnabled: { $0.session.canPerformCommands && $0.session.connectsHardwareKeyboard },
                      state: { $0.capturesKeyboard ? .on : .off },
                      stateTitle: { $0.capturesKeyboard ? "Release Keyboard" : "Capture Keyboard" }) { $0.toggleKeyboardCapture() },
        // Software keyboard toggling requires the hardware keyboard.
        DeviceCommand(id: .toggleSoftwareKeyboard, title: "Toggle Software Keyboard", key: "k",
                      isSupported: { $0.supportsFeature(DeviceCapabilities.keyboard) },
                      isEnabled: { $0.session.canPerformCommands && $0.session.connectsHardwareKeyboard }) {
            $0.send(.press(.button(.softwareKeyboard)))
        },
        // App preferences remain available without a booted device.
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
        biometricEnrollment(.opticIDEnrolled, feature: DeviceCapabilities.opticID),
        biometric(.opticIDMatching, title: "Matching Eye", .opticID, matching: true),
        biometric(.opticIDNonMatching, title: "Non-matching Eye", .opticID, matching: false),
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
        DeviceCommand(id: .appleTVRemote, title: "Show Apple TV Remote", key: "r", modifiers: [.command, .shift],
                      isEnabled: { $0.session.capabilities.family == .tv },
                      stateTitle: { $0.tvRemote.isVisible ? "Hide Apple TV Remote" : "Show Apple TV Remote" }) {
            $0.tvRemote.toggle()
        },
        DeviceCommand(id: .stayOnTop, title: "Stay On Top",
                      isEnabled: { !$0.isEmbedded && $0.session.canPerformCommands },
                      state: { $0.staysOnTop ? .on : .off }) { $0.toggleStayOnTop() },
        scale(.physicalSize, title: "Physical Size", key: "1"),
        scale(.pointAccurate, title: "Point Accurate", key: "2"),
        scale(.pixelAccurate, title: "Pixel Accurate", key: "3"),
        scale(.fitScreen, title: "Fit Screen", key: "4"),
    ] + ExternalDisplayMode.allCases.map { externalDisplay($0) }).map { ($0.id, $0) })

    /// Fit Screen has no checkmark; fixed-scale checkmarks persist while unavailable.
    private static func scale(_ mode: WindowScaleMode, title: String, key: String) -> DeviceCommand {
        DeviceCommand(id: ID(rawValue: mode.rawValue)!, title: title, key: key,
                      isEnabled: { $0.scaledWindow.canSetScale(mode) },
                      state: mode == .fitScreen ? nil : { $0.scaledWindow.scaleState(mode) },
                      keepsStateWithoutWindow: true) { $0.scaledWindow.setScale(mode) }
    }

    /// External-display choices remain available during restart and apply on reconnection.
    /// Checkmarks follow actual state; unsupported choices show a reason and are disabled.
    private static func externalDisplay(_ mode: ExternalDisplayMode) -> DeviceCommand {
        let hasFeature: (DeviceWindowController) -> Bool = {
            mode != .carPlay || $0.session.capabilities.supportsCarPlay
        }
        return DeviceCommand(id: mode.commandID, title: mode.title,
                             isSupported: { $0.supportsExternalDisplays },
                             isEnabled: { hasFeature($0) && $0.session.externalDisplayLimit(for: mode) == nil },
                             state: { hasFeature($0) && $0.session.externalDisplayMode == mode ? .on : .off },
                             stateSubtitle: {
                                 hasFeature($0) ? $0.session.externalDisplayLimit(for: mode)?.menuSubtitle : nil
                             }) {
            $0.chooseExternalDisplay(mode)
        }
    }

    /// Watch-only menu choices update the app-wide touch-pressure mode.
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

    /// Touch ID ▸ Enrolled, Face ID ▸ Enrolled, or Optic ID ▸ Enrolled. They
    /// share one guest state.
    private static func biometricEnrollment(_ id: ID, feature: String) -> DeviceCommand {
        DeviceCommand(id: id, title: "Enrolled", isSupported: { $0.supportsFeature(feature) },
                      state: { $0.session.isBiometricEnrolled ? .on : .off }) { controller in
            controller.run { try controller.session.toggleBiometricEnrollment() }
        }
    }

    /// Shared biometric shortcuts prefer Face ID, then Touch ID.
    /// Optic ID has no shortcut on Vision Pro, matching Simulator.app.
    private static func biometric(_ id: ID, title: String, _ biometric: DeviceSession.Biometric,
                                  matching: Bool) -> DeviceCommand {
        DeviceCommand(id: id, title: title, key: matching ? "m" : "n", modifiers: [.command, .option],
                      hasKey: { capabilities in
                          let faceID = capabilities?.supportsFeature(DeviceCapabilities.faceID) ?? false
                          return biometric == .touchID ? !faceID : faceID
                      },
                      isSupported: { $0.supportsFeature(biometric.feature) }) { controller in
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

    /// Graphics quality applies immediately; Apple TV also queues a system-UI restart.
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

    /// Simulator.app toolbar order; capability validation omits unsupported items.
    static let toolbarItems: [ID] = [.captureKeyboard, .home, .saveScreen, .rotateRight, .alwaysOn]
}

/// Plugin commands use the first-responder chain for validation and execution.
/// The XROS overlay supplies checkmarks, scene submenus, and actions;
/// without it in the key window, AppKit disables these commands.
@MainActor
struct PluginCommand {
    let title: String
    let action: Selector
    var key = ""
    var modifiers: NSEvent.ModifierFlags = []
    /// Whether the key device shows the item, as Simulator.app's
    /// `deviceWindowBecameKey:` decides. By default, only Apple Vision shows it.
    var isShown: (DeviceCapabilities) -> Bool = { $0.family == .vision }

    /// The command whose item sends `action`.
    static func command(for action: Selector) -> PluginCommand? { byAction[action] }

    // Device. Simulator.app shows Re-Center Open Apps for every device, where
    // only Apple Vision Pro's overlay takes it.
    static let recenterOpenApps = PluginCommand(title: "Re-Center Open Apps", action: Selector(("recenterAllOpenApps:")),
                                                isShown: { _ in true })
    static let viewportModes = [
        PluginCommand(title: "Interaction Mode", action: Selector(("viewportModeChangedToInteraction:")), key: "1",
                      modifiers: [.control, .command]),
        PluginCommand(title: "Look Around Mode", action: Selector(("viewportModeChangedToLookAround:")), key: "2",
                      modifiers: [.control, .command]),
        PluginCommand(title: "Pan Mode", action: Selector(("viewportModeChangedToPan:")), key: "3",
                      modifiers: [.control, .command]),
        PluginCommand(title: "Orbit Mode", action: Selector(("viewportModeChangedToOrbit:")), key: "4",
                      modifiers: [.control, .command]),
        PluginCommand(title: "Dolly Mode", action: Selector(("viewportModeChangedToDolly:")), key: "5",
                      modifiers: [.control, .command]),
    ]
    static let resetCamera = PluginCommand(title: "Reset Camera", action: Selector(("resetViewportCamera:")), key: "0",
                                           modifiers: [.control, .command])
    /// The overlay gives the item a submenu of the runtime's scenes when it
    /// validates it.
    static let simulatedScenes = PluginCommand(title: "Simulated Scenes", action: Selector(("selectSimulatedScene:")))
    // I/O ▸ Set Immersion To. Simulator.app also has Increase Immersion and
    // Decrease Immersion, and 0% and 25% here, but hides them for every device.
    static let immersionLevels = [
        PluginCommand(title: "50%", action: Selector(("setImmersionTo50:"))),
        PluginCommand(title: "75%", action: Selector(("setImmersionTo75:"))),
        PluginCommand(title: "100%", action: Selector(("setImmersionTo100:"))),
    ]
    // Starts a guest FaceTime call with the local user and these simulated participant counts.
    static let faceTimeSessions = [
        PluginCommand(title: "User and 1 Spatial Participant",
                      action: Selector(("configureSimulatedFaceTimeSession1x1:"))),
        PluginCommand(title: "User and 2 Spatial Participants",
                      action: Selector(("configureSimulatedFaceTimeSession1x2:"))),
        PluginCommand(title: "User and 3 Spatial Participants",
                      action: Selector(("configureSimulatedFaceTimeSession1x3:"))),
        PluginCommand(title: "User and 4 Spatial Participants",
                      action: Selector(("configureSimulatedFaceTimeSession1x4:"))),
        PluginCommand(title: "User, 1 Participant and 4 Spatial Participants",
                      action: Selector(("configureSimulatedFaceTimeSession1x4x1:"))),
        PluginCommand(title: "User, 8 Participants and 4 Spatial Participants",
                      action: Selector(("configureSimulatedFaceTimeSession1x4x8:"))),
    ]
    // Debug
    static let showGazeTarget = PluginCommand(title: "Show Gaze Target", action: Selector(("toggleShowGazeTarget:")),
                                              isShown: { $0.supportsFeature(DeviceCapabilities.hoverboard) })

    private static let byAction = Dictionary(uniqueKeysWithValues: (
        [recenterOpenApps, resetCamera, simulatedScenes, showGazeTarget] + viewportModes + immersionLevels
            + faceTimeSessions
    ).map { ($0.action, $0) })
}

/// Splits parenthesized device details into the subtitle and removes the Apple Watch title prefix.
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
        case .carPlay: .externalDisplayCarPlay
        }
    }
}
