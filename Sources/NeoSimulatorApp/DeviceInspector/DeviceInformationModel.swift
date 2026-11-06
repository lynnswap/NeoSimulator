import NeoSimulatorKit
import NeoSimulatorHostSupport
import AppKit
import Observation
import ObservationBridge

@MainActor @Observable
final class DeviceInformationModel {
    struct FieldGroup: Identifiable, Equatable {
        let id: DeviceInformation.Group
        let fields: [DeviceInformation.Field]
    }

    let visibility: DeviceInfoVisibility
    var editsVisibility = false
    var selectedPairedSimulator: DeviceInventoryID?
    var information: DeviceInformation? { inspection.information }
    var visibleGroups: [FieldGroup] {
        let fields = information?.fields.filter { visibility.isVisible($0) } ?? []
        return DeviceInformation.Group.allCases.compactMap { group in
            let members = fields.filter { $0.group == group }
            return members.isEmpty ? nil : FieldGroup(id: group, fields: members)
        }
    }
    @ObservationIgnored private var inspectedDeviceID: DeviceInventoryID?
    @ObservationIgnored private let manager: SimulatorManagerModel
    @ObservationIgnored private let inspection: DeviceInspectorModel
    @ObservationIgnored private let makePairingMenu: (SimulatorHostDevice) -> NSMenu
    @ObservationIgnored let deviceMenu: (SimulatorHostDevice) -> NSMenu
    @ObservationIgnored private let unpair: (SimulatorHostDevice) -> Void
    @ObservationIgnored private var observation: PortableObservationTracking.Token?

    init(manager: SimulatorManagerModel, inspection: DeviceInspectorModel, visibility: DeviceInfoVisibility,
         pairingMenu: @escaping (SimulatorHostDevice) -> NSMenu,
         deviceMenu: @escaping (SimulatorHostDevice) -> NSMenu, unpair: @escaping (SimulatorHostDevice) -> Void) {
        self.manager = manager
        self.inspection = inspection
        self.visibility = visibility
        makePairingMenu = pairingMenu
        self.deviceMenu = deviceMenu
        self.unpair = unpair
        observation = withPortableContinuousObservation { [weak self, inspection] _ in
            let identifier = inspection.device?.id
            guard let self, inspectedDeviceID != identifier else { return }
            inspectedDeviceID = identifier
            selectedPairedSimulator = nil
            editsVisibility = false
        }
    }

    var pairingDevice: SimulatorHostDevice? {
        guard case .simulator(let device) = inspection.device,
              device.productFamily == "iPhone" || device.productFamily == "Apple Watch" else { return nil }
        return device
    }
    var pairedSimulators: [SimulatorHostDevice] {
        pairingDevice.map { DeviceInformation.pairedSimulators(for: $0, in: manager.inventory) } ?? []
    }
    var emptyPairingLabel: String {
        pairingDevice?.productFamily == "Apple Watch" ? "No Paired iPhone Simulators" : "No Paired Watch Simulators"
    }
    private var watchToUnpair: SimulatorHostDevice? {
        guard let device = pairingDevice,
              let partner = pairedSimulators.first(where: { $0.inventoryID == selectedPairedSimulator }) else { return nil }
        return DeviceInformation.watchToUnpair(device: device, partner: partner)
    }
    var canAddPairing: Bool {
        guard let device = pairingDevice else { return false }
        return manager.canAddPairing(for: device) && !inspection.isManaging
            && manager.canManage(.pair, deviceIDs: [device.inventoryID])
    }
    var canRemovePairing: Bool {
        guard let watch = watchToUnpair else { return false }
        return !inspection.isManaging && manager.canManage(.unpair, deviceIDs: [watch.inventoryID])
    }
    func pairingMenu() -> NSMenu { pairingDevice.map(makePairingMenu) ?? NSMenu() }
    func removePairing() { if let watch = watchToUnpair { unpair(watch) } }
}
