import AppKit

@MainActor
final class InspectorCategoryAccessoryViewController: NSSplitViewItemAccessoryViewController {
    let picker = NSSegmentedControl(labels: ["Info", "Apps", "Profiles"], trackingMode: .selectOne, target: nil, action: nil)

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
import SwiftUI
import XcodeSimulatorHost

#Preview("Info Categories") {
    InspectorCategoryPreview().frame(width: 320, height: 450)
}

private struct InspectorCategoryPreview: NSViewControllerRepresentable {
    func makeNSViewController(context: Context) -> NSSplitViewController {
        let inspection = DeviceInspectorModel()
        inspection.device = .simulator(SimulatorHostDevice(
            identifier: "A1840638-6397-40C7-8BB8-B8223DE937CC", name: "iPad Pro 11-inch (M5)",
            descriptiveName: "iPad Pro 11-inch (M5)", runtimeIdentifier: "preview",
            runtimeName: "iPadOS 27.2", productFamily: "iPad", state: "Booted"))
        let info = NSHostingController(rootView: DeviceInformationView(
            manager: SettingsPreview.manager(), inspection: inspection,
            visibility: DeviceInfoVisibility(defaults: UserDefaults(suiteName: "dev.lynnswap.NeoSimulator.InspectorPreview")!),
            pairingMenu: { _ in NSMenu() }, deviceMenu: { _ in NSMenu() }, unpair: { _ in }))
        info.sizingOptions = []
        let accessory = InspectorCategoryAccessoryViewController()
        accessory.picker.selectedSegment = 0
        let item = NSSplitViewItem(inspectorWithViewController: info)
        item.addTopAlignedAccessoryViewController(accessory)
        let split = NSSplitViewController()
        split.splitView.isVertical = true
        split.addSplitViewItem(item)
        return split
    }

    func updateNSViewController(_ controller: NSSplitViewController, context: Context) {}
}
#endif
