import AppKit
import ObservationBridge

@MainActor
final class BackgroundServiceSearchField: NSSearchField {
    private let model: BackgroundServiceListModel
    private var observation: PortableObservationTracking.Token?

    init(model: BackgroundServiceListModel) {
        self.model = model
        super.init(frame: .zero)
        placeholderString = "Search Services"
        setAccessibilityLabel("Search Services")
        sendsSearchStringImmediately = false
        sendsWholeSearchString = false
        target = self
        action = #selector(search)
        observation = withPortableContinuousObservation { [weak self, model] _ in
            guard let self, stringValue != model.query else { return }
            stringValue = model.query
        }
    }

    required init?(coder: NSCoder) { nil }

    @objc private func search() { model.query = stringValue }
}

@MainActor
final class BackgroundServiceSearchAccessoryViewController: NSSplitViewItemAccessoryViewController {
    let searchField: BackgroundServiceSearchField

    init(model: BackgroundServiceListModel) {
        searchField = BackgroundServiceSearchField(model: model)
        super.init(nibName: nil, bundle: nil)
        automaticallyAppliesContentInsets = false
        preferredScrollEdgeEffectStyle = .hard
        let controls = NSStackView(views: [searchField])
        controls.orientation = .horizontal
        controls.distribution = .fill
        controls.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 8, right: 16)
        controls.frame.size = controls.fittingSize
        view = controls
    }

    required init?(coder: NSCoder) { nil }
}
