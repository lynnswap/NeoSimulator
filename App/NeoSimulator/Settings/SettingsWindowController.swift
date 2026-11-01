import AppKit

@MainActor
final class SettingsWindowController: NSWindowController {
    let settings: SettingsViewController
    init(model: SimulatorManagerModel, restart: @escaping () -> Void, makeSimulator: @escaping () async throws -> NewSimulatorModel,
         preferences: SimulatorPreferences, reportFailure: @escaping (Error) -> Void) {
        let content = SettingsViewController(model: model, restart: restart, makeSimulator: makeSimulator,
                                             preferences: preferences, reportFailure: reportFailure)
        settings = content
        let window = NSWindow(contentViewController: content)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        content.onContentSizeChange = { [weak self] in self?.resize(to: $0) }
        window.layoutIfNeeded()
        resize(to: content.selectedContentSize)
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    private func resize(to size: NSSize) {
        guard let window, size.width > 0, size.height > 0 else { return }
        let contentSize = NSSize(width: ceil(size.width), height: ceil(size.height))
        var frame = window.frame
        let height = contentSize.height + frame.height - window.contentLayoutRect.height
        frame.origin.y += frame.height - height
        frame.size = NSSize(width: contentSize.width, height: height)
        if frame != window.frame {
            window.setFrame(frame, display: true)
        }
    }

    override func showWindow(_ sender: Any?) {
        settings.reloadSimulatorIfVisible()
        super.showWindow(sender)
    }
}
