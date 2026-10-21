import AppKit

/// A command that acts on the active device window.
///
/// Each command is defined once here: menus, the window toolbar, and their
/// validation are built from the catalog. Titles, shortcuts, and positions
/// follow Simulator.app's MainMenu.nib where Simulator.app has the command.
@MainActor
struct DeviceCommand {
    enum ID: String, CaseIterable {
        case saveScreen, recordScreen, stopRecording, importFiles
        case shutDown, rotateLeft, rotateRight, home, lock, sideButton, actionButtonSting
        case actionButtonStaccato, siri, shake, appSwitcher, triggerScreenshot
        case toggleSoftwareKeyboard, increaseVolume, decreaseVolume, openURL
        case authorizeApplePay, toggleAppearance
        case showDeviceBezels, stayOnTop, fitScreen
    }

    struct Toolbar {
        let label: String
        let symbol: String
    }

    let id: ID
    let title: String
    var key = ""
    var modifiers: NSEvent.ModifierFlags = .command
    var toolbar: Toolbar?
    /// Whether the device supports the command. Unsupported commands are hidden.
    var isSupported: (DeviceCapabilities) -> Bool = { _ in true }
    /// Whether the command can run now. Defaults to a connected, booted device.
    var isEnabled: (DeviceWindowController) -> Bool = { $0.session.canPerformCommands }
    var state: ((DeviceWindowController) -> NSControl.StateValue)?
    let perform: (DeviceWindowController) -> Void

    static func command(_ id: ID) -> DeviceCommand { catalog[id]! }

    static let catalog: [ID: DeviceCommand] = Dictionary(uniqueKeysWithValues: [
        // File
        DeviceCommand(id: .saveScreen, title: "Save Screen…", key: "s",
                      toolbar: Toolbar(label: "Save Screen", symbol: "camera.on.rectangle"),
                      isEnabled: { $0.session.canPerformToolOperation }) { $0.saveScreenshot() },
        DeviceCommand(id: .recordScreen, title: "Record Screen…", key: "r",
                      isEnabled: { $0.session.canPerformToolOperation && $0.session.recording == nil }) { $0.chooseRecordingDestination() },
        DeviceCommand(id: .stopRecording, title: "Stop Recording",
                      toolbar: Toolbar(label: "Stop Recording", symbol: "stop.circle.fill"),
                      isEnabled: { $0.session.recording.map { !$0.isStopping } ?? false }) { $0.session.stopRecording() },
        DeviceCommand(id: .importFiles, title: "Install App or Import Media…", key: "i", modifiers: [.command, .shift],
                      isEnabled: { $0.session.canPerformToolOperation }) { $0.chooseFilesToImport() },
        // Device
        DeviceCommand(id: .shutDown, title: "Shut Down",
                      isEnabled: { $0.session.canPerformToolOperation && $0.session.recording == nil }) { $0.shutDown() },
        DeviceCommand(id: .rotateLeft, title: "Rotate Left", key: String(UnicodeScalar(NSLeftArrowFunctionKey)!),
                      isSupported: { $0.supportsFeature(DeviceCapabilities.displayRotation) },
                      isEnabled: { $0.session.canPerformToolOperation }) { $0.rotate(left: true) },
        DeviceCommand(id: .rotateRight, title: "Rotate Right", key: String(UnicodeScalar(NSRightArrowFunctionKey)!),
                      toolbar: Toolbar(label: "Rotate Right", symbol: "rotate.right"),
                      isSupported: { $0.supportsFeature(DeviceCapabilities.displayRotation) },
                      isEnabled: { $0.session.canPerformToolOperation }) { $0.rotate(left: false) },
        DeviceCommand(id: .home, title: "Home", key: "h", modifiers: [.command, .shift],
                      toolbar: Toolbar(label: "Home", symbol: "house")) { $0.send(.press(.button(.home))) },
        DeviceCommand(id: .lock, title: "Lock", key: "l") { $0.send(.press(.button(.lock))) },
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
        // I/O
        DeviceCommand(id: .toggleSoftwareKeyboard, title: "Toggle Software Keyboard", key: "k") {
            $0.send(.press(.button(.softwareKeyboard)))
        },
        DeviceCommand(id: .increaseVolume, title: "Increase Volume", key: String(UnicodeScalar(NSUpArrowFunctionKey)!),
                      isSupported: { $0.supportsFeature(DeviceCapabilities.routableAudio) }) { $0.send(.press(.volumeUp)) },
        DeviceCommand(id: .decreaseVolume, title: "Decrease Volume", key: String(UnicodeScalar(NSDownArrowFunctionKey)!),
                      isSupported: { $0.supportsFeature(DeviceCapabilities.routableAudio) }) { $0.send(.press(.volumeDown)) },
        DeviceCommand(id: .openURL, title: "Open URL…", key: "u", modifiers: [.command, .shift],
                      isEnabled: { $0.session.canPerformToolOperation }) { $0.chooseURLToOpen() },
        // Features
        DeviceCommand(id: .authorizeApplePay, title: "Authorize Apple Pay", key: "a", modifiers: [.command, .option],
                      isSupported: { $0.supportsFeature(DeviceCapabilities.applePayAuthorization) }) {
            $0.send(.press(.button(.applePay)))
        },
        DeviceCommand(id: .toggleAppearance, title: "Toggle Appearance", key: "a", modifiers: [.command, .shift],
                      isSupported: { $0.isPhoneOrPad }) { controller in controller.run { try controller.session.toggleAppearance() } },
        // Window
        DeviceCommand(id: .showDeviceBezels, title: "Show Device Bezels",
                      state: { $0.showsDeviceBezel ? .on : .off }) { $0.toggleDeviceBezel() },
        DeviceCommand(id: .stayOnTop, title: "Stay On Top",
                      state: { $0.staysOnTop ? .on : .off }) { $0.toggleStayOnTop() },
        DeviceCommand(id: .fitScreen, title: "Fit Screen", key: "4",
                      isEnabled: { $0.canFitScreen }) { $0.fitScreen() },
    ].map { ($0.id, $0) })

    /// Toolbar items in Simulator.app's iPhone toolbar order. Unsupported items
    /// are omitted; Stop Recording appears only while recording.
    static let toolbarItems: [ID] = [.home, .saveScreen, .rotateRight, .stopRecording]
}

/// Splits a device name the way Simulator.app titles its windows: the name up
/// to the first closing parenthesis stays in the title, and later parenthesized
/// groups join the runtime name in the subtitle.
func deviceWindowTitles(name: String, runtimeName: String) -> (title: String, subtitle: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let open = trimmed.firstIndex(of: "("), let close = trimmed.firstIndex(of: ")"),
          open < close, close < trimmed.index(before: trimmed.endIndex) else {
        return (trimmed, runtimeName)
    }
    let title = String(trimmed[...close])
    let suffix = trimmed[trimmed.index(after: close)...]
        .replacingOccurrences(of: ") (", with: " - ")
        .filter { $0 != "(" && $0 != ")" }
        .trimmingCharacters(in: .whitespaces)
    return (title, suffix.isEmpty ? runtimeName : "\(suffix) – \(runtimeName)")
}
