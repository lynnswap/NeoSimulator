import NeoSimulatorKit
@_spi(NeoSimulator) import XcodeSimulatorHost
import AppKit

@MainActor
package final class NewSimulatorWindowController: NSWindowController, NSWindowDelegate {
    package let form: NewSimulatorViewController
    private let onClose: () -> Void

    package init(model: NewSimulatorModel, reportFailure: @escaping (Error) -> Void, onClose: @escaping () -> Void = {}) {
        let form = NewSimulatorViewController(model: model)
        self.form = form
        self.onClose = onClose
        let window = NSWindow(contentViewController: form)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = form.title ?? "New Simulator"
        window.isReleasedWhenClosed = false
        window.layoutIfNeeded()
        window.setContentSize(form.preferredContentSize)
        super.init(window: window)
        window.delegate = self
        model.onCreated = { [weak self] in self?.close() }
        model.onCancel = { [weak self] in self?.close() }
        model.onFailure = { [weak self, weak model] error in
            if self?.window?.isVisible == true { model?.error = error.localizedDescription }
            else { reportFailure(error) }
        }
    }

    package required init?(coder: NSCoder) { nil }

    package func windowWillClose(_ notification: Notification) { onClose() }
}
