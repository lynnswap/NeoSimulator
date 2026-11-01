import AppKit

@MainActor
final class InspectorAccessoryViewController: NSSplitViewItemAccessoryViewController {
    private let tabs = NSSegmentedControl()
    var onSelect: ((Int) -> Void)?

    init() {
        super.init(nibName: nil, bundle: nil)
        preferredScrollEdgeEffectStyle = .soft
        tabs.segmentCount = 3
        tabs.trackingMode = .selectOne
        tabs.segmentStyle = .texturedRounded
        tabs.selectedSegmentBezelColor = .unemphasizedSelectedContentBackgroundColor
        tabs.setAccessibilityLabel("Device Inspector")
        for (index, item) in [
            ("Settings", "slider.horizontal.3"),
            ("Reports", "text.document"),
            ("Info", "info"),
        ].enumerated() {
            tabs.setImage(NSImage(systemSymbolName: item.1, accessibilityDescription: item.0), forSegment: index)
            tabs.setToolTip(item.0, forSegment: index)
        }
        tabs.target = self
        tabs.action = #selector(selectTab(_:))
        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.setViews([tabs], in: .center)
        controls.frame.size = controls.fittingSize
        view = controls
    }

    required init?(coder: NSCoder) { nil }

    func select(_ index: Int?) {
        for segment in 0..<tabs.segmentCount {
            tabs.setSelected(segment == index, forSegment: segment)
        }
    }

    @objc private func selectTab(_ sender: NSSegmentedControl) {
        onSelect?(sender.selectedSegment)
    }
}

#if DEBUG
#Preview("Inspector Tabs", traits: .sizeThatFitsLayout) {
    let controller = InspectorAccessoryViewController()
    controller.select(0)
    return controller
}
#endif
