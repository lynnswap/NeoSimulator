import AppKit
import Observation

enum DeviceCommand: String {
    case home, lock, keyboard, screenshot, rotateLeft, rotateRight
    case shake, appearance, bezel, stayOnTop, fit, shutdown
    case recording, importFiles, openURL
}

@MainActor @Observable
final class DeviceToolbarState {
    var isBusy = false
    var isConnected = true
    var recording: VideoRecording?
}

@MainActor
final class DeviceToolbar: NSObject, NSToolbarDelegate {
    let toolbar = NSToolbar(identifier: "DeviceToolbar")
    private let state: DeviceToolbarState
    private let perform: (DeviceCommand) -> Void

    init(state: DeviceToolbarState, perform: @escaping (DeviceCommand) -> Void) {
        self.state = state
        self.perform = perform
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        updateItems()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, identifier(.home), identifier(.screenshot), identifier(.rotateRight), identifier(.recording)]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let command = DeviceCommand(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let title: String
        let symbol: String
        switch command {
        case .home: (title, symbol) = ("Home", "house")
        case .screenshot: (title, symbol) = ("Save Screen", "camera.on.rectangle")
        case .rotateRight: (title, symbol) = ("Rotate Right", "rotate.right")
        case .recording: (title, symbol) = ("Stop Recording", "stop.circle.fill")
        default: return nil
        }
        item.label = title
        item.toolTip = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        item.target = self
        item.action = #selector(activate(_:))
        item.autovalidates = false
        configure(item, command: command)
        return item
    }

    private func identifier(_ command: DeviceCommand) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier(command.rawValue)
    }

    private func configure(_ item: NSToolbarItem, command: DeviceCommand) {
        item.isEnabled = state.isConnected && (command == .home || !state.isBusy)
        if command == .recording {
            item.isHidden = state.recording == nil
            item.isEnabled = state.isConnected && (state.recording.map { !$0.isStopping } ?? false)
            item.image = item.image?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        }
    }

    private func updateItems() {
        withObservationTracking {
            // Read these even before AppKit has asked the delegate to create items.
            _ = state.isBusy
            _ = state.isConnected
            _ = state.recording?.isStopping
            for item in toolbar.items {
                if let command = DeviceCommand(rawValue: item.itemIdentifier.rawValue) {
                    configure(item, command: command)
                }
            }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.updateItems() }
        }
    }

    @objc private func activate(_ sender: NSToolbarItem) {
        if let command = DeviceCommand(rawValue: sender.itemIdentifier.rawValue) { perform(command) }
    }
}
