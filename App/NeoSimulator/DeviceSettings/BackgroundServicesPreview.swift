#if DEBUG
import SwiftUI
@_spi(NeoSimulator) import XcodeSimulatorHost

@MainActor
struct BackgroundServicesPreview: View {
    enum Scenario {
        case overrides, profileUpdate, unapplied, defaultProfile, defaultModified, stopped
    }

    @State private var manager: SimulatorManagerModel
    @State private var selection = ServiceProfilesSelection()
    @State private var showsProfiles = false
    @State private var issue: String?
    private let scenario: Scenario
    private let source: BackgroundServicesPreviewSource
    private let domain: String

    init(_ scenario: Scenario) {
        self.scenario = scenario
        let domain = "NeoSimulator.BackgroundServicesPreview.\(UUID().uuidString)"
        self.domain = domain
        let store = ServiceProfileStore(defaults: UserDefaults(suiteName: domain)!)
        var configuration = Self.lightweightConfiguration
        if scenario == .overrides || scenario == .profileUpdate {
            configuration.set([.service("com.apple.searchd")], enabled: true)
        } else if scenario == .unapplied || scenario == .defaultProfile {
            configuration = ServiceConfiguration()
        }
        let source = BackgroundServicesPreviewSource(configuration: configuration, stopped: scenario == .stopped)
        self.source = source
        _manager = State(initialValue: SimulatorManagerModel(source: source, serviceProfiles: store))
    }

    private static var lightweightConfiguration: ServiceConfiguration {
        var configuration = ServiceConfiguration()
        configuration.set([.category("widgets"), .category("siri"), .category("search")], enabled: false)
        return configuration
    }

    var body: some View {
        ManagerBackgroundServicesView(manager: manager, model: manager.backgroundServices)
            .frame(width: 320, height: 820)
            .task {
                manager.onError = { [message = $issue] in message.wrappedValue = $0.localizedDescription }
                manager.onManageServiceProfiles = { [selection, presented = $showsProfiles] id in
                    selection.profileID = id
                    presented.wrappedValue = true
                }
                do {
                    let store = manager.serviceProfiles
                    if store.profiles.isEmpty {
                        let lightweight = try store.create(name: "Lightweight", configuration: Self.lightweightConfiguration)
                        if scenario == .defaultModified {
                            try store.record([.category("widgets"), .category("siri"), .category("search")], enabled: false,
                                             for: source.device.id, productFamily: "iPhone")
                        } else if scenario != .defaultProfile {
                            try store.assign(lightweight.id, to: source.device.id, pending: scenario == .stopped)
                        }
                        if scenario == .overrides || scenario == .profileUpdate {
                            try store.record([.service("com.apple.searchd")], enabled: true,
                                             for: source.device.id, productFamily: "iPhone")
                        }
                        if scenario == .profileUpdate {
                            var updated = lightweight.configuration
                            updated.set([.category("telemetry")], enabled: false)
                            try store.update(lightweight.id, name: lightweight.name, configuration: updated)
                        }
                    }
                    await manager.refresh()
                    manager.backgroundServices.inspect(source.device, selectionCount: 1)
                    manager.backgroundServices.setVisible(true)
                    await manager.backgroundServices.finishReading()
                } catch {
                    issue = error.localizedDescription
                }
            }
            .onDisappear {
                manager.backgroundServices.setVisible(false)
                manager.onError = nil
                manager.onManageServiceProfiles = nil
                UserDefaults.standard.removePersistentDomain(forName: domain)
            }
            .sheet(isPresented: $showsProfiles) {
                ServiceProfilesSettingsView(store: manager.serviceProfiles, selection: selection)
            }
            .alert("Preview Error", isPresented: Binding(get: { issue != nil },
                                                        set: { if !$0 { issue = nil } })) {
                Button("OK") { issue = nil }
            } message: {
                Text(issue ?? "")
            }
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
