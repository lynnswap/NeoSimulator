import AppKit
import NeoSimulatorHostSupport
import SwiftUI

@MainActor
final class KeyboardShortcutsSettingsViewController: NSHostingController<KeyboardShortcutsSettingsView> {
    init(shortcuts: MenuShortcuts) {
        super.init(rootView: KeyboardShortcutsSettingsView(shortcuts: shortcuts))
        title = "Keyboard Shortcuts"
        sizingOptions = [.preferredContentSize]
    }

    required init?(coder: NSCoder) { nil }
}

struct KeyboardShortcutsSettingsView: View {
    let shortcuts: MenuShortcuts
    @State private var query = ""
    @State private var sortOrder = [KeyPathComparator(\MenuShortcuts.Command.menu), KeyPathComparator(\.title)]
    @State private var selection: String?
    @State private var editing: MenuShortcuts.Command?
    @State private var confirmsReset = false

    private var filtered: [MenuShortcuts.Command] {
        if query.isEmpty { return shortcuts.commands }
        return shortcuts.commands.filter {
            $0.title.localizedStandardContains(query) || $0.menu.localizedStandardContains(query)
                || shortcuts.shortcut(for: $0).display.localizedStandardContains(query)
        }
    }

    var body: some View {
        let commands = filtered.sorted(using: sortOrder)
        let selected = commands.first { $0.id == selection }
        VStack(alignment: .leading, spacing: 10) {
            TextField("Filter commands", text: $query)
                .textFieldStyle(.roundedBorder)
            Table(commands, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Command", value: \.title)
                TableColumn("Menu", value: \.menu)
                TableColumn("Shortcut") { command in
                    Text(verbatim: shortcuts.shortcut(for: command).display)
                }
                .width(100)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let command = commands.first(where: { ids.contains($0.id) }) {
                    Button("Edit Shortcut…") { editing = command }
                }
            } primaryAction: { ids in
                editing = commands.first { ids.contains($0.id) }
            }
            HStack {
                Button("Restore Defaults…") { confirmsReset = true }
                    .disabled(!shortcuts.hasChanges)
                Spacer()
                Button("Edit Shortcut…") { editing = selected }
                    .disabled(selected == nil)
            }
        }
        .padding()
        .frame(width: 680, height: 400)
        .sheet(item: $editing) { command in
            ShortcutEditor(command: command, shortcuts: shortcuts)
        }
        .confirmationDialog("Restore all default keyboard shortcuts?", isPresented: $confirmsReset) {
            Button("Restore Defaults", role: .destructive) { shortcuts.restoreDefaults() }
        }
    }
}

private struct ShortcutEditor: View {
    let command: MenuShortcuts.Command
    let shortcuts: MenuShortcuts
    @Environment(\.dismiss) private var dismiss
    @State private var proposed: MenuShortcut?
    @State private var recording = true

    var body: some View {
        let current = shortcuts.shortcut(for: command)
        let binding = proposed ?? current
        let conflicts = shortcuts.conflicts(for: binding, with: command)
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: command.title).font(.headline)
            ShortcutRecorder(recording: $recording, shortcut: binding) { proposed = $0 }
                .frame(maxWidth: .infinity)
                .frame(height: 32)
            if !conflicts.isEmpty {
                let names = conflicts.map { $0.menu + " › " + $0.title }.formatted(.list(type: .and))
                Text("Reassigning this shortcut will remove it from \(names).")
            }
            HStack {
                Button("Clear") {
                    proposed = MenuShortcut(key: "", modifiers: [])
                    recording = false
                }.disabled(binding.key.isEmpty)
                Button("Use Default") {
                    proposed = command.standard
                    recording = false
                }.disabled(binding == command.standard)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(conflicts.isEmpty ? "Save" : "Reassign") {
                    shortcuts.assign(binding, to: command)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(binding == current)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @Binding var recording: Bool
    let shortcut: MenuShortcut
    let captured: (MenuShortcut) -> Void

    func makeNSView(context: Context) -> RecorderButton {
        RecorderButton(title: "", target: nil, action: nil)
    }

    func updateNSView(_ button: RecorderButton, context: Context) {
        button.title = recording ? "Press a keyboard shortcut…" : shortcut.display + "   ·   Record Again"
        button.bezelStyle = .rounded
        button.onClick = { recording = true }
        button.endRecording = { recording = false }
        button.capture =
            recording
            ? { binding in
                captured(binding)
                recording = false
            } : nil
    }

    @MainActor final class RecorderButton: NSButton {
        var onClick: (() -> Void)?
        var endRecording: (() -> Void)?
        var capture: ((MenuShortcut) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            target = self
            action = #selector(recordAgain)
            // Receive the chord before a menu command such as Command-Q can handle it.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let capture, let window, event.window === window,
                    let shortcut = MenuShortcut(event: event)
                else { return event }
                if event.keyCode == 48, shortcut.modifiers.subtracting(.shift).isEmpty {
                    endRecording?()
                    return event
                }
                if shortcut.modifiers.isEmpty, ["\u{1b}", "\r"].contains(shortcut.key) { return event }
                guard !event.isARepeat else { return nil }
                capture(shortcut)
                return nil
            }
        }

        isolated deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        @objc private func recordAgain() { onClick?() }
    }
}
