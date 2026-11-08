import AppKit
import NeoSimulatorHostSupport
import NeoSimulatorKit
import NeoSimulatorManager
import ObservationBridge
import SwiftUI

/// Shows the inspector model's page in its split view item and toolbar item.
@MainActor
package final class InspectorViewController: NSViewController {
    package static let toolbarIdentifier = NSToolbarItem.Identifier("DeviceInspector")

    let model: InspectorModel
    let deviceInspector: ManagerDeviceInspectorController
    private let settings: NSHostingController<ManagerDeviceSettingsView>
    private let services: BackgroundServicesViewController
    private weak var shownPage: NSViewController?
    private weak var splitViewItem: NSSplitViewItem?
    private weak var toolbarItem: NSToolbarItem?
    private var collapseObservation: NSKeyValueObservation?
    private var stateObservation: PortableObservationTracking.Token?

    /// Device commands come from the window, which presents what they ask for.
    package init(
        model: InspectorModel, manager: SimulatorManagerModel,
        pairingMenu: @escaping (SimulatorHostDevice) -> NSMenu, deviceMenu: @escaping (SimulatorHostDevice) -> NSMenu
    ) {
        self.model = model
        deviceInspector = ManagerDeviceInspectorController(model: manager, inspection: model.deviceInspection)
        deviceInspector.onPairingMenu = pairingMenu
        deviceInspector.onDeviceMenu = deviceMenu
        settings = NSHostingController(rootView: ManagerDeviceSettingsView(model: model.settings))
        services = BackgroundServicesViewController(model: model.services)
        super.init(nibName: nil, bundle: nil)
        // AppKit owns the pane size; content-derived bounds must not constrain the window.
        settings.sizingOptions = []
    }

    required init?(coder: NSCoder) { nil }

    override package func loadView() { view = NSView() }

    package func makeSplitViewItem() -> NSSplitViewItem {
        let item = NSSplitViewItem(inspectorWithViewController: self)
        item.minimumThickness = 280
        item.maximumThickness = 440
        item.canCollapse = true
        item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        item.addTopAlignedAccessoryViewController(deviceInspector.categoryAccessory)
        services.addAccessories(to: item)
        splitViewItem = item
        collapseObservation = item.observe(\.isCollapsed, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let item = self.splitViewItem else { return }
                self.model.setShown(!item.isCollapsed)
                self.update()
            }
        }
        stateObservation = withPortableContinuousObservation { [weak self, model] event in
            _ = model.device
            _ = model.isManaging
            guard event.kind != .initial else { return }
            // Updating the page writes to models that this pass would otherwise track.
            Task { @MainActor [weak self] in self?.update() }
        }
        return item
    }

    package func makeToolbarItem() -> NSToolbarItem {
        let pages = InspectorModel.Page.allCases
        let images = pages.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title)! }
        let tabs = NSSegmentedControl(
            images: images, trackingMode: .selectOne, target: self, action: #selector(changePage(_:)))
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
        update()
        return item
    }

    package func stopReading() { deviceInspector.stopReading() }
    package func finishPreviews() async throws { try await deviceInspector.finishPreviews() }
    package func resumeAfterCancelledQuit() { deviceInspector.resumeAfterCancelledQuit() }

    @objc private func changePage(_ sender: NSSegmentedControl) {
        guard let page = InspectorModel.Page(rawValue: sender.selectedSegment) else { return }
        model.toggle(page)
        update()
    }

    @objc private func changePageFromMenu(_ sender: NSMenuItem) {
        guard let page = InspectorModel.Page(rawValue: sender.tag) else { return }
        model.toggle(page)
        update()
    }

    /// Applies the model to the split view item, the shown page, and the toolbar.
    private func update() {
        guard let splitViewItem else { return }
        if splitViewItem.isCollapsed == model.isShown { splitViewItem.animator().isCollapsed = !model.isShown }
        show(model.page)
        deviceInspector.update(
            device: model.device, isManaging: model.isManaging, isVisible: model.showsDeviceInspector)
        let selected = model.isShown ? model.page.rawValue : -1
        (toolbarItem?.view as? NSSegmentedControl)?.selectedSegment = selected
        for action in toolbarItem?.menuFormRepresentation?.submenu?.items ?? [] {
            action.state = action.tag == selected ? .on : .off
        }
    }

    private func show(_ page: InspectorModel.Page) {
        let controller: NSViewController
        switch page {
        case .settings: controller = settings
        case .services: controller = services
        case .reports, .info:
            deviceInspector.setPage(page == .reports ? .reports : .info)
            controller = deviceInspector
        }
        guard shownPage !== controller else { return }
        // Accessories are also children; replace only the page.
        shownPage?.view.removeFromSuperview()
        shownPage?.removeFromParent()
        addChild(controller)
        shownPage = controller
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
}
