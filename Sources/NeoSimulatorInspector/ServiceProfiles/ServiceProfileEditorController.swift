import NeoSimulatorKit
import NeoSimulatorHostSupport
import AppKit
import ObservationBridge

@MainActor
final class ServiceProfileEditorController: NSViewController, NSTextFieldDelegate {
    let model: ServiceProfileEditorModel
    var onClose: (() -> Void)?
    private let nameField = LiteralTextField()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private var observation: PortableObservationTracking.Token?

    init(model: ServiceProfileEditorModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let heading = NSTextField(labelWithString: "Service Profile")
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        nameField.delegate = self
        nameField.placeholderString = "Name"
        let label = NSTextField(labelWithString: "Name")
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let name = NSStackView(views: [label, nameField])
        name.distribution = .fill
        name.alignment = .firstBaseline
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        let buttons = NSStackView()
        buttons.addView(cancel, in: .leading)
        buttons.addView(saveButton, in: .trailing)
        let content = NSStackView(views: [heading, name, buttons])
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 14
        content.setCustomSpacing(20, after: name)
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        // The sheet keeps its width and takes the height of its contents.
        content.widthAnchor.constraint(equalToConstant: 360).isActive = true
        content.frame.size = content.fittingSize
        view = content
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
        if model.commit() {
            close()
        } else if let issue = model.issue, let window = view.window {
            let alert = NSAlert()
            alert.messageText = "Unable to Save Service Profile"
            alert.informativeText = issue
            alert.beginSheetModal(for: window)
        }
    }
    private func close() {
        if let onClose { onClose() } else { dismiss(self) }
    }
}

#if DEBUG
    #Preview("Save Profile", traits: .sizeThatFitsLayout) {
        let model = ServiceProfileEditorModel(name: "", configuration: ServiceConfiguration())
        model.save = { _ in }
        return ServiceProfileEditorController(model: model)
    }
#endif
