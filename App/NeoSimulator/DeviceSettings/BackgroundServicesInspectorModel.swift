import Foundation
import Observation
import XcodeSimulatorHost

@MainActor @Observable
final class BackgroundServicesInspectorModel: BackgroundServiceEditing {
    enum Content: Equatable {
        case noSelection, multipleSelection, unsupportedDevice
        case simulator(SimulatorContent)
    }
    enum SimulatorContent: Equatable { case unavailableRuntime, stopped, loading, failure(String), services }

    let profiles: ServiceProfileStore
    @ObservationIgnored private let manager: SimulatorManagerModel
    @ObservationIgnored private let services: BackgroundServicesModel
    @ObservationIgnored private let showProfileSettings: (UUID) -> Void
    @ObservationIgnored lazy var categories = SimulatorBackgroundServiceCategory.all.map {
        BackgroundServiceCategoryModel($0, source: self)
    }
    var profileEditor: ServiceProfileEditorModel?
    var actionIssue: String?

    init(manager: SimulatorManagerModel, showProfileSettings: @escaping (UUID) -> Void) {
        self.manager = manager
        self.showProfileSettings = showProfileSettings
        services = manager.backgroundServices
        profiles = manager.serviceProfiles
    }

    var content: Content {
        if services.selectionCount > 1 { return .multipleSelection }
        guard services.selectionCount == 1, let device = services.device else { return .noSelection }
        guard case .simulator(let simulator) = device else { return .unsupportedDevice }
        guard simulator.isAvailable else { return .simulator(.unavailableRuntime) }
        guard simulator.state == "Booted" else { return .simulator(.stopped) }
        if services.serviceState != nil { return .simulator(.services) }
        if let issue = services.issue { return .simulator(.failure(issue)) }
        return .simulator(.loading)
    }
    var holdsChanges: Bool { services.device.map { !manager.canEditSettings(for: $0.id) } ?? true }
    var serviceState: SimulatorBackgroundServices? { services.serviceState }
    var issue: String? { services.issue }
    var outcome: BackgroundServicesModel.Outcome? { services.outcome }
    var isLoading: Bool { services.isLoading }
    var showsActionIssue: Bool {
        get { actionIssue != nil }
        set { if !newValue { actionIssue = nil } }
    }
    var selectedProfile: ServiceProfile {
        guard let device = services.device, let binding = profiles.binding(for: device.id) else { return .default }
        return profiles.profile(binding.profileID) ?? .default
    }
    struct ProfileChoice: Equatable {
        let id: UUID
        let title: String
    }
    var profileChoices: [ProfileChoice] {
        let selected = selectedProfile.id
        let modified = hasProfileChanges
        return profiles.availableProfiles.map {
            ProfileChoice(id: $0.id, title: $0.id == selected && modified ? "\($0.name) (Modified)" : $0.name)
        }
    }

    var selectedProfileID: UUID {
        get { selectedProfile.id }
        set {
            guard let device = services.device else { return }
            manager.selectServiceProfile(newValue, for: device.id)
        }
    }
    var hasProfileChanges: Bool {
        let current = services.configuration ?? services.device.flatMap { profiles.binding(for: $0.id)?.configuration } ?? ServiceConfiguration()
        let required = serviceState?.platformRequiredLabels ?? []
        return current.disabledLabels.subtracting(required) != selectedProfile.configuration.disabledLabels.subtracting(required)
    }
    var canSaveProfile: Bool {
        !holdsChanges && services.device?.canInspectBackgroundServices == true && serviceState != nil
            && profiles.issue == nil && hasProfileChanges
    }

    func customizeProfile() { showProfileSettings(selectedProfileID) }

    func saveProfile() {
        guard canSaveProfile, let device = services.device, let configuration = services.configuration else { return }
        let profile = selectedProfile
        if profile.id == ServiceProfile.default.id {
            let editor = ServiceProfileEditorModel(name: "", configuration: configuration)
            editor.save = { [profiles, deviceID = device.id] editor in
                try profiles.create(name: editor.name, configuration: editor.configuration, assigningTo: deviceID)
            }
            profileEditor = editor
        } else {
            do { try profiles.update(profile.id, configuration: configuration, assigningTo: device.id) }
            catch { actionIssue = error.localizedDescription }
        }
    }
    func revertProfile() {
        guard let device = services.device else { return }
        manager.revertServiceProfile(for: device.id)
    }
    func setServices(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool) {
        guard let device = services.device else { return }
        manager.setBackgroundServices(targets, enabled: enabled, for: device.id)
    }
    func requestRefresh() { services.requestRefresh() }
}
