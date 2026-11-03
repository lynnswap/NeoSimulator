#if DEBUG
import AppKit
import SwiftUI
@_spi(NeoSimulator) import XcodeSimulatorHost

struct BackgroundServicesPreview: NSViewControllerRepresentable {
    enum Scenario { case overrides, defaultProfile, defaultModified, stopped }
    let scenario: Scenario
    init(_ scenario: Scenario) { self.scenario = scenario }
    func makeNSViewController(context: Context) -> BackgroundServicesPreviewController {
        BackgroundServicesPreviewController(scenario)
    }
    func updateNSViewController(_ controller: BackgroundServicesPreviewController, context: Context) {}
}

@MainActor
final class BackgroundServicesPreviewController: NSViewController {
    typealias Scenario = BackgroundServicesPreview.Scenario

    let manager: SimulatorManagerModel
    let inspector: BackgroundServicesInspectorModel
    private let source: BackgroundServicesPreviewSource
    private let domain: String
    private let scenario: Scenario
    private var loading: Task<Void, Never>?

    init(_ scenario: Scenario) {
        self.scenario = scenario
        domain = "NeoSimulator.BackgroundServicesPreview.\(UUID().uuidString)"
        let store = ServiceProfileStore(defaults: UserDefaults(suiteName: domain)!)
        var configuration = Self.lightweightConfiguration
        if scenario == .overrides {
            configuration.set([.service("com.apple.searchd")], enabled: true)
        } else if scenario == .defaultProfile {
            configuration = ServiceConfiguration()
        }
        source = BackgroundServicesPreviewSource(configuration: configuration, stopped: scenario == .stopped)
        manager = SimulatorManagerModel(source: source, serviceProfiles: store)
        inspector = BackgroundServicesInspectorModel(manager: manager, showProfileSettings: { _ in })
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 320, height: 820)
        manager.onError = { [weak model = inspector] error in
            model?.actionIssue = error.localizedDescription
        }
        loading = Task { [weak self] in await self?.loadPreview() }
    }

    required init?(coder: NSCoder) { nil }

    private static var lightweightConfiguration: ServiceConfiguration {
        var configuration = ServiceConfiguration()
        configuration.set([.category("widgets"), .category("siri"), .category("search")], enabled: false)
        return configuration
    }

    override func loadView() {
        let split = NSSplitViewController()
        split.splitView.isVertical = true
        let controller = BackgroundServicesViewController(model: inspector)
        controller.isVisible = true
        let accessory = BackgroundServicesAccessoryViewController(model: inspector)
        accessory.isActive = true
        let item = NSSplitViewItem(inspectorWithViewController: controller)
        item.addTopAlignedAccessoryViewController(accessory)
        item.addTopAlignedAccessoryViewController(controller.searchAccessory)
        split.addSplitViewItem(item)
        addChild(split)
        view = split.view
        view.frame = NSRect(origin: .zero, size: preferredContentSize)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        manager.backgroundServices.setVisible(true)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        manager.backgroundServices.setVisible(false)
    }

    private func loadPreview() async {
        do {
            let store = manager.serviceProfiles
            let lightweight = try store.create(name: "Lightweight", configuration: Self.lightweightConfiguration)
            if scenario == .defaultModified {
                try store.record([.category("widgets"), .category("siri"), .category("search")], enabled: false,
                                 for: source.device.id, productFamily: "iPhone")
            } else if scenario != .defaultProfile {
                try store.assign(lightweight.id, to: source.device.id, pending: scenario == .stopped)
            }
            if scenario == .overrides {
                try store.record([.service("com.apple.searchd")], enabled: true,
                                 for: source.device.id, productFamily: "iPhone")
            }
            await manager.refresh()
            manager.backgroundServices.inspect(source.device, selectionCount: 1)
            manager.backgroundServices.setVisible(true)
            await manager.backgroundServices.finishReading()
        } catch {
            inspector.actionIssue = error.localizedDescription
        }
    }

    isolated deinit {
        loading?.cancel()
        UserDefaults.standard.removePersistentDomain(forName: domain)
    }
}

/// Supplies in-memory host responses so previews use the same read and write paths as the inspector.
private actor BackgroundServicesPreviewSource: SimulatorManagerSource {
    let device: InventoryDevice
    private var configuration: ServiceConfiguration

    init(configuration: ServiceConfiguration, stopped: Bool) {
        self.configuration = configuration
        device = .simulator(SimulatorHostDevice(identifier: "preview-iphone", name: "iPhone 18 Pro",
            descriptiveName: "iPhone 18 Pro", runtimeIdentifier: "preview-runtime", runtimeName: "iOS 27.2",
            productFamily: "iPhone", state: stopped ? "Shutdown" : "Booted"))
    }

    func inventory() -> DeviceInventorySnapshot { .init(devices: [device], issues: []) }
    func status() -> SimulatorHostStatus {
        .init(host: .neo, preferredHost: .neo, restorationAvailable: false, rendererRunning: false)
    }
    func backgroundServices(for device: InventoryDevice) -> SimulatorBackgroundServices {
        SimulatorBackgroundServices(disabled: configuration.disabledLabels,
            loaded: ServiceConfiguration.labels.subtracting(configuration.disabledLabels), productFamily: "iPhone")
    }
    func setBackgroundServices(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool,
                               for device: InventoryDevice) -> SimulatorBackgroundServicesUpdate {
        configuration.set(targets, enabled: enabled, productFamily: "iPhone")
        let state = backgroundServices(for: device)
        let categories = SimulatorBackgroundServiceCategory.all.filter { targets.contains(.category($0.id)) }
        let labels = Set(categories.flatMap { $0.services.map(\.label) }).union(targets.compactMap {
            if case .service(let label) = $0 { return label }
            return nil
        })
        return SimulatorBackgroundServicesUpdate(services: state,
            stillEnabledLabels: enabled ? [] : labels.filter { state.isEnabled($0) }.sorted(), notStartedLabels: [])
    }

    // The inspector does not expose these host operations.
    func beginSession() {}
    func endSession() {}
    func installedXcodes() -> [SimulatorXcode] { [] }
    func xcodeURL(forDevice deviceID: DeviceInventoryID) throws -> URL { throw CocoaError(.featureUnsupported) }
    func selectHost(_ host: SimulatorHost, xcodeURL: URL?) throws { throw CocoaError(.featureUnsupported) }
    nonisolated func makeScreenOpenRequest(for deviceID: DeviceInventoryID) -> SimulatorScreenOpenRequest {
        SimulatorScreenOpenRequest(deviceID: deviceID, onCancel: {})
    }
    func openDevice(_ request: SimulatorScreenOpenRequest, xcodeURL: URL?, bootIfNeeded: Bool) throws { throw CocoaError(.featureUnsupported) }
    func closeDevice(_ deviceID: DeviceInventoryID, keepingDeviceRunning: Bool) throws { throw CocoaError(.featureUnsupported) }
    func creationCatalog() throws -> SimulatorCreationContext { throw CocoaError(.featureUnsupported) }
    func creationCatalog(for deviceID: DeviceInventoryID) throws -> SimulatorCreationContext { throw CocoaError(.featureUnsupported) }
    func createSimulator(named name: String, deviceType: String, runtime: String, context: SimulatorCreationContext) throws -> String {
        throw CocoaError(.featureUnsupported)
    }
    func pairSimulators(watch: String, phone: String, context: SimulatorCreationContext) throws { throw CocoaError(.featureUnsupported) }
    func manage(_ action: DeviceManagementAction, devices: [InventoryDevice],
                preparingDisplay: (@isolated(any) @Sendable (InventoryDevice) async throws -> Void)?) -> DeviceManagementReport {
        DeviceManagementReport(results: [])
    }
    func inspector(for device: InventoryDevice) throws -> DeviceInspector { throw CocoaError(.featureUnsupported) }
    func restore(force: Bool) throws { throw CocoaError(.featureUnsupported) }
    func synchronizeXcodeConnections() -> Bool { false }
    func testingDeviceVisibilityDidChange() {}
    func quitRenderer(keepingDevicesRunning: Bool?) {}
    func deviceSettings(for device: InventoryDevice) throws -> SimulatorDeviceSettings { throw CocoaError(.featureUnsupported) }
    func setDeviceSetting(_ setting: SimulatorDeviceSetting, for device: InventoryDevice) throws { throw CocoaError(.featureUnsupported) }
    func setDeviceSetting(_ setting: SimulatorDeviceSetting, for device: InventoryDevice,
                          updating settings: SimulatorDeviceSettings) throws -> SimulatorDeviceSettings {
        throw CocoaError(.featureUnsupported)
    }
}
#endif
