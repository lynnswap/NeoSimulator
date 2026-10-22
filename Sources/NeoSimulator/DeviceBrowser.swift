import AppKit
import Observation
import SwiftUI

struct AvailableDevice: Identifiable {
    let identifier: String
    let name: String
    let descriptiveName: String
    let runtimeIdentifier: String
    let runtimeName: String
    /// `SimDeviceType.productFamilyID`, as in `SimulatorDevice.productFamily`.
    let productFamily: Int
    let deviceTypeName: String
    var state: UInt
    var id: String { identifier }
    var isBooted: Bool { state == 3 }
    /// The SF Symbol of the device's product family.
    var symbolName: String {
        switch DeviceCapabilities.Family(rawValue: productFamily) {
        case .iPad: "ipad"
        case .tv: "appletv"
        case .watch: "applewatch"
        case .vision: "visionpro"
        case .iPhone, nil: "iphone"
        }
    }
    var canOpen: Bool { state == 1 || state == 3 }
    var stateLabel: String {
        switch state {
        case 1: "Shut Down"
        case 2: "Starting…"
        case 3: "Running"
        case 4: "Shutting Down…"
        default: "Unavailable"
        }
    }

    init(identifier: String, name: String, descriptiveName: String, runtimeIdentifier: String,
         runtimeName: String, productFamily: Int, deviceTypeName: String, state: UInt) {
        self.identifier = identifier
        self.name = name
        self.descriptiveName = descriptiveName
        self.runtimeIdentifier = runtimeIdentifier
        self.runtimeName = runtimeName
        self.productFamily = productFamily
        self.deviceTypeName = deviceTypeName
        self.state = state
    }
}

@MainActor
protocol DeviceBrowserSource: AnyObject {
    func availableSimulatorDevices() throws -> [AvailableDevice]
    func openSimulator(withIdentifier identifier: String) async throws
}

@MainActor @Observable
final class DeviceBrowserModel {
    private weak var source: (any DeviceBrowserSource)?
    private(set) var devices: [AvailableDevice] = []
    private(set) var opening: Set<String> = []
    var errorMessage: String?

    init(source: any DeviceBrowserSource) {
        self.source = source
        refresh()
    }

    func refresh() {
        do {
            devices = try source?.availableSimulatorDevices().sorted {
            let runtimeOrder = $0.runtimeName.compare($1.runtimeName, options: .numeric)
            return runtimeOrder == .orderedSame
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : runtimeOrder == .orderedDescending
            } ?? []
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    func open(_ device: AvailableDevice) -> Task<Void, Never>? {
        guard let source, device.canOpen, opening.insert(device.id).inserted else { return nil }
        return Task {
            defer { opening.remove(device.id); refresh() }
            do { try await source.openSimulator(withIdentifier: device.id) }
            catch is CancellationError {}
            catch { errorMessage = error.localizedDescription }
        }
    }
}

struct DeviceBrowserView: View {
    @Bindable var model: DeviceBrowserModel
    @State private var search = ""

    private var devices: [AvailableDevice] {
        model.devices.filter {
            search.isEmpty || $0.name.localizedStandardContains(search)
                || $0.runtimeName.localizedStandardContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Simulators").font(.largeTitle.bold())
                    Text("Choose a device to open.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise", action: model.refresh)
                    .labelStyle(.iconOnly)
                    .help("Refresh Simulators")
            }
            .padding(24)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search devices or runtimes", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") { search = "" }
                        .labelStyle(.iconOnly).buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            if model.devices.isEmpty {
                ContentUnavailableView("No Simulators", systemImage: "iphone",
                    description: Text("Install a simulator runtime and create a simulator in Xcode, then refresh."))
            } else if devices.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List {
                    ForEach(Array(Set(devices.map(\.runtimeName))).sorted {
                        $0.compare($1, options: .numeric) == .orderedDescending
                    }, id: \.self) { runtime in
                        Section(runtime) {
                            ForEach(devices.filter { $0.runtimeName == runtime }) { device in
                                HStack(spacing: 14) {
                                    Image(systemName: device.symbolName)
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                        .frame(width: 32)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(device.name).font(.headline)
                                        HStack(spacing: 5) {
                                            Circle().fill(device.isBooted ? Color.green : Color.secondary)
                                                .frame(width: 6, height: 6)
                                            Text(device.stateLabel).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if model.opening.contains(device.id) {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Button(device.isBooted ? "Open" : "Start") { model.open(device) }
                                            .disabled(!device.canOpen)
                                    }
                                }
                                .padding(.vertical, 8)
                                .contextMenu {
                                    Button("Copy Device Identifier") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(device.id, forType: .string)
                                    }
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            Text("Closing a device window shuts its simulator down. Hold Control to keep it running.")
                .font(.caption).foregroundStyle(.secondary).padding(14)
        }
        .frame(minWidth: 440, minHeight: 380)
        .background(.background)
        .alert("Could Not Open Simulator", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

@MainActor
final class DeviceBrowserWindowController: NSWindowController {
    private let model: DeviceBrowserModel

    init(source: any DeviceBrowserSource) {
        model = DeviceBrowserModel(source: source)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "NeoSimulator"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DeviceBrowserView(model: model))
        window.contentMinSize = NSSize(width: 440, height: 380)
        window.setFrameAutosaveName("SimulatorBrowser")
        super.init(window: window)
    }

    required init?(coder: NSCoder) { nil }

    func refresh() { model.refresh() }
    func report(_ error: Error) { model.errorMessage = error.localizedDescription }

    func show() {
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// File ▸ New Simulator…, Simulator.app's creation form.
///
/// The form offers every supported device type and available runtime. Choosing
/// one keeps the other when they are compatible and otherwise selects the first
/// compatible choice. An empty name creates the device with its device type's
/// name, shown as the placeholder. Creating closes the window without booting
/// the device.
///
/// Paired Apple Watch, enabled only for an iPhone, turns Create into Next,
/// which shows the watch's page: its name, a watch device type, and a runtime
/// that supports it, kept compatible the same way, except that choosing a
/// device type the runtime does not support lists only the runtimes that do.
/// There Create is enabled only while CoreSimulator can pair the two devices;
/// it creates the iPhone, then the watch, and pairs them. Like Simulator.app,
/// a failure keeps the devices already created; the alert names them.
@MainActor
final class NewSimulatorWindowController: NSWindowController, NSWindowDelegate {
    /// Creates a device and returns its identifier.
    typealias Create = @MainActor (_ name: String, _ deviceType: String, _ runtime: String) async throws -> String
    typealias Pair = @MainActor (_ watch: String, _ phone: String) async throws -> Void

    let nameField = NSTextField()
    let deviceTypes = NSPopUpButton()
    let runtimes = NSPopUpButton()
    let pairedWatchButton = NSButton(checkboxWithTitle: "Paired Apple Watch", target: nil, action: nil)
    let watchNameField = NSTextField()
    let watchDeviceTypes = NSPopUpButton()
    let watchRuntimes = NSPopUpButton()
    let previousButton = NSButton(title: "Previous", target: nil, action: nil)
    /// Create, or Next while the first page leads to the watch's page.
    let forwardButton = NSButton(title: "Create", target: nil, action: nil)
    private let simulatorPage = NSGridView()
    private let watchPage = NSGridView()
    private let catalog: SimulatorCatalog
    private let create: Create
    private let pair: Pair
    private let onClose: () -> Void
    private var creation: Task<Void, Never>?

    init(catalog: SimulatorCatalog, create: @escaping Create, pair: @escaping Pair, onClose: @escaping () -> Void = {}) {
        self.catalog = catalog
        self.create = create
        self.pair = pair
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 196, y: 240, width: 618, height: 258),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "New Simulator"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        fillMenus()
        fillWatchMenus()
    }

    required init?(coder: NSCoder) { nil }

    /// Whether the watch's page is showing.
    var showsWatchPage: Bool { !watchPage.isHidden }

    private func makeContent() -> NSView {
        func label(_ title: String) -> NSTextField {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            return label
        }
        func layOut(_ page: NSGridView, _ rows: [[NSView]]) {
            for row in rows { page.addRow(with: row) }
            page.column(at: 0).xPlacement = .trailing
            page.rowAlignment = .firstBaseline
            page.rowSpacing = 8
        }
        for field in [nameField, watchNameField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 200).isActive = true
        }
        for (popUp, action) in [(deviceTypes, #selector(deviceTypeChanged(_:))), (runtimes, #selector(runtimeChanged(_:))),
                                (watchDeviceTypes, #selector(watchDeviceTypeChanged(_:))),
                                (watchRuntimes, #selector(watchRuntimeChanged(_:)))] {
            popUp.target = self
            popUp.action = action
        }
        pairedWatchButton.target = self
        pairedWatchButton.action = #selector(pairedWatchChanged(_:))
        layOut(simulatorPage, [
            [label("Simulator Name:"), nameField],
            [label("Device Type:"), deviceTypes],
            [label("OS Version:"), runtimes],
            [NSGridCell.emptyContentView, pairedWatchButton],
        ])
        layOut(watchPage, [
            [label("Paired Watch Name:"), watchNameField],
            [label("Device Type:"), watchDeviceTypes],
            [label("OS Version:"), watchRuntimes],
        ])
        watchPage.isHidden = true
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        previousButton.target = self
        previousButton.action = #selector(previous(_:))
        previousButton.isEnabled = false
        forwardButton.target = self
        forwardButton.action = #selector(forward(_:))
        let heading = NSTextField(labelWithString: "Create a new simulator:")
        let content = NSView()
        for view in [heading, simulatorPage, watchPage, cancel, previousButton, forwardButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            simulatorPage.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 20),
            simulatorPage.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            watchPage.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 20),
            watchPage.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            cancel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            previousButton.trailingAnchor.constraint(equalTo: forwardButton.leadingAnchor, constant: -12),
            previousButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            forwardButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            forwardButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        return content
    }

    private func fillMenus() {
        var family: Int?
        for type in catalog.deviceTypes {
            // Simulator.app separates product families without headings.
            if let family, family != type.productFamily { deviceTypes.menu?.addItem(.separator()) }
            family = type.productFamily
            deviceTypes.menu?.addItem(item(type.name, representing: type.identifier))
        }
        guard !catalog.runtimes.isEmpty else {
            addNoRuntimesItem(to: runtimes)
            for control in [runtimes, deviceTypes, pairedWatchButton] as [NSControl] { control.isEnabled = false }
            updateForwardButton()
            return
        }
        for runtime in catalog.runtimes {
            runtimes.menu?.addItem(item(runtime.name, representing: runtime.identifier))
        }
        deviceTypes.selectItem(at: 0)
        runtimes.selectItem(at: 0)
        // Like Simulator.app, the initial runtime stays and the device type adapts.
        runtimeChanged(nil)
    }

    /// The watch's page lists the watch device types without separators and,
    /// at first, the runtimes that support any of them.
    private func fillWatchMenus() {
        let watchTypes = catalog.deviceTypes.filter { $0.productFamily == DeviceCapabilities.Family.watch.rawValue }
        // Without watch device types Simulator.app leaves both menus empty.
        guard !watchTypes.isEmpty else { return }
        for type in watchTypes { watchDeviceTypes.menu?.addItem(item(type.name, representing: type.identifier)) }
        let runtimes = catalog.runtimes.filter { runtime in
            watchTypes.contains { catalog.runtime(runtime.identifier, supports: $0.identifier) }
        }
        guard !runtimes.isEmpty else {
            addNoRuntimesItem(to: watchRuntimes)
            watchRuntimes.isEnabled = false
            watchDeviceTypes.isEnabled = false
            return
        }
        for runtime in runtimes { watchRuntimes.menu?.addItem(item(runtime.name, representing: runtime.identifier)) }
        watchDeviceTypes.selectItem(at: 0)
        watchRuntimes.selectItem(at: 0)
        watchRuntimeChanged(nil)
    }

    private func addNoRuntimesItem(to popUp: NSPopUpButton) {
        let none = NSMenuItem(title: "No Runtimes Available", action: nil, keyEquivalent: "")
        none.isEnabled = false
        popUp.menu?.addItem(none)
    }

    private func item(_ title: String, representing identifier: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = identifier
        return item
    }

    private var deviceType: String? { deviceTypes.selectedItem?.representedObject as? String }
    private var runtime: String? { runtimes.selectedItem?.representedObject as? String }
    private var watchType: String? { watchDeviceTypes.selectedItem?.representedObject as? String }
    private var watchRuntime: String? { watchRuntimes.selectedItem?.representedObject as? String }

    // An empty selection counts as incompatible, as a nil selection does in
    // Simulator.app, so choosing again restores a compatible one.
    @objc private func deviceTypeChanged(_ sender: Any?) {
        if let deviceType, runtime.map({ catalog.runtime($0, supports: deviceType) }) != true {
            select(in: runtimes) { catalog.runtime($0, supports: deviceType) }
        }
        simulatorSelectionDidChange()
    }

    @objc private func runtimeChanged(_ sender: Any?) {
        if let runtime, deviceType.map({ catalog.runtime(runtime, supports: $0) }) != true {
            select(in: deviceTypes) { catalog.runtime(runtime, supports: $0) }
        }
        simulatorSelectionDidChange()
    }

    /// Like Simulator.app, Paired Apple Watch is enabled only for an iPhone and
    /// turns off for another device type; an empty selection leaves it as it is.
    private func simulatorSelectionDidChange() {
        nameField.placeholderString = deviceTypes.selectedItem?.title
        if let family = deviceType.flatMap(catalog.deviceType)?.productFamily {
            pairedWatchButton.isEnabled = family == DeviceCapabilities.Family.iPhone.rawValue
            if !pairedWatchButton.isEnabled { pairedWatchButton.state = .off }
        }
        updateForwardButton()
    }

    /// Like Simulator.app, a watch that the runtime does not support replaces
    /// the runtime menu with the runtimes that support it.
    @objc private func watchDeviceTypeChanged(_ sender: Any?) {
        if let watchType, watchRuntime.map({ catalog.runtime($0, supports: watchType) }) != true {
            watchRuntimes.removeAllItems()
            for runtime in catalog.runtimes where catalog.runtime(runtime.identifier, supports: watchType) {
                watchRuntimes.menu?.addItem(item(runtime.name, representing: runtime.identifier))
            }
            watchRuntimes.select(watchRuntimes.itemArray.first)
        }
        watchNameField.placeholderString = watchDeviceTypes.selectedItem?.title
        updateForwardButton()
    }

    @objc private func watchRuntimeChanged(_ sender: Any?) {
        if let watchRuntime, watchType.map({ catalog.runtime(watchRuntime, supports: $0) }) != true {
            select(in: watchDeviceTypes) { catalog.runtime(watchRuntime, supports: $0) }
        }
        watchNameField.placeholderString = watchDeviceTypes.selectedItem?.title
        updateForwardButton()
    }

    /// Selects the first item whose identifier matches, or nothing.
    private func select(in popUp: NSPopUpButton, where matches: (String) -> Bool) {
        popUp.select(popUp.itemArray.first { ($0.representedObject as? String).map(matches) == true })
    }

    @objc private func pairedWatchChanged(_ sender: Any?) { updateForwardButton() }

    /// Whether Create also creates a watch, which Simulator.app decides from
    /// the option being enabled and on.
    private var pairsWatch: Bool { pairedWatchButton.isEnabled && pairedWatchButton.state == .on }

    /// Whether the four choices make a pair that CoreSimulator can create.
    private var canPair: Bool {
        guard let deviceType, let runtime, let watchType, let watchRuntime,
              catalog.runtime(watchRuntime, supports: watchType) else { return false }
        return catalog.canPair(watchType, watchRuntime, deviceType, runtime)
    }

    private func updateForwardButton() {
        forwardButton.title = pairsWatch && !showsWatchPage ? "Next" : "Create"
        forwardButton.isEnabled = !catalog.runtimes.isEmpty && creation == nil && (!showsWatchPage || canPair)
    }

    private func showWatchPage(_ shows: Bool) {
        simulatorPage.isHidden = shows
        watchPage.isHidden = !shows
        previousButton.isEnabled = shows
        updateForwardButton()
    }

    @objc private func forward(_ sender: Any?) {
        if pairsWatch && !showsWatchPage { showWatchPage(true) } else { createSimulator() }
    }

    @objc private func previous(_ sender: Any?) { showWatchPage(false) }

    /// An empty name field names the device after its placeholder.
    private static func name(in field: NSTextField) -> String {
        field.stringValue.isEmpty ? field.placeholderString ?? "" : field.stringValue
    }

    private func createSimulator() {
        guard creation == nil, let deviceType, let runtime else { return }
        let name = Self.name(in: nameField)
        var watch: (name: String, deviceType: String, runtime: String)?
        if pairsWatch {
            guard let watchType, let watchRuntime else { return }
            watch = (Self.name(in: watchNameField), watchType, watchRuntime)
        }
        creation = Task {
            defer {
                creation = nil
                updateForwardButton()
            }
            do {
                let phone = try await create(name, deviceType, runtime)
                if let watch {
                    let identifier: String
                    do { identifier = try await create(watch.name, watch.deviceType, watch.runtime) } catch {
                        throw HostError.operation(
                            "Created “\(name)”, but could not create its paired Apple Watch: \(error.localizedDescription)")
                    }
                    do { try await pair(identifier, phone) } catch {
                        throw HostError.operation(
                            "Created “\(name)” and “\(watch.name)”, but could not pair them: \(error.localizedDescription)")
                    }
                }
                close()
            } catch {
                // The window may have been closed while the devices were being created.
                if let window, window.isVisible {
                    NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
                } else {
                    NSAlert(error: error).runModal()
                }
            }
        }
        updateForwardButton()
    }

    @objc private func cancel(_ sender: Any?) { close() }

    func windowWillClose(_ notification: Notification) { onClose() }
}

#if DEBUG
@MainActor
private final class PreviewDeviceCatalog: DeviceBrowserSource {
    static let populated = PreviewDeviceCatalog(devices: [
        device("phone", "iPhone 17 Pro", runtime: "iOS 27.0", state: 3),
        device("tablet", "iPad Pro 13-inch", runtime: "iOS 27.0", state: 1),
        device("older", "iPhone 16", runtime: "iOS 26.5", state: 1),
    ])
    static let empty = PreviewDeviceCatalog(devices: [])
    private static func device(_ id: String, _ name: String, runtime: String, state: UInt) -> AvailableDevice {
        AvailableDevice(identifier: id, name: name, descriptiveName: "\(runtime) - \(name)",
                        runtimeIdentifier: runtime, runtimeName: runtime,
                        productFamily: name.hasPrefix("iPad") ? 2 : 1, deviceTypeName: name, state: state)
    }
    var devices: [AvailableDevice]
    init(devices: [AvailableDevice]) { self.devices = devices }
    func availableSimulatorDevices() -> [AvailableDevice] { devices }
    func openSimulator(withIdentifier identifier: String) async throws {
        devices = devices.map {
            var device = $0
            if device.id == identifier { device.state = 3 }
            return device
        }
    }
}

#Preview("Simulators") {
    DeviceBrowserView(model: DeviceBrowserModel(source: PreviewDeviceCatalog.populated))
        .frame(width: 540, height: 560)
}

#Preview("No Simulators") {
    DeviceBrowserView(model: DeviceBrowserModel(source: PreviewDeviceCatalog.empty))
        .frame(width: 540, height: 440)
}
#endif
