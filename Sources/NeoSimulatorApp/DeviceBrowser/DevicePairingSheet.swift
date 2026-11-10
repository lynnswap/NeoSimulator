import AppKit
import NeoSimulatorDeviceIO
import NeoSimulatorKit

/// Keeps trust guidance and native PIN challenges in one cancellable sheet.
@MainActor
final class DevicePairingSheet: NSObject {
    private let panel: NSPanel
    private weak var parent: NSWindow?
    private let message = NSTextField(wrappingLabelWithString: "Unlock the device and tap Trust if asked.")
    private let code = NSTextField(string: "")
    private let submit = NSButton(title: "Pair", target: nil, action: nil)
    private let progress = NSProgressIndicator()
    private var response: CheckedContinuation<String, any Error>?
    private var cancelled = false
    private var cancelOperation: (() -> Void)?
    private var parentCloseObserver: (any NSObjectProtocol)?

    static func pair(
        _ device: CoreDeviceDevice, in window: NSWindow,
        using pair: @escaping @MainActor (String, @escaping CoreDeviceHostPairing.PINPrompt) async throws -> Void = {
            try await CoreDeviceHostPairing.pair(identifier: $0, enteringPINUsing: $1)
        }
    ) async throws {
        let sheet = DevicePairingSheet(name: device.name, parent: window)
        let task = Task {
            try await pair(device.identifier) { [sheet] failed, delay in
                try await sheet.readPIN(lastAttemptFailed: failed, retryDelay: delay)
            }
        }
        sheet.cancelOperation = { task.cancel() }
        window.beginSheet(sheet.panel) { [weak sheet] _ in
            if sheet?.cancelOperation != nil { sheet?.cancel(nil) }
        }
        defer {
            sheet.cancelOperation = nil
            sheet.finishPIN(.failure(CancellationError()))
            sheet.close()
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
            Task { @MainActor in sheet.cancel(nil) }
        }
    }

    private init(name: String, parent: NSWindow) {
        self.parent = parent
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 175),
            styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = "Pair with \(name)"
        super.init()
        parentCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: parent, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel(nil) }
        }
        code.placeholderString = "Pairing Code"
        code.setAccessibilityLabel("Pairing Code")
        code.isHidden = true
        submit.target = self
        submit.action = #selector(sendPIN(_:))
        submit.keyEquivalent = "\r"
        submit.isEnabled = false
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)
        let buttons = NSStackView(views: [progress, NSView(), cancel, submit])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8
        let content = NSStackView(views: [message, code, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 16
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        panel.contentView = content
        for view in [message, code, buttons] {
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -40).isActive = true
        }
    }

    private func readPIN(lastAttemptFailed: Bool, retryDelay: TimeInterval?) async throws -> String {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
        if let retryDelay {
            message.stringValue = "Wait before trying another pairing code."
            try await Task.sleep(for: .seconds(retryDelay))
        }
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
        message.stringValue =
            lastAttemptFailed
            ? "The code was not accepted. Enter the code shown on your device."
            : "Enter the pairing code shown on your device."
        code.stringValue = ""
        code.isHidden = false
        code.isEnabled = true
        submit.isEnabled = true
        progress.stopAnimation(nil)
        panel.makeFirstResponder(code)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { response = $0 }
        } onCancel: {
            Task { @MainActor in self.cancel(nil) }
        }
    }

    @objc private func sendPIN(_ sender: Any?) {
        let value = code.stringValue
        code.isEnabled = false
        submit.isEnabled = false
        message.stringValue = "Waiting for the device to finish pairing…"
        progress.startAnimation(nil)
        finishPIN(.success(value))
    }

    @objc private func cancel(_ sender: Any?) {
        guard !cancelled else { return }
        cancelled = true
        cancelOperation?()
        finishPIN(.failure(CancellationError()))
        close()
    }

    private func finishPIN(_ result: Result<String, any Error>) {
        guard let response else { return }
        self.response = nil
        response.resume(with: result)
    }

    isolated deinit {
        if let parentCloseObserver { NotificationCenter.default.removeObserver(parentCloseObserver) }
    }

    private func close() {
        if panel.sheetParent != nil { parent?.endSheet(panel) }
        panel.orderOut(nil)
    }
}
