import NeoSimulatorKit
import NeoSimulatorHostSupport
import NeoSimulatorManager
import AppKit
import ObservationBridge
import SwiftUI

/// Lists the selected simulator's background services, with the profile above and its actions beside the filter.
@MainActor
final class BackgroundServicesViewController: NSViewController {
    let model: BackgroundServicesInspectorModel
    let profileAccessory: BackgroundServicesProfileAccessoryViewController
    private lazy var outline = BackgroundServiceOutlineController(categories: model.categories)
    private(set) lazy var actionsAccessory = BackgroundServicesActionsAccessoryViewController(
        model: model, list: outline.model)
    private lazy var unavailable = NSHostingView(rootView: BackgroundServicesUnavailable(model: model))
    private var accessoriesObservation: PortableObservationTracking.Token?
    private var observation: PortableObservationTracking.Token?
    private var editor: ServiceProfileEditorController?
    private var issueAlert: NSAlert?

    init(model: BackgroundServicesInspectorModel) {
        self.model = model
        profileAccessory = BackgroundServicesProfileAccessoryViewController(model: model)
        super.init(nibName: nil, bundle: nil)
        // The split view item shows the accessories whether or not this page has loaded.
        accessoriesObservation = withPortableContinuousObservation { [weak self] _ in
            self?.updateAccessories()
        }
    }

    required init?(coder: NSCoder) { nil }

    /// Adds this page's accessories to the split view item that shows the page.
    func addAccessories(to item: NSSplitViewItem) {
        item.addTopAlignedAccessoryViewController(profileAccessory)
        item.addBottomAlignedAccessoryViewController(actionsAccessory)
    }

    override func loadView() {
        view = NSView()
        unavailable.sizingOptions = []
        addChild(outline)
        // The list fills the page so that it scrolls behind the accessories, which inset it.
        for child in [outline.view, unavailable] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                child.topAnchor.constraint(equalTo: view.topAnchor),
                child.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = withPortableContinuousObservation { [weak self] _ in
            self?.update()
        }
    }

    // Observed changes arrive after the turn that swaps pages, and the accessories show and hide with the page.
    override func viewWillAppear() {
        super.viewWillAppear()
        updateAccessories()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        updateAccessories()
    }

    private func updateAccessories() {
        profileAccessory.isHidden = !model.showsAccessories
        actionsAccessory.isHidden = !model.showsAccessories
    }

    private func update() {
        outline.model.setCategories(model.categories)
        outline.view.isHidden = !model.canFilter
        unavailable.isHidden = model.canFilter
        outline.isEnabled = !model.holdsChanges
        showEditor(model.profileEditor)
        showIssue(model.actionIssue)
    }

    private func showEditor(_ model: ServiceProfileEditorModel?) {
        guard editor?.model !== model else { return }
        if let editor {
            dismiss(editor)
            self.editor = nil
        }
        guard let model else { return }
        let editor = ServiceProfileEditorController(model: model)
        editor.onClose = { [weak self] in
            self?.model.profileEditor = nil
        }
        self.editor = editor
        presentAsSheet(editor)
    }

    private func showIssue(_ issue: String?) {
        guard let issue, issueAlert == nil, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Unable to Save Service Profile"
        alert.informativeText = issue
        issueAlert = alert
        alert.beginSheetModal(for: window) { [weak self] _ in
            self?.issueAlert = nil
            self?.model.actionIssue = nil
        }
    }
}

private struct BackgroundServicesUnavailable: View {
    let model: BackgroundServicesInspectorModel

    var body: some View {
        switch model.content {
        case .noSelection:
            ContentUnavailableView(
                "Select a Device", systemImage: "cpu",
                description: Text("Select one simulator to change its background services."))
        case .multipleSelection:
            ContentUnavailableView(
                "Multiple Devices Selected", systemImage: "cpu",
                description: Text("Select one simulator to change its background services."))
        case .unsupportedDevice:
            ContentUnavailableView(
                "Background Services Unavailable", systemImage: "cpu",
                description: Text("Background services can be changed only on simulators."))
        case .simulator(.loading):
            ProgressView("Loading background services…")
        case .simulator(.unavailableRuntime):
            ContentUnavailableView(
                "Runtime Unavailable", systemImage: "cpu",
                description: Text("Install a compatible runtime to use this simulator."))
        case .simulator(.stopped):
            ContentUnavailableView(
                "Simulator Stopped", systemImage: "cpu",
                description: Text("Start this simulator to change individual services."))
        case .simulator(.failure(let issue)):
            ContentUnavailableView {
                Label("Unable to Load Services", systemImage: "cpu")
            } description: {
                Text(issue)
            } actions: {
                Button("Try Again", action: model.requestRefresh)
            }
        case .simulator(.services):
            EmptyView()
        }
    }
}

#if DEBUG
    #Preview("Profile + Overrides", traits: .fixedLayout(width: 320, height: 820)) {
        BackgroundServicesPreview.make(.overrides)
    }

    #Preview("Use Default", traits: .fixedLayout(width: 320, height: 820)) {
        BackgroundServicesPreview.make(.defaultProfile)
    }

    #Preview("Use Default (Modified)", traits: .fixedLayout(width: 320, height: 820)) {
        BackgroundServicesPreview.make(.defaultModified)
    }

    #Preview("Stopped Simulator", traits: .fixedLayout(width: 320, height: 820)) {
        BackgroundServicesPreview.make(.stopped)
    }
#endif
