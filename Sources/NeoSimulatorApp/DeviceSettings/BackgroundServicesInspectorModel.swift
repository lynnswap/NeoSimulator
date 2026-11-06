import NeoSimulatorKit
import NeoSimulatorHostSupport
import Foundation
import Observation

@MainActor @Observable
final class BackgroundServicesInspectorModel: BackgroundServiceEditing {
    enum Content: Equatable {
        case noSelection, multipleSelection, unsupportedDevice
        case simulator(SimulatorContent)
    }
    enum SimulatorContent: Equatable { case unavailableRuntime, stopped, loading, failure(String), services }

    let profiles: ServiceProfileStore
    @ObservationIgnored private let manager: SimulatorManagerModel
    @ObservationIgnored private let selection: ManagerSelection
    @ObservationIgnored private let showProfileSettings: (UUID) -> Void
    @ObservationIgnored lazy var categories = SimulatorBackgroundServiceCategory.all.map {
        BackgroundServiceCategoryModel($0, source: self)
    }
    var profileEditor: ServiceProfileEditorModel?
    var actionIssue: String?

    init(manager: SimulatorManagerModel, showProfileSettings: @escaping (UUID) -> Void) {
        self.manager = manager
        self.showProfileSettings = showProfileSettings
        selection = manager.selection
        profiles = manager.serviceProfiles
    }

    private var services: BackgroundServicesState? { selection.device?.backgroundServices }

    var content: Content {
        if selection.count > 1 { return .multipleSelection }
        guard selection.count == 1, let device = selection.device else { return .noSelection }
        guard case .simulator(let simulator) = device.inventory else { return .unsupportedDevice }
        guard simulator.isAvailable else { return .simulator(.unavailableRuntime) }
        guard simulator.state == "Booted" else { return .simulator(.stopped) }
        // A failed read keeps what was read before, which `issue` says may be out of date.
        if device.backgroundServices.services != nil { return .simulator(.services) }
        if let issue { return .simulator(.failure(issue)) }
        return .simulator(.loading)
    }
    var holdsChanges: Bool { selection.device.map { !manager.canEditSettings(for: $0.id) } ?? true }
    var serviceState: SimulatorBackgroundServices? { services?.services }
    var issue: String? {
        if case .stale(let reason) = services?.status { reason } else { nil }
    }
    var pendingRestartLabels: Set<String> { services?.pendingRestartLabels ?? [] }
    var isLoading: Bool { services?.isReading == true }
    var showsActionIssue: Bool {
        get { actionIssue != nil }
        set { if !newValue { actionIssue = nil } }
    }
    var selectedProfile: ServiceProfile {
        guard let device = selection.device, let binding = profiles.binding(for: device.id) else { return .default }
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
            guard let device = selection.device else { return }
            manager.selectServiceProfile(newValue, for: device.id)
        }
    }
    var hasProfileChanges: Bool {
        let current = services?.configuration ?? selection.device.flatMap { profiles.binding(for: $0.id)?.configuration } ?? ServiceConfiguration()
        let required = serviceState?.platformRequiredLabels ?? []
        return current.disabledLabels.subtracting(required) != selectedProfile.configuration.disabledLabels.subtracting(required)
    }
    var canSaveProfile: Bool {
        !holdsChanges && selection.device?.canInspectBackgroundServices == true && serviceState != nil
            && issue == nil && profiles.issue == nil && hasProfileChanges
    }

    func customizeProfile() { showProfileSettings(selectedProfileID) }

    func saveProfile() {
        guard canSaveProfile, let device = selection.device, let configuration = services?.configuration else { return }
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
        guard let device = selection.device else { return }
        manager.revertServiceProfile(for: device.id)
    }
    func setServices(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool) {
        guard let device = selection.device else { return }
        manager.setBackgroundServices(targets, enabled: enabled, for: device.id)
    }
    func requestRefresh() { selection.device?.revalidate(.backgroundServices) }
}
