import NeoSimulatorKit
import Observation

/// Which device the manager shows, and so what stays current. What is known of a device belongs to its model, so changing
/// the selection reads only what is out of date, and returning to a device finds it as it was left.
@MainActor @Observable
final class ManagerSelection {
    private(set) var device: DeviceModel?
    private(set) var count = 0
    private(set) var showsServices = false
    @ObservationIgnored private var settingsInterest: DeviceReadInterest?
    @ObservationIgnored private var servicesInterest: DeviceReadInterest?

    func select(_ device: DeviceModel?, count: Int) {
        if self.count != count { self.count = count }
        guard self.device !== device else { return }
        settingsInterest?.release()
        servicesInterest?.release()
        self.device = device
        settingsInterest = device?.keepCurrent(.settings)
        servicesInterest = showsServices ? device?.keepCurrent(.backgroundServices) : nil
    }

    /// launchd is read only while the Background Services page shows.
    func setServicesVisible(_ visible: Bool) {
        guard showsServices != visible else { return }
        showsServices = visible
        servicesInterest?.release()
        servicesInterest = visible ? device?.keepCurrent(.backgroundServices) : nil
    }
}
