import AppKit
import SwiftUI

@MainActor
final class SettingsViewController: NSTabViewController {
    let general: GeneralSettingsViewController
    let devices: DevicesSettingsViewController
    let capture: CaptureSettingsViewController
    var onContentSizeChange: ((NSSize) -> Void)?

    init(model: SimulatorManagerModel, restart: @escaping () -> Void,
         makeSimulator: @escaping () async throws -> NewSimulatorModel,
         preferences: SimulatorPreferences, reportFailure: @escaping (Error) -> Void) {
        general = GeneralSettingsViewController(model: model, preferences: preferences,
                                               frameworks: model.frameworks, restart: restart)
        devices = DevicesSettingsViewController(makeSimulator: makeSimulator, reportFailure: reportFailure)
        capture = CaptureSettingsViewController(preferences: preferences)
        super.init(nibName: nil, bundle: nil)
        general.sizingOptions = [.preferredContentSize]
        devices.sizingOptions = [.preferredContentSize]
        capture.sizingOptions = [.preferredContentSize]
        transitionOptions = []
        tabStyle = .toolbar
        canPropagateSelectedChildViewControllerTitle = true
        for (controller, symbol) in [(general as NSViewController, "gear"), (devices, "iphone"), (capture, "camera")] {
            let item = NSTabViewItem(viewController: controller)
            item.identifier = controller.title
            item.label = controller.title ?? ""
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: controller.title)
            addTabViewItem(item)
        }
    }

    required init?(coder: NSCoder) { nil }

    var selectedContentSize: NSSize {
        tabView.selectedTabViewItem?.viewController?.preferredContentSize ?? .zero
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard tabView.selectedTabViewItem?.viewController === viewController else { return }
        onContentSizeChange?(viewController.preferredContentSize)
    }

    var simulatorLoading: Task<Void, Never>? { devices.loading }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        onContentSizeChange?(selectedContentSize)
        if tabViewItem?.viewController === devices { devices.reload() }
    }

    func reloadSimulatorIfVisible() {
        if selectedTabViewItemIndex == 1 { devices.reload() }
    }
}

#if DEBUG
@MainActor
enum SettingsPreview {
    static func preferences() -> SimulatorPreferences {
        let defaults = UserDefaults(suiteName: "dev.lynnswap.NeoSimulator.SettingsPreview")!
        return SimulatorPreferences(defaults: defaults, creationDefaults: defaults)
    }
    static func manager() -> SimulatorManagerModel {
        SimulatorManagerModel(rendererApplicationURL: Bundle.main.bundleURL)
    }
    static func frameworks() -> UIFrameworkSettings {
        UIFrameworkSettings(defaults: UserDefaults(suiteName: "dev.lynnswap.NeoSimulator.SettingsPreview")!, discover: { [] })
    }
    static func simulator() -> NewSimulatorModel {
        let catalog = SimulatorCatalog(
            deviceTypes: [.init(identifier: "iphone", name: "iPhone 17", productFamily: 1),
                          .init(identifier: "ipad", name: "iPad Pro 11-inch (M5)", productFamily: 2),
                          .init(identifier: "tv", name: "Apple TV 4K (3rd generation)", productFamily: 3),
                          .init(identifier: "watch", name: "Apple Watch Series 11", productFamily: 4),
                          .init(identifier: "vision", name: "Apple Vision Pro", productFamily: 7)],
            runtimes: [.init(identifier: "ios", name: "iOS 27.2"), .init(identifier: "tvos", name: "tvOS 27.2"),
                       .init(identifier: "watchos", name: "watchOS 27.2"), .init(identifier: "visionos", name: "visionOS 27.2")],
            supportedDeviceTypes: ["ios": ["iphone", "ipad"], "tvos": ["tv"], "watchos": ["watch"], "visionos": ["vision"]],
            canPair: { _, _, _, _ in true })
        return NewSimulatorModel(catalog: catalog, create: { _, _, _ in "preview" }, pair: { _, _ in }, preferences: preferences())
    }
}
#endif
