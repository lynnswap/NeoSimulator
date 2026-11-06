import NeoSimulatorKit
import Observation

/// Retains read interest for the selected device. Device state stays in its shared model.
@MainActor @Observable
final class ManagerSelection {
    private(set) var device: DeviceModel?
    private(set) var count = 0
    private(set) var showsServices = false
    @ObservationIgnored private var settingsInterest: DeviceReadInterest?
    @ObservationIgnored private var servicesInterest: DeviceReadInterest?
    @ObservationIgnored private var inspectionGroups: DeviceStateGroups = []
    @ObservationIgnored private var inspectionInterest: DeviceReadInterest?

    func select(_ device: DeviceModel?, count: Int) {
        if self.count != count { self.count = count }
        guard self.device !== device else { return }
        settingsInterest?.release()
        servicesInterest?.release()
        inspectionInterest?.release()
        self.device = device
        settingsInterest = device?.keepCurrent(.settings)
        servicesInterest = showsServices ? device?.keepCurrent(.backgroundServices) : nil
        inspectionInterest = device?.keepCurrent(inspectionGroups)
    }

    /// launchd is read only while the Background Services page shows.
    func setServicesVisible(_ visible: Bool) {
        guard showsServices != visible else { return }
        showsServices = visible
        servicesInterest?.release()
        servicesInterest = visible ? device?.keepCurrent(.backgroundServices) : nil
    }

    /// What the device inspector shows is read only while it does.
    func setInspection(_ groups: DeviceStateGroups) {
        guard inspectionGroups != groups else { return }
        inspectionGroups = groups
        inspectionInterest?.release()
        inspectionInterest = device?.keepCurrent(groups)
    }
}
