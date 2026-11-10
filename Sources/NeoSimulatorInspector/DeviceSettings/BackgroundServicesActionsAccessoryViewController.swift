import AppKit
import NeoSimulatorManager
import ObservationBridge

@MainActor
final class BackgroundServicesActionsAccessoryViewController: NSSplitViewItemAccessoryViewController {
    let searchField: BackgroundServiceSearchField
    let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let model: BackgroundServicesInspectorModel
    private let actions = NSStackView()
    private var observation: PortableObservationTracking.Token?

    init(model: BackgroundServicesInspectorModel, list: BackgroundServiceListModel) {
        self.model = model
        searchField = BackgroundServiceSearchField(model: list)
        super.init(nibName: nil, bundle: nil)
        automaticallyAppliesContentInsets = false
        preferredScrollEdgeEffectStyle = .hard
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        revertButton.target = self
        revertButton.action = #selector(revert)
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.tintProminence = .primary
        actions.addArrangedSubview(revertButton)
        actions.addArrangedSubview(saveButton)
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [searchField, actions])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.distribution = .fill
        controls.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        // Hiding the actions can widen the filter, but must not change the list's top inset.
        controls.heightAnchor.constraint(equalToConstant: controls.fittingSize.height).isActive = true
        controls.frame.size = controls.fittingSize
        view = controls
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = withPortableContinuousObservation { [weak self] _ in self?.update() }
    }

    private func update() {
        searchField.isEnabled = model.canFilter
        actions.isHidden = !model.hasProfileChanges
        revertButton.isEnabled = model.canRevertProfile
        saveButton.isEnabled = model.canSaveProfile
    }

    @objc private func revert() { model.revertProfile() }
    @objc private func save() { model.saveProfile() }
}
