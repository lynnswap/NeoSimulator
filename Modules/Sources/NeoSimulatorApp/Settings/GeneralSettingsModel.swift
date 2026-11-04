import NeoSimulatorKit
import NeoSimulatorHostSupport
@_spi(NeoSimulator) import XcodeSimulatorHost
import Foundation
import Observation

@MainActor @Observable
final class GeneralSettingsModel {
    let preferences: SimulatorPreferences
    let frameworks: UIFrameworkSettings
    var confirmsRestore = false
    @ObservationIgnored private let manager: SimulatorManagerModel
    @ObservationIgnored private let restartApplication: () -> Void

    init(manager: SimulatorManagerModel, preferences: SimulatorPreferences, frameworks: UIFrameworkSettings,
         restart: @escaping () -> Void) {
        self.manager = manager
        self.preferences = preferences
        self.frameworks = frameworks
        restartApplication = restart
    }

    var preferredHost: SimulatorHost {
        get { manager.status?.preferredHost ?? .neo }
        set { manager.select(newValue) }
    }
    var selectedXcodeURL: URL? {
        get { frameworks.selectedXcodeURL }
        set { frameworks.select(newValue) }
    }
    var missingXcodeURL: URL? {
        guard let selected = frameworks.selectedXcodeURL,
              !frameworks.installations.contains(where: { $0.url == selected }) else { return nil }
        return selected
    }
    var canSelectHost: Bool { !manager.isBusy && manager.status != nil }
    var canSelectFrameworks: Bool { !manager.isBusy && !frameworks.isLoading }
    var canRestore: Bool { !manager.isBusy && manager.status?.restorationAvailable == true }
    var canRestart: Bool { !manager.isBusy }
    var offersNeoHost: Bool { manager.status?.preferredHost == .neo && manager.status?.host != .neo }
    var frameworkMessage: String {
        if let issue = frameworks.issue { return issue }
        return frameworks.needsRestart
            ? String(localized: "Restart NeoSimulator to apply this change. Simulators will keep running.")
            : String(localized: "Uses the selected Xcode's display frameworks. Simulator runtimes are selected independently.")
    }

    func useNeoHost() { manager.select(.neo) }
    func restoreDefaults() { manager.restoreDefaults() }
    func restart() { restartApplication() }
}
