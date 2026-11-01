import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {
    private let settings: SettingsViewController
    init(model: SimulatorManagerModel, restart: @escaping () -> Void, makeSimulator: @escaping () async throws -> NewSimulatorModel,
         preferences: SimulatorPreferences, reportFailure: @escaping (Error) -> Void) {
        let content = SettingsViewController(model: model, restart: restart, makeSimulator: makeSimulator,
                                             preferences: preferences, reportFailure: reportFailure)
        settings = content
        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        settings.reloadSimulatorIfVisible()
        super.showWindow(sender)
    }
}
