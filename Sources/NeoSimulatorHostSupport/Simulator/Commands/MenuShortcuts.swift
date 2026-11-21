import AppKit
import NeoSimulatorKit
import NeoSimulatorPresentationAdapters
import NeoSimulatorUI
import Observation

/// An AppKit key equivalent. The saved value uses the modifier prefixes from Apple's key bindings format.
package struct MenuShortcut: Equatable {
    package let key: String
    package let modifiers: NSEvent.ModifierFlags

    private static let prefixes: [(NSEvent.ModifierFlags, Character, String)] = [
        (.control, "^", "⌃"), (.option, "~", "⌥"), (.shift, "$", "⇧"), (.command, "@", "⌘"),
    ]

    package init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        self.modifiers =
            key.isEmpty
            ? []
            : modifiers.intersection([.control, .option, .shift, .command])
                .union(key != self.key ? .shift : [])
    }

    package init?(event: NSEvent) {
        guard let key = event.unshiftedMenuKey, key.count == 1 else { return nil }
        self.init(key: key.lowercased(), modifiers: event.modifierFlags)
    }

    /// AppKit accepts both a shifted base key and the symbol that key types on the current layout.
    fileprivate var equivalents: [Self] {
        var result = [self]
        guard !key.isEmpty, key == key.uppercased(), key == key.lowercased() else { return result }
        for code: UInt16 in 0..<128 {
            guard
                let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true).flatMap(
                    NSEvent.init(cgEvent:)),
                event.type == .keyDown, event.specialKey == nil, let base = event.characters(byApplyingModifiers: []),
                let shifted = event.characters(byApplyingModifiers: .shift), base != shifted,
                base.count == 1, shifted.count == 1
            else { continue }
            let explicit = Self(key: base, modifiers: modifiers.union(.shift))
            let symbol = Self(key: shifted, modifiers: modifiers.subtracting(.shift))
            if self == explicit { result.append(symbol) }
            if self == symbol { result.append(explicit) }
        }
        return result
    }

    fileprivate init(saved: String) {
        let flags = Self.prefixes.reduce(into: NSEvent.ModifierFlags()) { result, prefix in
            if saved.dropLast().contains(prefix.1) { result.insert(prefix.0) }
        }
        self.init(key: String(saved.suffix(1)), modifiers: flags)
    }

    fileprivate var saved: String { String(Self.prefixes.compactMap { modifiers.contains($0.0) ? $0.1 : nil }) + key }

    private static let keyNames = [
        " ": "Space", "\r": "↩", "\t": "⇥", "\u{1b}": "⎋", "\u{7f}": "⌦", "\u{8}": "⌫",
        "\u{f700}": "↑", "\u{f701}": "↓", "\u{f702}": "←", "\u{f703}": "→", "\u{f728}": "⌦",
        "\u{f729}": "↖", "\u{f72b}": "↘", "\u{f72c}": "⇞", "\u{f72d}": "⇟",
    ]

    package var display: String {
        guard !key.isEmpty else { return "—" }
        let symbols = Self.prefixes.compactMap { modifiers.contains($0.0) ? $0.2 : nil }.joined()
        if let scalar = key.unicodeScalars.first?.value, (0xf704...0xf726).contains(scalar) {
            return symbols + "F\(scalar - 0xf704 + 1)"
        }
        return symbols + (Self.keyNames[key] ?? key.uppercased())
    }
}

/// The app's menu commands and their user-assigned shortcuts. Both display hosts use the renderer defaults.
@MainActor @Observable
package final class MenuShortcuts {
    package struct Command: Identifiable {
        package let id: String
        package let menu: String
        package let title: String
        package let standard: MenuShortcut
    }

    private struct Entry {
        weak var item: NSMenuItem?
        let command: Command
        let wasAlternate: Bool
        let standardModifiers: NSEvent.ModifierFlags
    }

    private static let preference = "MenuKeyboardShortcuts"
    private let defaults: UserDefaults
    @ObservationIgnored private var observation: DefaultsObservation?
    @ObservationIgnored private var entries: [String: Entry] = [:]
    @ObservationIgnored private var capabilities: DeviceCapabilities?
    package private(set) var commands: [Command] = []
    private var overrides: [String: String]
    package var hasChanges: Bool { !overrides.isEmpty }

    package init(defaults: UserDefaults = HostPreferences.defaults) {
        self.defaults = defaults
        overrides = defaults.dictionary(forKey: Self.preference) as? [String: String] ?? [:]
        observation = DefaultsObservation(defaults, keys: [Self.preference]) { [weak self] in
            guard let self else { return }
            let saved = defaults.dictionary(forKey: Self.preference) as? [String: String] ?? [:]
            if saved != overrides {
                overrides = saved
                apply()
            }
        }
    }

    /// Fixed commands in menus whose items AppKit builds for the current device on demand.
    package func register(titles: [String], path: [String]) {
        for title in titles {
            let command = Command(
                id: (path + [title]).joined(separator: "/"), menu: path.joined(separator: " › "),
                title: title, standard: .init(key: "", modifiers: []))
            if !commands.contains(where: { $0.id == command.id }) { commands.append(command) }
        }
    }

    package func register(_ menu: NSMenu, path: [String] = [], declaredOnly: Bool = false) {
        for item in menu.items {
            if let submenu = item.submenu {
                register(submenu, path: path + [item.title], declaredOnly: declaredOnly)
            } else if let action = item.action, !item.isSeparatorItem, !item.title.isEmpty {
                let deviceID = (item.representedObject as? String).flatMap(DeviceCommand.ID.init(rawValue:))
                let deviceCommand = deviceID.map(DeviceCommand.command)
                // AppKit gives every item with the same action the same implicit identifier.
                let identifier = item.identifier?.rawValue
                let explicitID = identifier == NSStringFromSelector(action) ? nil : identifier
                let id = deviceID?.rawValue ?? explicitID ?? (path + [item.title]).joined(separator: "/")
                if entries[id]?.item === item { continue }
                let isDeclared = commands.contains { $0.id == id }
                if declaredOnly && !isDeclared { continue }
                let modifiers = deviceCommand?.modifiers ?? item.keyEquivalentModifierMask
                let command = Command(
                    id: id, menu: path.joined(separator: " › "), title: deviceCommand?.shortcutTitle ?? item.title,
                    standard: MenuShortcut(key: deviceCommand?.key ?? item.keyEquivalent, modifiers: modifiers))
                let entry = Entry(
                    item: item, command: command, wasAlternate: item.isAlternate, standardModifiers: modifiers)
                if !isDeclared { commands.append(command) }
                entries[id] = entry
                apply(entry)
            }
        }
    }

    /// Limit the lookup to a submenu when it needs to build its items for the current selection.
    package func hasCustomShortcut(for event: NSEvent, in path: [String]? = nil) -> Bool {
        let prefix = path.map { ($0 + [""]).joined(separator: "/") }
        return overrides.contains { id, value in
            if let prefix, !id.hasPrefix(prefix) { return false }
            let shortcut = MenuShortcut(saved: value)
            return event.matchesMenuKey(shortcut.key, modifiers: shortcut.modifiers)
        }
    }

    package func shortcut(for command: Command) -> MenuShortcut {
        overrides[command.id].map(MenuShortcut.init(saved:)) ?? command.standard
    }

    /// Some standard shortcuts are shared by mutually exclusive commands, such as Face ID and Touch ID.
    package func conflicts(for shortcut: MenuShortcut, with command: Command) -> [Command] {
        guard !shortcut.key.isEmpty else { return [] }
        let equivalents = shortcut.equivalents
        return commands.filter {
            $0.id != command.id && equivalents.contains(self.shortcut(for: $0))
                && !(command.standard == shortcut && $0.standard == shortcut)
        }
    }

    package func assign(_ shortcut: MenuShortcut, to command: Command) {
        var saved = overrides
        for conflict in conflicts(for: shortcut, with: command) {
            saved[conflict.id] = conflict.standard.key.isEmpty ? nil : ""
        }
        saved[command.id] = shortcut == command.standard ? nil : shortcut.saved
        store(saved)
    }

    package func restoreDefaults() { store([:]) }

    private func store(_ saved: [String: String]) {
        overrides = saved
        if saved.isEmpty {
            defaults.removeObject(forKey: Self.preference)
        } else {
            defaults.set(saved, forKey: Self.preference)
        }
        apply()
    }

    package func update(for capabilities: DeviceCapabilities?) {
        self.capabilities = capabilities
        apply()
    }

    private func apply() {
        for entry in entries.values { apply(entry) }
    }

    private func apply(_ entry: Entry) {
        guard let item = entry.item else { return }
        let command = entry.command
        let binding = shortcut(for: command)
        var key = binding.key
        if let raw = item.representedObject as? String, let id = DeviceCommand.ID(rawValue: raw) {
            let device = DeviceCommand.command(id)
            if overrides[command.id] == nil, device.hasKey?(capabilities) == false { key = "" }
            if overrides[command.id] != nil, let capabilities, !device.isSupported(capabilities) { key = "" }
        } else if overrides[command.id] != nil, let action = item.action,
            let plugin = PluginCommand.command(for: action),
            let capabilities, !plugin.isShown(capabilities)
        {
            key = ""
        }
        let modifiers = binding.key.isEmpty ? entry.standardModifiers : binding.modifiers
        if item.keyEquivalent != key { item.keyEquivalent = key }
        if item.keyEquivalentModifierMask != modifiers { item.keyEquivalentModifierMask = modifiers }
        let alternate = entry.wasAlternate && overrides[command.id] == nil
        if item.isAlternate != alternate { item.isAlternate = alternate }
    }
}
