import AppKit
import NeoSimulatorHostSupport
import NeoSimulatorKit
import ObservationBridge
import SwiftUI
import NeoSimulatorManager
import NeoSimulatorDeviceScreens

@MainActor
final class ManagerInspectorController: NSViewController {
    static let toolbarIdentifier = NSToolbarItem.Identifier("DeviceInspector")

    private enum Page: Int, CaseIterable {
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

    let deviceInspector: ManagerDeviceInspectorController
    var onShowServiceProfile: ((UUID) -> Void)?
    private let model: SimulatorManagerModel
    private let presentationState: DeviceBrowserState
    private let settings: NSHostingController<ManagerDeviceSettingsView>
    private lazy var services = BackgroundServicesViewController(model: BackgroundServicesInspectorModel(
        manager: model, showProfileSettings: { [weak self] in self?.onShowServiceProfile?($0) }))
    private weak var content: NSViewController?
    private weak var splitViewItem: NSSplitViewItem?
    private weak var toolbarItem: NSToolbarItem?
    private var selectionObservation: PortableObservationTracking.Token?
    private var selectedPage: Page { Page(rawValue: presentationState.inspectorTab)! }

    init(model: SimulatorManagerModel, screens: DeviceScreens, presentationState: DeviceBrowserState,
         showCustomLocation: @escaping () -> Void) {
        self.model = model
        self.presentationState = presentationState
        deviceInspector = ManagerDeviceInspectorController(model: model)
        settings = NSHostingController(rootView: ManagerDeviceSettingsView(model: DeviceSettingsPanelModel(
            manager: model, screens: screens, preferences: SimulatorPreferences(), customLocation: showCustomLocation)))
        super.init(nibName: nil, bundle: nil)
        settings.sizingOptions = []
        deviceInspector.inspection.select(presentationState.inspectorContent)
        selectionObservation = withPortableContinuousObservation { [weak self] _ in
            guard let self else { return }
            self.presentationState.inspectorContent = self.deviceInspector.inspection.content
        }
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() { view = NSView() }

    func makeSplitViewItem() -> NSSplitViewItem {
        let item = NSSplitViewItem(inspectorWithViewController: self)
        item.minimumThickness = 280
        item.maximumThickness = 440
        item.canCollapse = true
        item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        item.addTopAlignedAccessoryViewController(deviceInspector.categoryAccessory)
        services.searchAccessory.isHidden = true
        item.addBottomAlignedAccessoryViewController(services.searchAccessory)
        splitViewItem = item
        showSelectedPage()
        return item
    }

    func makeToolbarItem() -> NSToolbarItem {
        let pages = Page.allCases
        let images = pages.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title)! }
        let tabs = NSSegmentedControl(images: images, trackingMode: .selectOne, target: self, action: #selector(changePage(_:)))
        tabs.setAccessibilityLabel("Device Inspector")
        for page in pages { tabs.setToolTip(page.title, forSegment: page.rawValue) }
        let item = NSToolbarItem(itemIdentifier: Self.toolbarIdentifier)
        item.label = "Device Inspector"
        item.view = tabs
        item.visibilityPriority = .high
        let menu = NSMenu(title: item.label)
        for page in pages {
            let action = NSMenuItem(title: page.title, action: #selector(changePageFromMenu(_:)), keyEquivalent: "")
            action.target = self
            action.tag = page.rawValue
            menu.addItem(action)
        }
        let representation = NSMenuItem(title: item.label, action: nil, keyEquivalent: "")
        representation.submenu = menu
        item.menuFormRepresentation = representation
        toolbarItem = item
        updateToolbarSelection()
        return item
    }

    func update(device: DeviceModel?, isManaging: Bool) {
        deviceInspector.update(device: device, isManaging: isManaging, isVisible: showsDeviceInspector)
        updateServicesVisibility()
    }

    func updateVisibility() {
        let inspection = deviceInspector.inspection
        update(device: inspection.device, isManaging: inspection.isManaging)
        updateToolbarSelection()
    }

    func stopReading() { deviceInspector.stopReading() }
    func finishPreviews() async throws { try await deviceInspector.finishPreviews() }
    func resumeAfterCancelledQuit() { deviceInspector.resumeAfterCancelledQuit() }

    private var isVisible: Bool { splitViewItem?.isCollapsed == false }
    private var showsDeviceInspector: Bool { isVisible && (selectedPage == .reports || selectedPage == .info) }

    private func updateServicesVisibility() {
        let visible = isVisible && selectedPage == .services
        model.selection.setServicesVisible(visible)
        services.isVisible = visible
    }

    @objc private func changePage(_ sender: NSSegmentedControl) {
        guard let page = Page(rawValue: sender.selectedSegment) else { return }
        toggle(page)
    }

    @objc private func changePageFromMenu(_ sender: NSMenuItem) {
        guard let page = Page(rawValue: sender.tag) else { return }
        toggle(page)
    }

    private func toggle(_ page: Page) {
        guard let splitViewItem else { return }
        if page == selectedPage && !splitViewItem.isCollapsed {
            splitViewItem.animator().isCollapsed = true
        } else {
            presentationState.inspectorTab = page.rawValue
            showSelectedPage()
            splitViewItem.animator().isCollapsed = false
        }
        updateVisibility()
    }

    private func showSelectedPage() {
        let controller: NSViewController
        switch selectedPage {
        case .settings: controller = settings
        case .services: controller = services
        case .reports, .info:
            deviceInspector.setPage(selectedPage == .reports ? .reports : .info)
            controller = deviceInspector
        }
        guard content !== controller else { return }
        // Accessories are also children; replace only the selected page.
        content?.view.removeFromSuperview()
        content?.removeFromParent()
        addChild(controller)
        content = controller
        let pageView = controller.view
        pageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageView)
        NSLayoutConstraint.activate([
            pageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageView.topAnchor.constraint(equalTo: view.topAnchor),
            pageView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func updateToolbarSelection() {
        (toolbarItem?.view as? NSSegmentedControl)?.selectedSegment = isVisible ? selectedPage.rawValue : -1
        for action in toolbarItem?.menuFormRepresentation?.submenu?.items ?? [] {
            action.state = isVisible && action.tag == selectedPage.rawValue ? .on : .off
        }
    }
}
