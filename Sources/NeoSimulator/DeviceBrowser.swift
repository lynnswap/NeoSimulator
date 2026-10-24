import AppKit
import Observation
import SwiftUI

/// A simulator belongs to one device set; a UDID alone is not a session key.
struct SimulatorDeviceIdentifier: Hashable, Codable, Sendable, Comparable {
    let identifier: String
    let deviceSetPath: String?
    init(_ identifier: String, deviceSetPath: String? = nil) {
        self.identifier = identifier
        self.deviceSetPath = deviceSetPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
    }
    var queryItems: [URLQueryItem] {
        [URLQueryItem(name: "udid", value: identifier)]
            + (deviceSetPath.map { [URLQueryItem(name: "deviceSetPath", value: $0)] } ?? [])
    }
    var preferenceIdentifier: String {
        guard let path = deviceSetPath else { return identifier }
        return "set:\(path.utf8.count):\(path):\(identifier)"
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.preferenceIdentifier < rhs.preferenceIdentifier }
}

struct AvailableDevice: Identifiable {
    let identifier: String
    let deviceSetPath: String?
    var identity: SimulatorDeviceIdentifier { SimulatorDeviceIdentifier(identifier, deviceSetPath: deviceSetPath) }
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
         runtimeName: String, productFamily: Int, deviceTypeName: String, state: UInt, deviceSetPath: String? = nil) {
        self.identifier = identifier
        self.deviceSetPath = deviceSetPath
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
    func openSimulator(withIdentifier identifier: SimulatorDeviceIdentifier) async throws
}

@MainActor @Observable
final class DeviceBrowserModel {
    private weak var source: (any DeviceBrowserSource)?
    private(set) var devices: [AvailableDevice] = []
    private(set) var opening: Set<SimulatorDeviceIdentifier> = []
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
        guard let source, device.canOpen, opening.insert(device.identity).inserted else { return nil }
        return Task {
            defer { opening.remove(device.identity); refresh() }
            do { try await source.openSimulator(withIdentifier: device.identity) }
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
                            ForEach(devices.filter { $0.runtimeName == runtime }, id: \.identity) { device in
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
