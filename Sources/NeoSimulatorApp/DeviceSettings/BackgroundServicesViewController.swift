import NeoSimulatorKit
import NeoSimulatorHostSupport
import AppKit
import ObservationBridge
import SwiftUI

@MainActor
final class BackgroundServicesViewController: NSViewController {
    let model: BackgroundServicesInspectorModel
    private lazy var outline = BackgroundServiceOutlineController(categories: model.categories, showsDetails: false)
    var searchAccessory: BackgroundServiceSearchAccessoryViewController { outline.searchAccessory }
    var isVisible = false { didSet { updateSearchVisibility() } }

    private func updateSearchVisibility() {
        if case .simulator = model.content { searchAccessory.isHidden = !isVisible }
        else { searchAccessory.isHidden = true }
    }
    private let placeholder = NSHostingView(rootView: BackgroundServicesUnavailable(content: .noSelection))
    private var observation: PortableObservationTracking.Token?
    private var shownContent: BackgroundServicesInspectorModel.Content?

    init(model: BackgroundServicesInspectorModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        view = NSView()
        placeholder.sizingOptions = []
        addChild(outline)
        for child in [outline.view, placeholder] {
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
        observation = withPortableContinuousObservation { [weak self] _ in self?.update() }
    }

    private func update() {
        updateSearchVisibility()
        let current = model.content
        if shownContent != current {
            shownContent = current
            placeholder.rootView = BackgroundServicesUnavailable(content: current, retry: model.requestRefresh)
        }
        let hasServices = current == .simulator(.services)
        outline.view.isHidden = !hasServices
        placeholder.isHidden = hasServices
        outline.isEnabled = !model.holdsChanges
        searchAccessory.searchField.isEnabled = hasServices
    }
}

private struct BackgroundServicesUnavailable: View {
    let content: BackgroundServicesInspectorModel.Content
    var retry: () -> Void = {}

    var body: some View {
        switch content {
        case .noSelection:
            ContentUnavailableView("Select a Device", systemImage: "cpu",
                description: Text("Select one simulator to change its background services."))
        case .multipleSelection:
            ContentUnavailableView("Multiple Devices Selected", systemImage: "cpu",
                description: Text("Select one simulator to change its background services."))
        case .unsupportedDevice:
            ContentUnavailableView("Background Services Unavailable", systemImage: "cpu",
                description: Text("Background services can be changed only on simulators."))
        case .simulator(.loading):
            ProgressView("Loading background services…")
        case .simulator(.unavailableRuntime):
            ContentUnavailableView("Runtime Unavailable", systemImage: "cpu",
                description: Text("Install a compatible runtime to use this simulator."))
        case .simulator(.stopped):
            ContentUnavailableView("Simulator Stopped", systemImage: "cpu",
                description: Text("Start this simulator to change individual services."))
        case .simulator(.failure(let issue)):
            ContentUnavailableView {
                Label("Unable to Load Services", systemImage: "cpu")
            } description: {
                Text(issue)
            } actions: {
                Button("Try Again", action: retry)
            }
        case .simulator(.services):
            EmptyView()
        }
    }
}

#if DEBUG
#Preview("Profile + Overrides", traits: .sizeThatFitsLayout) { BackgroundServicesPreview(.overrides).frame(width: 320, height: 820) }
#Preview("Use Default", traits: .sizeThatFitsLayout) { BackgroundServicesPreview(.defaultProfile).frame(width: 320, height: 820) }
#Preview("Use Default (Modified)", traits: .sizeThatFitsLayout) { BackgroundServicesPreview(.defaultModified).frame(width: 320, height: 820) }
#Preview("Stopped Simulator", traits: .sizeThatFitsLayout) { BackgroundServicesPreview(.stopped).frame(width: 320, height: 820) }
#Preview("Save Profile", traits: .sizeThatFitsLayout) {
    PreviewViewController {
        let model = ServiceProfileEditorModel(name: "", configuration: ServiceConfiguration())
        model.save = { _ in }
        return ServiceProfileEditorController(model: model)
    }.frame(width: 360, height: 160)
}
#endif
