import NeoSimulatorKit
@_spi(NeoSimulator) import XcodeSimulatorHost
import AppKit
import Observation
import SwiftUI

@MainActor
package protocol DeviceBrowserSource: AnyObject {
    func availableSimulatorDevices() throws -> [AvailableDevice]
    func openSimulator(withIdentifier identifier: SimulatorDeviceIdentifier) async throws
}

@MainActor @Observable
package final class DeviceBrowserModel {
    private weak var source: (any DeviceBrowserSource)?
    package private(set) var devices: [AvailableDevice] = []
    package private(set) var opening: Set<SimulatorDeviceIdentifier> = []
    package var errorMessage: String?
    package var search = "" {
        didSet { if search != oldValue { updateSections() } }
    }
    package struct RuntimeSection: Identifiable {
        package let id: String
        package let devices: [AvailableDevice]
    }
    package private(set) var sections: [RuntimeSection] = []
    package var showsError: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }

    private func updateSections() {
        let matching = devices.filter {
            search.isEmpty || $0.name.localizedStandardContains(search)
                || $0.runtimeName.localizedStandardContains(search)
        }
        sections = Dictionary(grouping: matching, by: \.runtimeName)
            .map { RuntimeSection(id: $0.key, devices: $0.value) }
            .sorted { $0.id.compare($1.id, options: .numeric) == .orderedDescending }
    }

    package init(source: any DeviceBrowserSource) {
        self.source = source
        refresh()
    }

    package func refresh() {
        do {
            devices = try source?.availableSimulatorDevices().sorted {
            let runtimeOrder = $0.runtimeName.compare($1.runtimeName, options: .numeric)
            return runtimeOrder == .orderedSame
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : runtimeOrder == .orderedDescending
            } ?? []
            updateSections()
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    package func open(_ device: AvailableDevice) -> Task<Void, Never>? {
        guard let source, device.canOpen, opening.insert(device.identity).inserted else { return nil }
        return Task {
            defer { opening.remove(device.identity); refresh() }
            do { try await source.openSimulator(withIdentifier: device.identity) }
            catch is CancellationError {}
            catch { errorMessage = error.localizedDescription }
        }
    }
}

package struct DeviceBrowserView: View {
    @Bindable package var model: DeviceBrowserModel
    package var body: some View {
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
                TextField("Search devices or runtimes", text: $model.search)
                    .textFieldStyle(.plain)
                if !model.search.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") { model.search = "" }
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
            } else if model.sections.isEmpty {
                ContentUnavailableView.search(text: model.search)
            } else {
                List {
                    ForEach(model.sections) { section in
                        Section(section.id) {
                            ForEach(section.devices, id: \.identity) { device in
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
                                    if model.opening.contains(device.identity) {
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
        .alert("Could Not Open Simulator", isPresented: $model.showsError) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

@MainActor
package final class DeviceBrowserWindowController: NSWindowController {
    private let model: DeviceBrowserModel

    package init(source: any DeviceBrowserSource) {
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

    package required init?(coder: NSCoder) { nil }

    package func refresh() { model.refresh() }
    package func report(_ error: Error) { model.errorMessage = error.localizedDescription }

    package func show() {
        refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
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
    func openSimulator(withIdentifier identifier: SimulatorDeviceIdentifier) async throws {
        devices = devices.map {
            var device = $0
            if device.identity == identifier { device.state = 3 }
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
