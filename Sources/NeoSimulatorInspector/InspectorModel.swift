import Foundation
import NeoSimulatorDeviceScreens
import NeoSimulatorHostSupport
import NeoSimulatorKit
import NeoSimulatorManager
import Observation
import ObservationBridge

/// What the inspector pane shows. The device it describes is the manager's selection, and what is known of that
/// device belongs to the device's model.
@MainActor @Observable
package final class InspectorModel {
    enum Page: Int, CaseIterable {
        case settings, reports, info, services

        var title: String {
            switch self {
            case .settings: "Settings"
            case .reports: "Reports"
            case .info: "Info"
            case .services: "Background Services"
            }
        }

        var symbol: String {
            switch self {
            case .settings: "slider.horizontal.3"
            case .reports: "text.document"
            case .info: "info"
            case .services: "cpu"
            }
        }
    }

    private static let pageKey = "InspectorTab"
    private static let contentKey = "InspectorContent"

    /// The page the toolbar chooses. It stays chosen while the pane is hidden.
    private(set) var page: Page {
        didSet {
            guard page != oldValue else { return }
            defaults.set(page.rawValue, forKey: Self.pageKey)
            updateReadInterest()
        }
    }
    /// Whether the pane shows. Its split view item follows this value, and reports a collapse made elsewhere.
    private(set) var isShown = false {
        didSet { if isShown != oldValue { updateReadInterest() } }
    }
    let deviceInspection = DeviceInspectorModel()
    let services: BackgroundServicesInspectorModel
    let settings: DeviceSettingsPanelModel
    @ObservationIgnored private let manager: SimulatorManagerModel
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var contentObservation: PortableObservationTracking.Token?

    package init(manager: SimulatorManagerModel, screens: DeviceScreens, defaults: UserDefaults,
                 showProfileSettings: @escaping (UUID) -> Void, showCustomLocation: @escaping () -> Void) {
        self.manager = manager
        self.defaults = defaults
        page = Page(rawValue: defaults.integer(forKey: Self.pageKey)) ?? .settings
        services = BackgroundServicesInspectorModel(manager: manager, showProfileSettings: showProfileSettings)
        settings = DeviceSettingsPanelModel(manager: manager, screens: screens, preferences: SimulatorPreferences(),
                                            customLocation: showCustomLocation)
        deviceInspection.select(DeviceInspectorModel.Content(rawValue: defaults.integer(forKey: Self.contentKey)) ?? .info)
        contentObservation = withPortableContinuousObservation { [weak self] event in
            guard let self else { return }
            let content = deviceInspection.content
            guard event.kind != .initial else { return }
            self.defaults.set(content.rawValue, forKey: Self.contentKey)
        }
    }

    /// The one selected device, which every page describes.
    var device: DeviceModel? { manager.selection.device }
    var isManaging: Bool { device.map { manager.managingDeviceIDs.contains($0.id) } ?? false }
    var showsDeviceInspector: Bool { isShown && (page == .reports || page == .info) }
    var showsServices: Bool { isShown && page == .services }

    /// Shows `page`, or hides the pane when `page` already shows.
    func toggle(_ page: Page) {
        if page == self.page && isShown {
            isShown = false
        } else {
            self.page = page
            isShown = true
        }
    }

    func setShown(_ shown: Bool) {
        if isShown != shown { isShown = shown }
    }

    /// launchd is read only while the Background Services page shows.
    private func updateReadInterest() {
        manager.selection.setServicesVisible(showsServices)
    }
}
