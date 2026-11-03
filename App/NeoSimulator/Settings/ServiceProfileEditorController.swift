import AppKit
import ObservationBridge

@MainActor
final class ServiceProfileEditorController: NSViewController, NSTextFieldDelegate {
    let model: ServiceProfileEditorModel
    var onClose: (() -> Void)?
    private let nameField = NSTextField()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var observation: PortableObservationTracking.Token?

    init(model: ServiceProfileEditorModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 360, height: 160)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: preferredContentSize))
        nameField.delegate = self
        nameField.placeholderString = "Name"
        let heading = NSTextField(labelWithString: "Service Profile")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let nameRow = NSGridView(views: [[NSTextField(labelWithString: "Name"), nameField]])
        nameRow.column(at: 1).width = 240
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, NSView(), saveButton])
        let stack = NSStackView(views: [heading, nameRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setContentHuggingPriority(.required, for: .vertical)
        buttons.heightAnchor.constraint(equalToConstant: 28).isActive = true
        for child in [stack, buttons] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            buttons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])

    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = withPortableContinuousObservation { [weak self, model] _ in
            guard let self else { return }
            if nameField.stringValue != model.name { nameField.stringValue = model.name }
            saveButton.isEnabled = model.canSave
        }
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(nameField)
    }
    func controlTextDidChange(_ notification: Notification) { model.name = nameField.stringValue }
    @objc private func cancel() { close() }
    @objc private func save() {
        if model.commit() { close() }
        else if let issue = model.issue, let window = view.window {
            let alert = NSAlert()
            alert.messageText = "Unable to Save Service Profile"
            alert.informativeText = issue
            alert.beginSheetModal(for: window)
        }
    }
    private func close() {
        if let onClose { onClose() }
        else { dismiss(self) }
    }
}
