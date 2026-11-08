import NeoSimulatorKit
import NeoSimulatorHostSupport
import Foundation
import Observation
import ObservationBridge
import NeoSimulatorManager

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
    /// The store's categories, whose switches change the selected simulator.
    private(set) var categories: [BackgroundServiceCategoryModel] = []
    /// The catalog and models that ``categories`` shows, which taking in a change reads without observing them.
    @ObservationIgnored private var shown:
        (catalog: BackgroundServiceCatalog, models: [BackgroundServiceCategoryModel])?
    @ObservationIgnored private var catalogObservation: PortableObservationTracking.Token?
    var profileEditor: ServiceProfileEditorModel?
    var actionIssue: String?

    init(manager: SimulatorManagerModel, showProfileSettings: @escaping (UUID) -> Void) {
        self.manager = manager
        self.showProfileSettings = showProfileSettings
        selection = manager.selection
        profiles = manager.serviceProfiles
        // The list takes the categories when it loads, which can come before the observation's first pass.
        showCatalog()
        catalogObservation = withPortableContinuousObservation { [weak self] _ in self?.showCatalog() }
    }

    private func showCatalog() {
        let catalog = profiles.catalog
        guard catalog != shown?.catalog else { return }
        let previous = shown?.models ?? []
        let models = BackgroundServiceCategoryModel.models(
            for: catalog, custom: profiles.customCategoryIDs, reusing: previous, source: self)
        shown = (catalog, models)
        if models.map(ObjectIdentifier.init) != previous.map(ObjectIdentifier.init) { categories = models }
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
    /// The profile controls and the filter belong to a simulator's services, while their page shows.
    var showsAccessories: Bool {
        guard selection.showsServices, case .simulator = content else { return false }
        return true
    }
    var canFilter: Bool { content == .simulator(.services) }
    var holdsChanges: Bool { selection.device.map { !manager.canEditSettings(for: $0.id) } ?? true }
    var serviceState: SimulatorBackgroundServices? { services?.services }
    var issue: String? {
        if case .stale(let reason) = services?.status { reason } else { nil }
    }
    var pendingRestartLabels: Set<String> { services?.pendingRestartLabels ?? [] }
    var selectedProfile: ServiceProfile {
        selection.device.flatMap { profiles.resolvedProfile(for: $0.id) } ?? profiles.allServices
    }
    struct ProfileChoice: Equatable {
        let id: ServiceProfileSelection
        let title: String
    }
    var defaultProfileChoice: ProfileChoice {
        profileChoice(.inheritDefault, title: String(localized: "Use Default: \(profiles.defaultProfile.name)"))
    }
    /// The choices after the default: All Services while the simulator names it, then the saved profiles.
    var profileChoices: [ProfileChoice] {
        let allServices = ServiceProfileSelection.profile(ServiceProfile.allServicesID)
        let named =
            selectedProfileSelection == allServices
            ? [profileChoice(allServices, title: profiles.allServices.name)] : []
        return named + profiles.profiles.map { profileChoice(.profile($0.id), title: $0.name) }
    }
    private func profileChoice(_ selection: ServiceProfileSelection, title: String) -> ProfileChoice {
        ProfileChoice(
            id: selection,
            title: selection == selectedProfileSelection && hasProfileChanges
                ? String(localized: "\(title) (Modified)") : title)
    }

    var selectedProfileSelection: ServiceProfileSelection {
        get { selection.device.map { profiles.selection(for: $0.id) } ?? .inheritDefault }
        set {
            guard let device = selection.device else { return }
            manager.selectServiceProfile(newValue, for: device.id)
        }
    }
    var hasProfileChanges: Bool {
        if let device = selection.device, profiles.binding(for: device.id)?.overrides.isEmpty == false { return true }
        let current =
            services?.configuration ?? selection.device.flatMap { profiles.configuration(for: $0.id) }
            ?? ServiceConfiguration()
        let required = serviceState?.platformRequiredLabels ?? []
        return current.disabledLabels.subtracting(required)
            != selectedProfile.configuration.disabledLabels.subtracting(required)
    }
    var canSaveProfile: Bool {
        !holdsChanges && selection.device?.canInspectBackgroundServices == true && serviceState != nil
            && issue == nil && profiles.issue == nil && hasProfileChanges
    }
    var canRevertProfile: Bool {
        guard !holdsChanges, hasProfileChanges, let device = selection.device else { return false }
        return profiles.binding(for: device.id)?.overrides.isEmpty == false
            || profiles.resolvedProfile(for: device.id) != nil
    }

    func openProfileSettings() { showProfileSettings(selectedProfile.id) }

    func saveProfile() {
        guard canSaveProfile, let device = selection.device, let configuration = services?.configuration else { return }
        let profile = selectedProfile
        if profile.id == ServiceProfile.allServicesID {
            let editor = ServiceProfileEditorModel(name: "", configuration: configuration)
            editor.save = { [profiles, deviceID = device.id] editor in
                try profiles.create(name: editor.name, configuration: editor.configuration, assigningTo: deviceID)
            }
            profileEditor = editor
        } else {
            do { try profiles.update(profile.id, configuration: configuration, assigningTo: device.id) } catch {
                actionIssue = error.localizedDescription
            }
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
