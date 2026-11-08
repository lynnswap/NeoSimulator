import AppKit

@MainActor
final class InspectorCategoryAccessoryViewController: NSSplitViewItemAccessoryViewController {
    let picker = NSSegmentedControl(
        labels: ["Info", "Apps", "Profiles"], trackingMode: .selectOne, target: nil, action: nil)

    init() {
        super.init(nibName: nil, bundle: nil)
        preferredScrollEdgeEffectStyle = .hard
        picker.segmentDistribution = .fill
        picker.setAccessibilityLabel("Inspector Subcategory")
        let controls = NSStackView(views: [picker])
        controls.orientation = .horizontal
        controls.distribution = .fill
        controls.frame.size = controls.fittingSize
        view = controls
    }

    required init?(coder: NSCoder) { nil }
}

#if DEBUG
    #Preview("Info Categories", traits: .sizeThatFitsLayout) {
        let accessory = InspectorCategoryAccessoryViewController()
        accessory.picker.selectedSegment = 0
        return accessory
    }
#endif
