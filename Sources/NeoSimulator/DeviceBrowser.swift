import AppKit
import Observation
import SwiftUI

struct AvailableDevice: Identifiable {
    let identifier: String
    let name: String
    let descriptiveName: String
    let runtimeIdentifier: String
    let runtimeName: String
    var state: UInt
    var id: String { identifier }
    var isBooted: Bool { state == 3 }
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
         runtimeName: String, state: UInt) {
        self.identifier = identifier
        self.name = name
        self.descriptiveName = descriptiveName
        self.runtimeIdentifier = runtimeIdentifier
        self.runtimeName = runtimeName
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
                ContentUnavailableView("No iOS Simulators", systemImage: "iphone",
                    description: Text("Install an iOS runtime and create a simulator in Xcode, then refresh."))
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
                                    Image(systemName: device.name.localizedCaseInsensitiveContains("iPad") ? "ipad" : "iphone")
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
            Text("Closing a device window keeps its simulator running.")
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
@MainActor
final class NewSimulatorWindowController: NSWindowController, NSWindowDelegate {
    typealias Create = @MainActor (_ name: String, _ deviceType: String, _ runtime: String) async throws -> Void

    let nameField = NSTextField()
    let deviceTypes = NSPopUpButton()
    let runtimes = NSPopUpButton()
    let createButton = NSButton(title: "Create", target: nil, action: nil)
    private let catalog: SimulatorCatalog
    private let create: Create
    private let onClose: () -> Void
    private var creation: Task<Void, Never>?

    init(catalog: SimulatorCatalog, create: @escaping Create, onClose: @escaping () -> Void = {}) {
        self.catalog = catalog
        self.create = create
        self.onClose = onClose
        let window = NSWindow(contentRect: NSRect(x: 196, y: 240, width: 618, height: 258),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "New Simulator"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        fillMenus()
    }

    required init?(coder: NSCoder) { nil }

    private func makeContent() -> NSView {
        func label(_ title: String) -> NSTextField {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            return label
        }
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        deviceTypes.target = self
        deviceTypes.action = #selector(deviceTypeChanged(_:))
        runtimes.target = self
        runtimes.action = #selector(runtimeChanged(_:))
        let grid = NSGridView(views: [
            [label("Simulator Name:"), nameField],
            [label("Device Type:"), deviceTypes],
            [label("OS Version:"), runtimes],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        createButton.target = self
        createButton.action = #selector(createSimulator(_:))
        let heading = NSTextField(labelWithString: "Create a new simulator:")
        let content = NSView()
        for view in [heading, grid, cancel, createButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 20),
            grid.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            cancel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            createButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            createButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
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
            let none = NSMenuItem(title: "No Runtimes Available", action: nil, keyEquivalent: "")
            none.isEnabled = false
            runtimes.menu?.addItem(none)
            for control in [runtimes, deviceTypes, createButton] as [NSControl] { control.isEnabled = false }
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

    private func item(_ title: String, representing identifier: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = identifier
        return item
    }

    private var deviceType: String? { deviceTypes.selectedItem?.representedObject as? String }
    private var runtime: String? { runtimes.selectedItem?.representedObject as? String }

    @objc private func deviceTypeChanged(_ sender: Any?) {
        if let deviceType, let runtime, !catalog.runtime(runtime, supports: deviceType) {
            select(in: runtimes) { catalog.runtime($0, supports: deviceType) }
        }
        nameField.placeholderString = deviceTypes.selectedItem?.title
    }

    @objc private func runtimeChanged(_ sender: Any?) {
        if let deviceType, let runtime, !catalog.runtime(runtime, supports: deviceType) {
            select(in: deviceTypes) { catalog.runtime(runtime, supports: $0) }
        }
        nameField.placeholderString = deviceTypes.selectedItem?.title
    }

    /// Selects the first item whose identifier matches, or nothing.
    private func select(in popUp: NSPopUpButton, where matches: (String) -> Bool) {
        popUp.select(popUp.itemArray.first { ($0.representedObject as? String).map(matches) == true })
    }

    @objc private func createSimulator(_ sender: Any?) {
        guard creation == nil, let deviceType, let runtime else { return }
        let name = nameField.stringValue.isEmpty ? nameField.placeholderString ?? "" : nameField.stringValue
        createButton.isEnabled = false
        creation = Task {
            defer {
                creation = nil
                createButton.isEnabled = true
            }
            do {
                try await create(name, deviceType, runtime)
                close()
            } catch {
                // The window may have been closed while the device was being created.
                if let window, window.isVisible {
                    NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
                } else {
                    NSAlert(error: error).runModal()
                }
            }
        }
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
                        runtimeIdentifier: runtime, runtimeName: runtime, state: state)
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
