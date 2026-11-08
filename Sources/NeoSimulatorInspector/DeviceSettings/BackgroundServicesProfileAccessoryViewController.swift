import AppKit
import NeoSimulatorManager
import ObservationBridge

/// Chooses the selected simulator's service profile above its services, and saves or reverts their changes.
@MainActor
final class BackgroundServicesProfileAccessoryViewController: NSSplitViewItemAccessoryViewController {
    let model: BackgroundServicesInspectorModel
    let profileButton = NSPopUpButton()
    let revertButton = NSButton(title: "Revert", target: nil, action: nil)
    let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let actions = NSStackView()
    private var observation: PortableObservationTracking.Token?

    init(model: BackgroundServicesInspectorModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
        preferredScrollEdgeEffectStyle = .hard
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        profileButton.target = self
        profileButton.action = #selector(chooseProfile)
        profileButton.toolTip = "Applies at each simulator start while NeoSimulator is open."
        // Long profile names shorten the pop-up button's title, which takes the width the label leaves.
        profileButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let label = NSTextField(labelWithString: "Profile")
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let profile = NSStackView(views: [label, profileButton])
        profile.distribution = .fill
        profile.alignment = .firstBaseline
        revertButton.target = self
        revertButton.action = #selector(revert)
        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.tintProminence = .primary
        actions.addView(revertButton, in: .leading)
        actions.addView(saveButton, in: .trailing)
        let controls = NSStackView(views: [profile, actions])
        controls.orientation = .vertical
        controls.alignment = .width
        controls.frame.size = controls.fittingSize
        view = controls
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = withPortableContinuousObservation { [weak self] _ in
            self?.update()
        }
    }

    private func update() {
        let menu = NSMenu()
        menu.addItem(profileItem(model.defaultProfileChoice))
        let choices = model.profileChoices
        if !choices.isEmpty {
            menu.addItem(.separator())
            for choice in choices {
                menu.addItem(profileItem(choice))
            }
        }
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Open Settings…", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        profileButton.menu = menu
        selectProfile()
        profileButton.isEnabled = !model.holdsChanges && model.profiles.issue == nil
        // The actions show while the simulator's services differ from its profile, even while they cannot run.
        actions.isHidden = !model.hasProfileChanges
        revertButton.isEnabled = model.canRevertProfile
        saveButton.isEnabled = model.canSaveProfile
    }

    private func profileItem(_ choice: BackgroundServicesInspectorModel.ProfileChoice) -> NSMenuItem {
        let item = NSMenuItem(title: choice.title, action: nil, keyEquivalent: "")
        item.representedObject = choice.id
        return item
    }

    private func selectProfile() {
        let selection = model.selectedProfileSelection
        profileButton.select(
            profileButton.itemArray.first { $0.representedObject as? ServiceProfileSelection == selection }
        )
    }

    @objc private func chooseProfile() {
        guard let selection = profileButton.selectedItem?.representedObject as? ServiceProfileSelection else {
            return
        }
        model.selectedProfileSelection = selection
    }

    @objc private func openSettings() {
        // The pop-up button selects the command it sends; the simulator keeps its profile.
        selectProfile()
        model.openProfileSettings()
    }

    @objc private func revert() { model.revertProfile() }

    @objc private func save() { model.saveProfile() }
}
