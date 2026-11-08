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
    private var change: ((Bool) -> Void)?
    private var editable = true
    private weak var representedItem: AnyObject?
    private var showsDetails = false
    package var controlsEnabled = true { didSet { toggle.isEnabled = controlsEnabled && editable } }

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
            title.stringValue = category.category.name
            title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            detail.stringValue = showsDetails ? "When off: " + category.category.consequence : ""
            toolTip = category.category.consequence
            toggle.setAccessibilityLabel(category.category.name)
            toggle.setAccessibilityHelp(category.category.consequence)
            change = { [weak category] in category?.setEnabled($0) }
            observation = withPortableContinuousObservation { [weak self, category] _ in
                self?.toggle.state = category.isEnabled ? .on : .off
            }
            editable = true
        } else if let service = item as? BackgroundServiceItem {
            title.stringValue = service.label
            title.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            detail.stringValue = showsDetails ? service.detail : ""
            toggle.setAccessibilityLabel(service.label)
            change = { [weak service] in service?.setEnabled($0) }
            observation = withPortableContinuousObservation { [weak self, service] _ in
                guard let self else { return }
                toggle.state = service.isEnabled ? .on : .off
                toolTip = service.help
                toggle.setAccessibilityHelp(service.help)
                editable = service.canChange
                toggle.isEnabled = controlsEnabled && editable
            }
        }
        detail.isHidden = !showsDetails
        toggle.isEnabled = controlsEnabled && editable
    }

    @objc private func toggleChanged() { change?(toggle.state == .on) }
}
