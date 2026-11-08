import NeoSimulatorKit
import NeoSimulatorHostSupport
import AppKit
import ObservationBridge
import NeoSimulatorManager

@MainActor
package final class BackgroundServiceSearchField: NSSearchField {
    package override class var cellClass: AnyClass? {
        get { LiteralSearchFieldCell.self }
        set {}
    }

    private let model: BackgroundServiceListModel
    private var observation: PortableObservationTracking.Token?

    package init(model: BackgroundServiceListModel) {
        self.model = model
        super.init(frame: .zero)
        placeholderString = "Filter"
        setAccessibilityLabel("Filter")
        sendsSearchStringImmediately = false
        sendsWholeSearchString = false
        target = self
        action = #selector(search)
        observation = withPortableContinuousObservation { [weak self, model] _ in
            guard let self, stringValue != model.query else { return }
            stringValue = model.query
        }
    }

    package required init?(coder: NSCoder) { nil }

    @objc private func search() { model.query = stringValue }
}

@MainActor
package final class BackgroundServiceSearchAccessoryViewController: NSSplitViewItemAccessoryViewController {
    package let searchField: BackgroundServiceSearchField

    package init(model: BackgroundServiceListModel) {
        searchField = BackgroundServiceSearchField(model: model)
        super.init(nibName: nil, bundle: nil)
        automaticallyAppliesContentInsets = false
        preferredScrollEdgeEffectStyle = .hard
        let controls = NSStackView(views: [searchField])
        controls.orientation = .horizontal
        controls.distribution = .fill
        controls.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        controls.frame.size = controls.fittingSize
        view = controls
    }

    package required init?(coder: NSCoder) { nil }
}
