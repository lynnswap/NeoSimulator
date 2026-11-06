import Foundation
import NeoSimulatorKit
import Observation

/// What the inspector shows of the selected device. What is known of the device belongs to its model.
@MainActor @Observable
final class DeviceInspectorModel {
    enum Page { case reports, info }
    enum Content: Int, CaseIterable {
        case info, applications, configuration, provisioning
        var title: String {
            switch self {
            case .info: "Info"
            case .applications: "Applications"
            case .configuration: "Configuration Profiles"
            case .provisioning: "Provisioning Profiles"
            }
        }
        var profileKind: DeviceProfileKind { self == .provisioning ? .provisioning : .configuration }
        var group: DeviceStateGroups {
            switch self {
            case .info: .info
            case .applications: .applications
            case .configuration, .provisioning: .profiles(of: profileKind)
            }
        }
    }
    var device: DeviceModel? {
        didSet { select(content) }
    }
    var page = Page.info
    private(set) var content = Content.info
    var isManaging = false
    var isVisible = false
    /// Why the last action started here failed. Why a read failed is the device's own status.
    var actionIssue: String?

    /// The part of the device's state that shows now.
    var shownGroup: DeviceStateGroups { page == .reports ? .reports : content.group }
    var information: DeviceInformation? {
        device.map { DeviceInformation(device: $0.inventory, properties: $0.inspection.info) }
    }
    var reading: Bool { device?.inspection.isReading(shownGroup) == true }
    var profiles: [DeviceProfile] {
        guard let state = device?.inspection else { return [] }
        return content == .provisioning ? state.provisioningProfiles : state.configurationProfiles
    }

    /// What the last read of the shown part leaves to say.
    var readMessage: String? {
        guard let state = device?.inspection else { return nil }
        switch state.status(of: shownGroup) {
        case .stale(let reason): return reason
        case .unread, .unsupported: return nil
        case .current:
            if page == .reports { return state.reports.isEmpty ? "No reports available." : nil }
            switch content {
            case .info: return nil
            case .applications: return state.applications.isEmpty ? "No applications installed." : nil
            case .configuration, .provisioning: return profiles.isEmpty ? "No profiles installed." : nil
            }
        }
    }
    var readFailed: Bool {
        if case .stale = device?.inspection.status(of: shownGroup) { true } else { false }
    }

    var simulatorIsRunning: Bool { device?.kind == .simulator && device?.canInspectSettings == true }
    func supports(_ feature: String) -> Bool { device?.inventory.supports(coreDeviceFeature: feature) == true }
    var canReadApplications: Bool { device?.inspection.canRead(.applications) == true }
    var canInstallApplications: Bool { device?.inventory.canInstallApplications == true }
    var canReadProfiles: Bool { device?.inspection.canRead(content == .provisioning ? .provisioningProfiles : .configurationProfiles) == true }
    var canReadReports: Bool { device?.inspection.canRead(.reports) == true }

    func select(_ content: Content) {
        let selected: Content = switch content {
        case .provisioning where !supports("provisioningprofiles") && supports("configurationprofiles"): .configuration
        case .configuration where !supports("configurationprofiles") && supports("provisioningprofiles"): .provisioning
        default: content
        }
        if self.content != selected { self.content = selected }
    }
}
