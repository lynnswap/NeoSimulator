import Foundation
import Observation
import XcodeSimulatorHost

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
    }
    var device: InventoryDevice? {
        didSet { select(content) }
    }
    var inspector: DeviceInspector?
    var page = Page.info
    private(set) var content = Content.info
    var isManaging = false
    var isVisible = false
    private(set) var generation = 0
    private(set) var applications: [DeviceApplication] = []
    var profiles: [DeviceProfile] = []
    private(set) var reports: [DeviceReport] = []
    private(set) var infoProperties: [String: DeviceInspectorValue] = [:]
    var lastIssue: String?
    private(set) var reading = false
    @ObservationIgnored private var readTask: Task<Void, Never>?

    func reset() {
        stopReading()
        inspector = nil
        applications = []
        profiles = []
        reports = []
        infoProperties = [:]
        lastIssue = nil
    }

    func stopReading() {
        generation += 1
        readTask?.cancel()
        readTask = nil
        reading = false
    }

    var simulatorIsRunning: Bool {
        guard case .simulator(let simulator) = device else { return false }
        return simulator.isAvailable && simulator.state == "Booted"
    }
    func supports(_ feature: String) -> Bool { device?.capabilities.contains("com.apple.coredevice.feature." + feature) == true }
    var canReadApplications: Bool { simulatorIsRunning || supports("streamapplist") }
    var canInstallApplications: Bool { simulatorIsRunning || supports("installapp") }
    var canReadProfiles: Bool {
        if case .simulator(let simulator) = device, simulator.deviceSetPath != nil { return false }
        return supports(content == .provisioning ? "provisioningprofiles" : "configurationprofiles")
    }

    func select(_ content: Content) {
        switch content {
        case .provisioning where !supports("provisioningprofiles") && supports("configurationprofiles"):
            self.content = .configuration
        case .configuration where !supports("configurationprofiles") && supports("provisioningprofiles"):
            self.content = .provisioning
        default:
            self.content = content
        }
    }

    func reload(using source: @escaping @MainActor (InventoryDevice) async throws -> DeviceInspector) {
        stopReading()
        guard isVisible, let device else { return }
        let request = generation
        let page = self.page
        let content = self.content
        reading = true
        lastIssue = nil
        readTask = Task { [weak self] in
            guard let self else { return }
            do {
                let inspector = try await source(device)
                guard generation == request, !Task.isCancelled else { return }
                self.inspector = inspector
                if page == .info && content == .info {
                    let snapshot = await inspector.info()
                    guard generation == request, !Task.isCancelled else { return }
                    infoProperties = snapshot.fields
                    lastIssue = snapshot.issues.map(\.localizedDescription).joined(separator: "\n")
                } else if page == .info && content == .applications {
                    guard canReadApplications else {
                        throw DeviceInspectorError.unsupported(device.kind == .simulator ? "Start this simulator to inspect its applications." : "This device does not currently support application inspection. Connect and unlock it, then refresh.")
                    }
                    let apps = try await inspector.applications()
                    guard generation == request, !Task.isCancelled else { return }
                    applications = apps
                    lastIssue = apps.isEmpty ? "No applications installed." : nil
                } else if page == .reports {
                    guard inspector.supportsReportListing || device.kind == .simulator else {
                        throw DeviceInspectorError.unsupported("This device does not currently support reports. Connect and unlock it, then refresh.")
                    }
                    let snapshot = try await inspector.reports()
                    guard generation == request, !Task.isCancelled else { return }
                    reports = snapshot.reports.sorted {
                        if $0.modificationDate != $1.modificationDate { return ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
                        return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
                    }
                    lastIssue = snapshot.issues.isEmpty ? (reports.isEmpty ? "No reports available." : nil)
                        : "\(snapshot.issues.count) reports returned incomplete metadata. Available reports are shown."
                } else {
                    guard canReadProfiles else {
                        let message: String
                        if case .simulator(let simulator) = device, simulator.deviceSetPath != nil {
                            message = "Profiles are unavailable for simulators in custom device sets."
                        } else { message = "This device does not currently support \(content.title.lowercased())." }
                        throw DeviceInspectorError.unsupported(message)
                    }
                    let snapshot = try await inspector.profiles(kind: content.profileKind)
                    guard generation == request, !Task.isCancelled else { return }
                    profiles = snapshot.profiles
                    let partial = content == .configuration ? snapshot.partialConfigurationProfiles : snapshot.partialProvisioningProfiles
                    lastIssue = partial.isEmpty ? (profiles.isEmpty ? "No profiles installed." : nil)
                        : "\(partial.count) profiles returned incomplete records. Available profiles are shown."
                }
            } catch {
                guard generation == request, !Task.isCancelled else { return }
                lastIssue = error.localizedDescription
            }
            guard generation == request, !Task.isCancelled else { return }
            reading = false
            readTask = nil
        }
    }
}
