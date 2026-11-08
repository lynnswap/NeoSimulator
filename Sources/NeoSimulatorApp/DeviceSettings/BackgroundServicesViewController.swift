import NeoSimulatorKit
import NeoSimulatorHostSupport
import AppKit
import ObservationBridge
import SwiftUI

@MainActor
final class BackgroundServicesViewController: NSViewController {
    let model: BackgroundServicesInspectorModel
    private lazy var outline = BackgroundServiceOutlineController(categories: model.categories, showsDetails: false)
    private lazy var content = NSHostingController(rootView: BackgroundServicesView(model: model, outline: outline))
    var searchAccessory: BackgroundServiceSearchAccessoryViewController { outline.searchAccessory }
    var isVisible = false { didSet { updateVisibility() } }

    private func updateVisibility() {
        if case .simulator = model.content {
            searchAccessory.isHidden = !isVisible
        } else {
            searchAccessory.isHidden = true
        }
    }
    private var observation: PortableObservationTracking.Token?
    private var editor: ServiceProfileEditorController?

    init(model: BackgroundServicesInspectorModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func loadView() {
        content.sizingOptions = []
        addChild(content)
        view = content.view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observation = withPortableContinuousObservation { [weak self] _ in self?.update() }
    }

    private func update() {
        updateVisibility()
        let hasServices = model.content == .simulator(.services)
        outline.view.isHidden = !hasServices
        outline.isEnabled = !model.holdsChanges
        searchAccessory.searchField.isEnabled = hasServices
        showEditor(model.profileEditor)
    }

    private func showEditor(_ model: ServiceProfileEditorModel?) {
        guard editor?.model !== model else { return }
        if let editor { dismiss(editor); self.editor = nil }
        guard let model else { return }
        let editor = ServiceProfileEditorController(model: model)
        editor.onClose = { [weak self] in self?.model.profileEditor = nil }
        self.editor = editor
        presentAsSheet(editor)
    }
}

private struct BackgroundServicesView: View {
    let model: BackgroundServicesInspectorModel
    let outline: BackgroundServiceOutlineController
    @State private var profileHeight: CGFloat = 0

    var body: some View {
        ZStack {
            BackgroundServicesOutline(controller: outline, profileHeight: showsProfile ? profileHeight : 0)
                .ignoresSafeArea(.container)
            BackgroundServicesUnavailable(content: model.content, retry: model.requestRefresh)
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            if showsProfile {
                BackgroundServicesProfileForm(model: model)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { profileHeight = $0 }
            }
        }
    }

    private var showsProfile: Bool {
        if case .simulator = model.content { true } else { false }
    }
}

private struct BackgroundServicesOutline: NSViewControllerRepresentable {
    let controller: BackgroundServiceOutlineController
    let profileHeight: CGFloat

    func makeNSViewController(context: Context) -> BackgroundServiceOutlineController { controller }
    func updateNSViewController(_ controller: BackgroundServiceOutlineController, context: Context) {
        // The AppKit scroll view needs the bar inset that SwiftUI applies to its own scroll views.
        controller.view.additionalSafeAreaInsets.top = profileHeight
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
