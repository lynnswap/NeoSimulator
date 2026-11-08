import AppKit
import NeoSimulatorKit
import NeoSimulatorManager
import ObservationBridge

/// Shows a service category or a service with a switch that turns it on or off.
@MainActor
package final class BackgroundServiceCell: NSTableCellView {
    private let title = LiteralTextField(labelWithString: "")
    private let detail = LiteralTextField(wrappingLabelWithString: "")
    private let toggle = NSSwitch()
    private var observation: PortableObservationTracking.Token?
    private var change: ((Bool) throws -> Void)?
    private weak var representedItem: AnyObject?
    private var showsDetails = false
    /// The switch position that the represented model has.
    private var isOn = false { didSet { showState() } }
    package var controlsEnabled = true { didSet { toggle.isEnabled = controlsEnabled } }

    package override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.lineBreakMode = .byTruncatingMiddle
        title.isSelectable = true
        detail.isSelectable = true
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        let labels = NSStackView(views: [title, detail])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.controlSize = .small
        toggle.target = self
        toggle.action = #selector(toggleChanged)
        addSubview(labels)
        addSubview(toggle)
        NSLayoutConstraint.activate([
            labels.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -8),
            toggle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toggle.setContentHuggingPriority(.required, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    package convenience init() { self.init(frame: .zero) }
    package required init?(coder: NSCoder) { nil }

    package func configure(item: Any, showsDetails: Bool) {
        let object = item as AnyObject
        guard representedItem !== object || self.showsDetails != showsDetails else { return }
        representedItem = object
        self.showsDetails = showsDetails
        observation?.cancel()
        if let category = item as? BackgroundServiceCategoryModel {
            title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            change = { [weak category] in category?.setEnabled($0) }
            observation = withPortableContinuousObservation { [weak self, category] _ in
                guard let self else { return }
                isOn = category.isEnabled
                // A custom category's name changes in place.
                title.stringValue = category.category.name
                showDetail(self.showsDetails ? "When off: " + category.category.consequence : "")
                toolTip = category.category.consequence
                toggle.setAccessibilityLabel(category.category.name)
                toggle.setAccessibilityHelp(category.category.consequence)
            }
        } else if let service = item as? BackgroundServiceItem {
            title.stringValue = service.label
            title.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            toggle.setAccessibilityLabel(service.label)
            change = { [weak service] in try service?.setEnabled($0) }
            observation = withPortableContinuousObservation { [weak self, service] _ in
                guard let self else { return }
                isOn = service.isEnabled
                showDetail(self.showsDetails ? service.summary : "")
                toolTip = service.help
                toggle.setAccessibilityHelp(service.help)
            }
        }
    }

    /// A service that the app added has no description, and its title centers without one.
    private func showDetail(_ text: String) {
        detail.stringValue = text
        detail.isHidden = text.isEmpty
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        showState()
    }

    // NSSwitch animates to a state set outside a window once it shows, as it does in a cell that a table reuses.
    private func showState() {
        guard window != nil else { return }
        toggle.state = isOn ? .on : .off
    }

    @objc private func toggleChanged() {
        do {
            try change?(toggle.state == .on)
        } catch {
            // The model kept its state, so the switch goes back to it.
            showState()
            if let window { presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil) }
        }
    }
}
