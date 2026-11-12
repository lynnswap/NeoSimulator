#if DEBUG
    import Foundation
    import NeoSimulatorHostSupport
    import NeoSimulatorKit

    /// Supplies in-memory host responses so that previews read and write through the manager as the app does.
    package actor PreviewManagerSource: SimulatorManagerSource {
        /// The simulator whose background services and settings the source supplies.
        package nonisolated let device: InventoryDevice
        private let otherDevices: [InventoryDevice]
        private var configuration: ServiceConfiguration
        private var settings: SimulatorDeviceSettings?

        package init(
            configuration: ServiceConfiguration = ServiceConfiguration(),
            stopped: Bool = false,
            settings: SimulatorDeviceSettings? = nil,
            otherDevices: [InventoryDevice] = []
        ) {
            self.settings = settings
            self.configuration = configuration
            self.otherDevices = otherDevices
            device = .simulator(
                SimulatorHostDevice(
                    identifier: "preview-iphone", name: "iPhone 18 Pro",
                    descriptiveName: "iPhone 18 Pro", runtimeIdentifier: "preview-runtime", runtimeName: "iOS 27.2",
                    productFamily: "iPhone", state: stopped ? "Shutdown" : "Booted"))
        }

        package func inventory() -> DeviceInventorySnapshot { .init(devices: [device] + otherDevices, issues: []) }
        package nonisolated func stopReads() {}
        package nonisolated func resumeReads() {}
        package func status() -> SimulatorHostStatus {
            .init(host: .neo, restorationAvailable: false, rendererRunning: false)
        }
        package func backgroundServices(
            for device: InventoryDevice, catalog: BackgroundServiceCatalog
        ) -> SimulatorBackgroundServices {
            SimulatorBackgroundServices(
                disabled: configuration.disabledLabels,
                loaded: catalog.slimmable.subtracting(configuration.disabledLabels), productFamily: "iPhone",
                catalog: catalog)
        }
        package func setBackgroundServices(
            _ targets: [SimulatorBackgroundServiceTarget], enabled: Bool, catalog: BackgroundServiceCatalog,
            for device: InventoryDevice
        ) -> SimulatorBackgroundServicesUpdate {
            configuration.set(targets, enabled: enabled, productFamily: "iPhone", catalog: catalog)
            let state = backgroundServices(for: device, catalog: catalog)
            let categories = catalog.categories.filter { targets.contains(.category($0.id)) }
            let labels = Set(categories.flatMap { $0.services.map(\.label) }).union(
                targets.compactMap {
                    if case .service(let label) = $0 { return label }
                    return nil
                })
            return SimulatorBackgroundServicesUpdate(
                services: state,
                stillEnabledLabels: enabled ? [] : labels.filter { state.isEnabled($0) }.sorted(), notStartedLabels: [])
        }

        // The inspector does not expose these host operations.
        package func beginSession() {}
        package func endSession() {}
        package func installedXcodes() -> [SimulatorXcode] { [] }
        package func xcodeURL(forDevice deviceID: DeviceInventoryID) throws -> URL {
            throw CocoaError(.featureUnsupported)
        }
        package func deviceHubDidExit(xcodeURL: URL) {}
        package func selectHost(_ host: SimulatorHost, xcodeURL: URL?) {}
        package func openDeviceHub(xcodeURL: URL, requestURL: URL?) throws {
            throw CocoaError(.featureUnsupported)
        }
        package nonisolated func makeScreenOpenRequest(for deviceID: DeviceInventoryID) -> SimulatorScreenOpenRequest {
            SimulatorScreenOpenRequest(deviceID: deviceID, onCancel: {})
        }
        package func openDevice(_ request: SimulatorScreenOpenRequest, xcodeURL: URL?, bootIfNeeded: Bool) throws {
            throw CocoaError(.featureUnsupported)
        }
        package func closeDevice(_ deviceID: DeviceInventoryID, keepingDeviceRunning: Bool) throws {
            throw CocoaError(.featureUnsupported)
        }
        package func creationCatalog() throws -> SimulatorCreationContext { throw CocoaError(.featureUnsupported) }
        package func creationCatalog(for deviceID: DeviceInventoryID) throws -> SimulatorCreationContext {
            throw CocoaError(.featureUnsupported)
        }
        package func createSimulator(
            named name: String, deviceType: String, runtime: String, context: SimulatorCreationContext
        ) throws -> String {
            throw CocoaError(.featureUnsupported)
        }
        package func pairSimulators(watch: String, phone: String, context: SimulatorCreationContext) throws {
            throw CocoaError(.featureUnsupported)
        }
        package func manage(
            _ action: DeviceManagementAction, devices: [InventoryDevice],
            preparingDisplay: (@isolated(any) @Sendable (InventoryDevice) async throws -> Void)?
        ) -> DeviceManagementReport {
            DeviceManagementReport(results: [])
        }
        package func inspector(for device: InventoryDevice) throws -> DeviceInspector {
            throw CocoaError(.featureUnsupported)
        }
        package func restore() throws { throw CocoaError(.featureUnsupported) }
        package func synchronizeXcodeConnections() -> Bool { false }
        package func quitRenderer(keepingDevicesRunning: Bool?) {}
        package func readSettings(
            _ groups: Set<DeviceSettingsGroup>, of device: InventoryDevice,
            publish: @escaping @Sendable (DeviceSettingsGroupRead) async -> Void
        ) async {
            for group in groups {
                if let settings {
                    await publish(.values(group) { $0.replace(group, with: settings) })
                } else {
                    await publish(.unsupported(group))
                }
            }
        }
        package func write(_ change: DeviceSettingChange, to device: InventoryDevice) throws {
            guard let settings else { throw CocoaError(.featureUnsupported) }
            self.settings = settings.applying(change)
        }
    }

    extension ServiceProfileStore {
        /// An empty store in a temporary file, which each preview run starts over.
        package static func preview(named name: String) -> ServiceProfileStore {
            let directory = URL.temporaryDirectory.appending(path: name, directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: directory)
            return ServiceProfileStore(fileURL: directory.appending(path: "ServiceProfiles.json"), legacyDefaults: nil)
        }
    }
#endif
