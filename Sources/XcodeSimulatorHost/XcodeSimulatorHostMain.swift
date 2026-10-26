import Foundation
import Darwin
import OSLog

public struct SimulatorXcode: Sendable, Equatable {
    public let url: URL
    public let version: String
    public let name: String
}

public struct SimulatorCreationContext: Sendable {
    public let xcodeURL: URL
    public let data: Data
}

/// The simulator address and backend selected before presenting its screen.
public struct SimulatorPresentationContext: Sendable {
    public let deviceID: DeviceInventoryID
    public let xcodeURL: URL
}

public struct SimulatorHostStatus: Sendable {
    /// The app's saved display choice. Reading status does not validate Xcode's live preferences.
    public let host: SimulatorHost
    public let restorationAvailable: Bool
    public let rendererRunning: Bool
}

public struct SimulatorHostDevice: Sendable, Equatable {
    public let identifier: String
    public let name: String
    public let descriptiveName: String
    public let runtimeIdentifier: String
    public let runtimeName: String
    public let productFamily: String
    public let state: String
    public let ownerXcodeURL: URL?
    public let deviceSetPath: String?
    public let modelIdentifier: String?
    public let isAvailable: Bool
    public let lastUsedAt: Date?
    public let capabilities: Set<String>
    public let pairIdentifiers: Set<String>

    public init(identifier: String, name: String, descriptiveName: String, runtimeIdentifier: String, runtimeName: String, productFamily: String, state: String, ownerXcodeURL: URL? = nil, deviceSetPath: String? = nil, modelIdentifier: String? = nil, isAvailable: Bool = true, lastUsedAt: Date? = nil, capabilities: Set<String> = [], pairIdentifiers: Set<String> = []) {
        self.identifier = identifier
        self.name = name
        self.descriptiveName = descriptiveName
        self.runtimeIdentifier = runtimeIdentifier
        self.runtimeName = runtimeName
        self.productFamily = productFamily
        self.state = state
        self.ownerXcodeURL = ownerXcodeURL
        self.deviceSetPath = deviceSetPath
        self.modelIdentifier = modelIdentifier
        self.isAvailable = isAvailable
        self.lastUsedAt = lastUsedAt
        self.capabilities = capabilities
        self.pairIdentifiers = pairIdentifiers
    }
}

public struct SimulatorHostFailure: Error, LocalizedError, Sendable {
    public enum Kind: Sendable, Equatable { case preferencesChanged, unavailableXcode, launchFailed, partialSuccess, operationFailed }
    public let kind: Kind
    public let technicalDetails: String
    public let failureReason: String?
    private let underlyingRecoverySuggestion: String?

    public var errorDescription: String? {
        switch kind {
        case .preferencesChanged: "Xcode’s simulator settings changed outside NeoSimulator."
        case .unavailableXcode: "Xcode cannot be used with NeoSimulator."
        case .launchFailed: "The simulator display could not be opened."
        case .partialSuccess: "Simulator settings changed, but the display could not be opened."
        case .operationFailed: "The simulator operation could not be completed."
        }
    }
    public var recoverySuggestion: String? {
        if let underlyingRecoverySuggestion { return underlyingRecoverySuggestion }
        return switch kind {
        case .preferencesChanged: "Review your Xcode settings. To use the saved values, choose Restore Original Settings…, then Restore Saved Values…."
        case .unavailableXcode: "Open Xcode 27 or later and finish installing its developer tools, then try again."
        case .launchFailed: "Try View Screen again, or select the display app in Settings."
        case .partialSuccess: "Try View Screen again, or select the display app in Settings."
        case .operationFailed: "Try again and review the diagnostic details if the problem continues."
        }
    }
    init(_ error: any Error) {
        failureReason = (error as? any LocalizedError)?.failureReason
        underlyingRecoverySuggestion = (error as? any LocalizedError)?.recoverySuggestion
        let identifier = (error as? CLIError)?.identifier ?? ""
        technicalDetails = identifier.isEmpty ? error.localizedDescription : "\(identifier): \(error.localizedDescription)"
        if ["preference-conflict", "ambiguous-intermediate"].contains(identifier) || identifier.hasSuffix("-host-invalidated") {
            kind = .preferencesChanged
        } else if identifier.hasSuffix("-partial-success") {
            kind = .partialSuccess
        } else if identifier == "unsupported-xcode" || identifier == "xcode-bundle" {
            kind = .unavailableXcode
        } else if identifier.contains("launch") || identifier.contains("runtime") || identifier.contains("startup") {
            kind = .launchFailed
        } else {
            kind = .operationFailed
        }
    }
}

struct RendererRegistration: Codable, Sendable {
    let processIdentifier: Int32
    let applicationPath: String
    let xcodePath: String
    let sessionIdentifier: String
    let deviceIdentifiers: [DeviceInventoryID]
    let ownerProcessIdentifier: Int32?
    let ownerLaunchDate: Date?

    init(processIdentifier: Int32, applicationPath: String, xcodePath: String, sessionIdentifier: String,
         deviceIdentifiers: [DeviceInventoryID], ownerProcessIdentifier: Int32? = nil, ownerLaunchDate: Date? = nil) {
        self.processIdentifier = processIdentifier
        self.applicationPath = applicationPath
        self.xcodePath = xcodePath
        self.sessionIdentifier = sessionIdentifier
        self.deviceIdentifiers = deviceIdentifiers
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.ownerLaunchDate = ownerLaunchDate
    }

    func isOwned(by owner: RendererOwnerIdentity) -> Bool {
        ownerProcessIdentifier == owner.processIdentifier && ownerLaunchDate == owner.launchDate
    }
}

/// Serializes preference transactions while each Xcode owns a separate renderer process.
public actor SimulatorHostController {
    let rendererApplicationURL: URL
    private let presentSimulator: (@MainActor @Sendable (SimulatorPresentationContext) async throws -> Void)?
    private let catalogLogger = Logger(subsystem: "dev.lynnswap.NeoSimulator", category: "Catalog")
    private var lastTestingCatalogDiagnostic: String?
    private let startedAt = Date().timeIntervalSince1970
    private let connectionTracker = XcodeConnectionTracker()
    private let bootTracker = SimulatorBootTracker()
    private var startupHandled = false
    private var startupDeviceIdentifier: DeviceInventoryID?
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    var shutdownTransactions: [SimulatorShutdownTransaction] = []

    public init(rendererApplicationURL: URL,
                presentSimulator: (@MainActor @Sendable (SimulatorPresentationContext) async throws -> Void)? = nil) {
        self.rendererApplicationURL = rendererApplicationURL.resolvingSymlinksInPath().standardizedFileURL
        self.presentSimulator = presentSimulator
    }

    public func status() async throws -> SimulatorHostStatus {
        try await operation {
            let selection = try await self.hostSelectionStatus()
            return SimulatorHostStatus(
                host: selection.host,
                restorationAvailable: selection.restorationAvailable,
                rendererRunning: try await !self.registeredRenderers().isEmpty
            )
        }
    }

    public func installedXcodes() async throws -> [SimulatorXcode] {
        try await operation {
            try await self.availableXcodes().map {
                SimulatorXcode(url: $0.applicationURL, version: $0.version.description, name: $0.applicationURL.deletingPathExtension().lastPathComponent)
            }
        }
    }

    public func creationCatalog() async throws -> SimulatorCreationContext {
        try await operation { try await self.readCreationCatalog() }
    }

    @concurrent
    private func readCreationCatalog() async throws -> SimulatorCreationContext {
        guard let bundle = Bundle(url: rendererApplicationURL), bundle.bundleIdentifier == ToolConstants.neoHostBundleIdentifier,
              let executable = bundle.executableURL else {
            throw CLIError.unavailable("neo-host-bundle", "The embedded simulator display could not be found.")
        }
        var candidates: [XcodeInstallation] = []
        if let selected = try? makeInspector().selectedXcode() { candidates.append(selected) }
        candidates.append(contentsOf: try await availableXcodes())
        var seen = Set<URL>()
        var firstFailure: (any Error)?
        for xcode in candidates where seen.insert(xcode.applicationURL).inserted {
            do {
                let output = try SystemCommandRunner().run(executable: executable, arguments: ["--creation-catalog", "--xcode", xcode.applicationURL.path])
                guard output.terminationStatus == 0 else { throw CLIError.unavailable("creation-catalog", output.stderrText) }
                return SimulatorCreationContext(xcodeURL: xcode.applicationURL, data: output.stdout)
            } catch {
                if firstFailure == nil { firstFailure = error }
                catalogLogger.warning("Simulator creation catalog unavailable for \(xcode.applicationURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if let firstFailure { throw firstFailure }
        throw CLIError.unavailable("creation-catalog", "No compatible simulator creation catalog is available.")
    }

    public func createSimulator(named name: String, deviceType: String, runtime: String, context: SimulatorCreationContext) async throws -> String {
        try await operation {
            let xcode = try await self.resolveXcode(context.xcodeURL)
            let output = try await self.runSimctl(xcode: xcode, arguments: ["create", name, deviceType, runtime])
            return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public func pairSimulators(watch: String, phone: String, context: SimulatorCreationContext) async throws {
        try await operation {
            let xcode = try await self.resolveXcode(context.xcodeURL)
            _ = try await self.runSimctl(xcode: xcode, arguments: ["pair", watch, phone])
        }
    }

    public func selectHost(_ host: SimulatorHost, xcodeURL: URL? = nil) async throws {
        try await operation { try await self.select(host, xcodeURL: xcodeURL) }
    }

    public func activate(xcodeURL: URL? = nil) async throws {
        try await operation {
            if try await self.hostSelectionStatus().host == .deviceHub {
                let xcode = try await self.resolveXcode(xcodeURL)
                let workspace = await WorkspaceClient.live
                _ = try await workspace.openDeviceHub(xcode.deviceHubApplicationURL)
                return
            }
            let xcode = try await self.resolveXcode(xcodeURL)
            if let renderer = try await self.registeredRenderers().first(where: { self.sameURL(URL(fileURLWithPath: $0.xcodePath), xcode.applicationURL) }) {
                self.send("activate", to: renderer)
            } else {
                try await self.launchHost(.neo, xcodeURL: xcode.applicationURL)
                if let renderer = try await self.registeredRenderers().first(where: { self.sameURL(URL(fileURLWithPath: $0.xcodePath), xcode.applicationURL) }) {
                    self.send("show-browser", to: renderer)
                }
            }
        }
    }

    public func restore(force: Bool = false) async throws {
        try await operation {
            try await self.restoreHost(force: force)
            self.startupHandled = true
            self.startupDeviceIdentifier = nil
        }
    }

    public func devices(xcodeURL: URL? = nil) async throws -> [SimulatorHostDevice] {
        try await operation {
            let catalogs: [SimulatorHostDevice]
            if let xcodeURL {
                catalogs = try await self.deviceCatalog(xcode: self.resolveXcode(xcodeURL))
            } else {
                catalogs = try await self.availableCatalogs().flatMap(\.devices)
            }
            let catalog = Dictionary(grouping: catalogs, by: \.inventoryID).values.compactMap(\.first).sorted { $0.descriptiveName.localizedStandardCompare($1.descriptiveName) == .orderedAscending }
            let renderers = try await self.registeredRenderers()
            return catalog.map { device in
                device.inventoryCopy(owners: renderers)
            }
        }
    }

    /// Opens a simulator in the default device set. Use its inventory ID for another set.
    public func openDevice(identifier: String, xcodeURL: URL? = nil) async throws {
        try await openDevice(.simulator(udid: identifier, deviceSetPath: nil), xcodeURL: xcodeURL)
    }

    /// Opens or brings forward the exact simulator, retaining its owning Xcode and device set.
    public func openDevice(_ deviceID: DeviceInventoryID, xcodeURL: URL? = nil) async throws {
        _ = try deviceID.simulatorAddress
        try await operation {
            // An explicit request supersedes the saved startup selection.
            self.startupHandled = true
            self.startupDeviceIdentifier = nil
            try await self.openDeviceBody(deviceID: deviceID, xcodeURL: xcodeURL)
        }
    }

    private func openDeviceBody(deviceID: DeviceInventoryID, xcodeURL: URL?, bootIfNeeded: Bool = true,
                                catalogs: [(xcode: XcodeInstallation, devices: [SimulatorHostDevice])] = []) async throws {
        let (identifier, _) = try deviceID.simulatorAddress
        let selection = try await self.hostSelectionStatus()
        let renderers = try await self.registeredRenderers()
        if selection.host == .neo,
           let owner = renderers.first(where: { $0.deviceIdentifiers.contains(deviceID) }) {
            if let xcodeURL, !sameURL(xcodeURL, URL(fileURLWithPath: owner.xcodePath)) {
                let (xcode, _) = try await resolveDevice(deviceID: deviceID, preferredURL: xcodeURL, catalogs: catalogs)
                try await RendererDeviceRequestWaiter().release(deviceID, from: owner)
                try await openRendererDevice(deviceID, xcode: xcode, bootIfNeeded: bootIfNeeded)
            } else {
                if bootIfNeeded { try await RendererDeviceRequestWaiter().open(deviceID, in: owner) }
                else { try await RendererDeviceRequestWaiter().attach(deviceID, in: owner) }
                try await self.present(deviceID, xcodeURL: URL(fileURLWithPath: owner.xcodePath))
            }
            return
        }
        let (xcode, device) = try await resolveDevice(deviceID: deviceID, preferredURL: xcodeURL, catalogs: catalogs)
        if selection.host == .neo {
            try await self.openRendererDevice(deviceID, xcode: xcode, bootIfNeeded: bootIfNeeded)
        } else {
            if bootIfNeeded && device.state == "Shutdown" { _ = try await self.runSimctl(xcode: xcode, arguments: ["boot", identifier], deviceSetPath: device.deviceSetPath) }
            try await launchHost(.deviceHub, xcodeURL: xcode.applicationURL)
        }
    }

    private func openRendererDevice(_ deviceID: DeviceInventoryID, xcode: XcodeInstallation, bootIfNeeded: Bool = true) async throws {
        let launchesRenderer = try await !registeredRenderers().contains(where: { sameURL(URL(fileURLWithPath: $0.xcodePath), xcode.applicationURL) })
        if launchesRenderer { try await launchHost(.neo, xcodeURL: xcode.applicationURL) }
        guard let target = try await registeredRenderers().first(where: { sameURL(URL(fileURLWithPath: $0.xcodePath), xcode.applicationURL) }) else {
            throw CLIError.temporary("renderer-startup", "The simulator display exited before opening the device.")
        }
        do {
            if bootIfNeeded { try await RendererDeviceRequestWaiter().open(deviceID, in: target) }
            else { try await RendererDeviceRequestWaiter().attach(deviceID, in: target) }
            try await self.present(deviceID, xcodeURL: xcode.applicationURL)
        } catch {
            throw CLIError.temporary(launchesRenderer ? "neo-host-launch-partial-success" : "renderer-device-launch", error.localizedDescription)
        }
    }

    private func present(_ deviceID: DeviceInventoryID, xcodeURL: URL) async throws {
        guard let presentSimulator else { return }
        try await presentSimulator(SimulatorPresentationContext(deviceID: deviceID, xcodeURL: xcodeURL))
    }

    /// Closes the presentation's backend ownership, optionally leaving the guest running.
    public func closeDevice(_ deviceID: DeviceInventoryID, keepingDeviceRunning: Bool) async throws {
        _ = try deviceID.simulatorAddress
        try await operation {
            guard let owner = try await self.registeredRenderers().first(where: { $0.deviceIdentifiers.contains(deviceID) }) else { return }
            try await RendererDeviceRequestWaiter().close(deviceID, in: owner, keepingDeviceRunning: keepingDeviceRunning)
        }
    }

    /// Associates devices with the Xcode that launched their current simulator app processes.
    /// Attaching a debugger to an already running process does not change its launch environment.
    public func synchronizeXcodeConnections() async throws -> Bool {
        try await operation {
            var catalogs = try await self.availableCatalogs()
            let catalog = catalogs.flatMap(\.devices)
            let selection = try await self.hostSelectionStatus()
            guard selection.allowsAutomaticHosting else {
                let observation = self.bootTracker.observe(catalog, attachInitially: false, allowsAttachments: false)
                self.startupHandled = true
                self.startupDeviceIdentifier = nil
                return observation.catalogChanged
            }
            let rendererDefaults = UserDefaults(suiteName: ToolConstants.neoHostBundleIdentifier)
            let managerDefaults = ToolConstants.managerDefaults
            let attachInitially = rendererDefaults?.object(forKey: "AttachBootedOnStart") as? Bool
                ?? managerDefaults?.object(forKey: "AttachBootedOnStart") as? Bool ?? true
            var changed = false
            var firstFailure: (any Error)?
            do {
                changed = try await self.connectionTracker.synchronize(
                    observations: try await Self.readProcessConnections(),
                    runningDeviceIdentifiers: Set(catalog.filter { $0.state == "Booted" }.map(\.inventoryID)),
                    testingDeviceSetPath: SimulatorDeviceSets.testingPath()
                ) { connection in
                    if !attachInitially && connection.event.startTime < self.startedAt { return }
                    let index = catalogs.firstIndex(where: { self.sameURL($0.xcode.applicationURL, connection.xcodeURL) })
                    let xcode: XcodeInstallation
                    if let index { xcode = catalogs[index].xcode }
                    else { xcode = try await self.resolveXcode(connection.xcodeURL) }
                    let devices = try await Self.connectionCatalog(for: connection.deviceID, cachedDevices: index.map { catalogs[$0].devices }) {
                        try await self.deviceCatalog(xcode: xcode)
                    }
                    if let index { catalogs[index] = (xcode, devices) }
                    else { catalogs.append((xcode, devices)) }
                    guard devices.contains(where: { $0.inventoryID == connection.deviceID && $0.state == "Booted" }) else { return }
                    let renderers = try await self.registeredRenderers()
                    if let owner = renderers.first(where: { $0.deviceIdentifiers.contains(connection.deviceID) }) {
                        if self.sameURL(URL(fileURLWithPath: owner.xcodePath), xcode.applicationURL) { return }
                        try await RendererDeviceRequestWaiter().release(connection.deviceID, from: owner)
                    }
                    try await self.openRendererDevice(connection.deviceID, xcode: xcode, bootIfNeeded: false)
                }
            } catch { firstFailure = error }
            let observation = self.bootTracker.observe(catalog, attachInitially: attachInitially)
            changed = changed || observation.catalogChanged
            let candidates = observation.devicesToAttach
            let ownedIdentifiers = Set(try await self.registeredRenderers().flatMap(\.deviceIdentifiers))
            for deviceID in candidates {
                if self.connectionTracker.hasPendingConnection(forDevice: deviceID) { continue }
                do {
                    if !ownedIdentifiers.contains(deviceID) { try await self.openDeviceBody(deviceID: deviceID, xcodeURL: nil, bootIfNeeded: false, catalogs: catalogs) }
                    self.bootTracker.didAttach(deviceID)
                    changed = true
                } catch { if firstFailure == nil { firstFailure = error } }
            }
            if !self.startupHandled {
                self.startupHandled = true
                func savedBoolean(_ key: String) -> Bool {
                    rendererDefaults?.object(forKey: key) as? Bool ?? managerDefaults?.object(forKey: key) as? Bool ?? true
                }
                let savedDefaults = rendererDefaults?.string(forKey: "CurrentDeviceUDID") != nil ? rendererDefaults : managerDefaults
                let current = savedDefaults?.string(forKey: "CurrentDeviceUDID").map {
                    DeviceInventoryID.simulator(udid: $0, deviceSetPath: savedDefaults?.string(forKey: "CurrentDeviceSetPath"))
                }
                self.startupDeviceIdentifier = SimulatorStartupSelection.device(
                    in: catalog, attachInitially: attachInitially,
                    startsSession: savedBoolean("SessionOnLaunch"), startsLastDevice: savedBoolean("StartLastDeviceOnLaunch"),
                    current: current, hasOwnedDevices: !ownedIdentifiers.isEmpty
                )?.inventoryID
            }
            if let identifier = self.startupDeviceIdentifier {
                do {
                    try await self.openDeviceBody(deviceID: identifier, xcodeURL: nil, catalogs: catalogs)
                    self.startupDeviceIdentifier = nil
                    changed = true
                } catch { if firstFailure == nil { firstFailure = error } }
            }
            if let firstFailure { throw firstFailure }
            return changed
        }
    }

    /// Invalidates testing-device attachments after a visibility change, including changes between catalog polls.
    public func testingDeviceVisibilityDidChange() async throws {
        try await operation { self.bootTracker.forgetTestingDevices() }
    }

    public func quitRenderer(keepingDevicesRunning: Bool? = nil) async throws {
        try await operation {
            let workspace = await WorkspaceClient.live
            _ = try await workspace.quitNeoHost(self.rendererApplicationURL, self.registeredRenderers(), keepingDevicesRunning)
        }
    }

    private func select(_ host: SimulatorHost, xcodeURL: URL?) async throws {
        let xcode = try await resolveXcode(xcodeURL)
        let renderers = try await registeredRenderers()
        let previousHost = try await hostSelectionStatus().host
        if host == .deviceHub || previousHost == .deviceHub { bootTracker.reset() }
        let existing = xcodeURL == nil ? renderers.first : renderers.first { sameURL(URL(fileURLWithPath: $0.xcodePath), xcode.applicationURL) }
        try await useHost(host, xcodeURL: xcode.applicationURL, launchNeoHost: existing == nil)
        if host == .neo {
            if let existing { send("activate", to: existing) }
            else if let launched = try await registeredRenderers().first(where: { sameURL(URL(fileURLWithPath: $0.xcodePath), xcode.applicationURL) }) { send("show-browser", to: launched) }
        }
    }

    @concurrent
    func registeredRenderers() async throws -> [RendererRegistration] {
        let workspace = await WorkspaceClient.live
        let applications = (await workspace.runningNeoHosts()).filter {
            $0.bundleURL.map({ sameURL($0, rendererApplicationURL) }) == true
        }
        guard !applications.isEmpty else { return [] }
        let owner = try await RendererOwnerIdentity.current()
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NeoSimulator/renderers", isDirectory: true)
        var registrations: [RendererRegistration] = []
        for application in applications {
            let url = directory.appendingPathComponent("\(application.processIdentifier).json")
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch CocoaError.fileReadNoSuchFile { continue }
            let registration = try JSONDecoder().decode(RendererRegistration.self, from: data)
            guard registration.processIdentifier == application.processIdentifier,
                  sameURL(URL(fileURLWithPath: registration.applicationPath), rendererApplicationURL) else {
                throw CLIError.configuration("renderer-registration", "The renderer registration does not match its running application.")
            }
            if registration.isOwned(by: owner) { registrations.append(registration) }
        }
        return registrations
    }

    private func send(_ action: String, to renderer: RendererRegistration) {
        let info = ["action": action]
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("dev.lynnswap.NeoSimulator.RendererRequest"), object: renderer.sessionIdentifier,
            userInfo: info, deliverImmediately: true
        )
    }

    nonisolated private func sameURL(_ lhs: URL, _ rhs: URL) -> Bool { lhs.resolvingSymlinksInPath().standardizedFileURL.path == rhs.resolvingSymlinksInPath().standardizedFileURL.path }
    nonisolated private func makeInspector() -> InstallationInspector {
        InstallationInspector(runner: SystemCommandRunner(), rendererApplicationURL: rendererApplicationURL)
    }
    @concurrent
    private func availableXcodes() async throws -> [XcodeInstallation] {
        try Self.discoverXcodes(rendererApplicationURL: rendererApplicationURL)
    }

    nonisolated static func discoverXcodes(rendererApplicationURL: URL) throws -> [XcodeInstallation] {
        let inspector = InstallationInspector(runner: SystemCommandRunner(), rendererApplicationURL: rendererApplicationURL)
        var urls = Set<URL>()
        if let selected = try? inspector.selectedXcode() { urls.insert(selected.applicationURL) }
        for root in [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
            let entries: [URL]
            do { entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) }
            catch CocoaError.fileReadNoSuchFile { continue }
            for entry in entries where entry.pathExtension == "app" {
                if let xcode = try? inspector.xcode(at: entry) { urls.insert(xcode.applicationURL) }
            }
        }
        let discovered: [XcodeInstallation] = try urls.map { try inspector.xcode(at: $0) }
        let installations = discovered.sorted { lhs, rhs in
            if lhs.version == rhs.version { return lhs.applicationURL.path < rhs.applicationURL.path }
            return rhs.version < lhs.version
        }
        guard !installations.isEmpty else { throw CLIError.unavailable("unsupported-xcode", "Install Xcode 27 or later and finish installing its developer tools.") }
        return installations
    }

    @concurrent
    private func resolveXcode(_ url: URL?) async throws -> XcodeInstallation {
        if let url { return try makeInspector().xcode(at: url) }
        if let selected = try? makeInspector().selectedXcode() { return selected }
        return try await availableXcodes()[0]
    }

    nonisolated(nonsending) static func connectionCatalog(for deviceID: DeviceInventoryID, cachedDevices: [SimulatorHostDevice]?,
                                  readCatalog: () async throws -> [SimulatorHostDevice]) async throws -> [SimulatorHostDevice] {
        if let cachedDevices, cachedDevices.contains(where: { $0.inventoryID == deviceID && $0.state == "Booted" }) {
            return cachedDevices
        }
        // Xcodes are polled sequentially, so another catalog may observe a boot that this snapshot predates.
        return try await readCatalog()
    }

    private func availableCatalogs() async throws -> [(xcode: XcodeInstallation, devices: [SimulatorHostDevice])] {
        var catalogs: [(xcode: XcodeInstallation, devices: [SimulatorHostDevice])] = []
        var firstFailure: (any Error)?
        for xcode in try await availableXcodes() {
            do { catalogs.append((xcode, try await deviceCatalog(xcode: xcode))) }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        if catalogs.isEmpty, let firstFailure { throw firstFailure }
        return catalogs
    }

    /// Resolves developer tools without requiring a user-visible Xcode selection.
    public func xcodeURL(forDevice identifier: String) async throws -> URL {
        try await xcodeURL(forDevice: .simulator(udid: identifier, deviceSetPath: nil))
    }

    public func xcodeURL(forDevice deviceID: DeviceInventoryID) async throws -> URL {
        _ = try deviceID.simulatorAddress
        return try await operation {
            if let owner = try await self.registeredRenderers().first(where: { $0.deviceIdentifiers.contains(deviceID) }) {
                return URL(fileURLWithPath: owner.xcodePath, isDirectory: true)
            }
            return try await self.resolveDevice(deviceID: deviceID, preferredURL: nil).xcode.applicationURL
        }
    }

    // Settings reads remain available while a renderer command waits for a screen.
    func settingsDevice(_ deviceID: DeviceInventoryID) async throws -> (SimulatorHostDevice, URL) {
        _ = try deviceID.simulatorAddress
        let owner = try await registeredRenderers().first { $0.deviceIdentifiers.contains(deviceID) }
        let preferredURL = owner.map { URL(fileURLWithPath: $0.xcodePath) }
        let (xcode, device) = try await resolveDevice(deviceID: deviceID, preferredURL: preferredURL)
        return (device, xcode.applicationURL)
    }

    func deviceManagementContext(for original: SimulatorHostDevice, requiresRenderer: Bool) async throws -> DeviceManagementContext {
        let owner = try await registeredRenderers().first { $0.deviceIdentifiers.contains(original.inventoryID) }
        let candidates: [XcodeInstallation]
        if let owner { candidates = [try await resolveXcode(URL(fileURLWithPath: owner.xcodePath))] }
        else { candidates = try await availableXcodes() }
        let selected = try await Self.managementDevice(for: original, xcodeURLs: candidates.map(\.applicationURL),
            readCatalog: Self.readManagementCatalog)
        return DeviceManagementContext(device: selected.device, xcodeURL: selected.xcodeURL, renderer: requiresRenderer ? owner : nil)
    }

    static func managementDevice(for original: SimulatorHostDevice, xcodeURLs: [URL],
                                 readCatalog: @Sendable (URL, String?) async throws -> [SimulatorHostDevice]) async throws
        -> (device: SimulatorHostDevice, xcodeURL: URL) {
        var unavailable: (device: SimulatorHostDevice, xcodeURL: URL)?
        var firstFailure: (any Error)?
        for xcodeURL in xcodeURLs {
            do {
                let current = try await readCatalog(xcodeURL, original.deviceSetPath)
                guard let device = current.first(where: { $0.identifier == original.identifier }) else { continue }
                if device.isAvailable { return (device, xcodeURL) }
                if unavailable == nil { unavailable = (device, xcodeURL) }
            } catch { if firstFailure == nil { firstFailure = error } }
        }
        if let unavailable { return unavailable }
        if let firstFailure { throw firstFailure }
        throw CLIError.unavailable("simulator-device", "The selected simulator is no longer available.")
    }

    @concurrent
    private static func readManagementCatalog(xcodeURL: URL, path: String?) async throws -> [SimulatorHostDevice] {
        let output = try SystemCommandRunner().runSimctl(xcodeURL: xcodeURL, arguments: ["list", "--json"], deviceSetPath: path)
        guard output.terminationStatus == 0 else { throw CLIError.io("simulator-management", output.stderrText) }
        return try SimulatorDeviceCatalog.decode(output.stdout, deviceSetPath: path, includeUnavailable: true)
    }

    private func resolveDevice(deviceID: DeviceInventoryID, preferredURL: URL?,
                               catalogs: [(xcode: XcodeInstallation, devices: [SimulatorHostDevice])] = []) async throws
        -> (xcode: XcodeInstallation, device: SimulatorHostDevice) {
        let candidates: [XcodeInstallation]
        if let preferredURL { candidates = [try await resolveXcode(preferredURL)] }
        else {
            let source = connectionTracker.xcodeURL(forDevice: deviceID)
            candidates = try await deviceXcodeCandidates(source: source)
        }
        var seen = Set<URL>()
        var firstFailure: (any Error)?
        var readAnyCatalog = false
        for candidate in candidates where seen.insert(candidate.applicationURL).inserted {
            do {
                let devices: [SimulatorHostDevice]
                if let known = catalogs.first(where: { sameURL($0.xcode.applicationURL, candidate.applicationURL) }) {
                    devices = known.devices
                } else {
                    devices = try await deviceCatalog(xcode: candidate)
                }
                readAnyCatalog = true
                if let device = devices.first(where: { $0.inventoryID == deviceID }) { return (candidate, device) }
            } catch { if firstFailure == nil { firstFailure = error } }
        }
        if !readAnyCatalog, let firstFailure { throw firstFailure }
        throw CLIError.unavailable("simulator-device", "The selected simulator is no longer available.")
    }

    @concurrent
    private func deviceXcodeCandidates(source: URL?) async throws -> [XcodeInstallation] {
        var candidates: [XcodeInstallation] = []
        if let source, let installation = try? makeInspector().xcode(at: source) { candidates.append(installation) }
        if let selected = try? makeInspector().selectedXcode() { candidates.append(selected) }
        candidates.append(contentsOf: try await availableXcodes())
        return candidates
    }

    nonisolated private func makeCore(workspace: WorkspaceClient) throws -> HostModeController {
        HostModeController(defaultsStore: DefaultsStore(), receiptStore: try ReceiptStore(),
                           installationInspector: makeInspector(), workspace: workspace)
    }

    @concurrent
    private func hostSelectionStatus() async throws -> SimulatorHostSelectionStatus {
        let workspace = await WorkspaceClient.live(headlessRenderers: presentSimulator != nil)
        return try makeCore(workspace: workspace).selectionStatus()
    }

    @concurrent
    private func launchHost(_ host: SimulatorHost, xcodeURL: URL) async throws {
        let workspace = await WorkspaceClient.live(headlessRenderers: presentSimulator != nil)
        try await makeCore(workspace: workspace).launch(host, xcodeURL: xcodeURL)
    }

    @concurrent
    private func useHost(_ host: SimulatorHost, xcodeURL: URL, launchNeoHost: Bool) async throws {
        let workspace = await WorkspaceClient.live(headlessRenderers: presentSimulator != nil)
        _ = try await makeCore(workspace: workspace).use(host, xcodeURL: xcodeURL, launchNeoHost: launchNeoHost)
    }

    @concurrent
    private func restoreHost(force: Bool) async throws {
        let workspace = await WorkspaceClient.live(headlessRenderers: presentSimulator != nil)
        _ = try await makeCore(workspace: workspace).restore(force: force)
    }

    @concurrent
    private static func readProcessConnections() async throws -> [XcodeSimulatorConnection] {
        try SimulatorProcessConnections.read()
    }
    func operation<T>(_ body: () async throws -> T) async throws -> T {
        if operationInProgress { await withCheckedContinuation { operationWaiters.append($0) } }
        else { operationInProgress = true }
        defer {
            if operationWaiters.isEmpty { operationInProgress = false }
            else { operationWaiters.removeFirst().resume() }
        }
        do { return try await body() }
        catch let error as SimulatorHostFailure { throw error }
        catch { throw SimulatorHostFailure(error) }
    }
    @concurrent
    private func runSimctl(xcode: XcodeInstallation, arguments: [String], deviceSetPath: String? = nil) async throws -> Data {
        let output = try SystemCommandRunner().runSimctl(xcodeURL: xcode.applicationURL, arguments: arguments, deviceSetPath: deviceSetPath)
        guard output.terminationStatus == 0 else { throw CLIError.io("simctl", output.stderrText) }
        return output.stdout
    }

    private struct CatalogResult: Sendable {
        var devices: [SimulatorHostDevice]
        var testingDiagnostic: String?
    }

    private func deviceCatalog(xcode: XcodeInstallation) async throws -> [SimulatorHostDevice] {
        let result = try await readDeviceCatalog(xcode: xcode)
        if let detail = result.testingDiagnostic, lastTestingCatalogDiagnostic != detail {
            catalogLogger.error("Parallel testing devices are unavailable; normal devices remain available. \(detail, privacy: .public)")
        }
        lastTestingCatalogDiagnostic = result.testingDiagnostic
        return result.devices
    }

    @concurrent
    private func readDeviceCatalog(xcode: XcodeInstallation) async throws -> CatalogResult {
        let output = try await runSimctl(xcode: xcode, arguments: ["list", "--json"])
        let devices = try SimulatorDeviceCatalog.decode(output)
        guard let path = SimulatorDeviceSets.testingPath(), FileManager.default.fileExists(atPath: path) else {
            return CatalogResult(devices: devices)
        }
        var diagnostic: String?
        let combined = SimulatorDeviceCatalog.appendingTestingDevices(to: devices, readTesting: {
            let output = try SystemCommandRunner().runSimctl(xcodeURL: xcode.applicationURL, arguments: ["list", "--json"], deviceSetPath: path)
            guard output.terminationStatus == 0 else { throw CLIError.io("simctl", output.stderrText) }
            return try SimulatorDeviceCatalog.decode(output.stdout, deviceSetPath: path)
        }, onFailure: { error in
            diagnostic = "\(path): \(error.localizedDescription)"
        })
        return CatalogResult(devices: combined, testingDiagnostic: diagnostic)
    }
}
enum SimulatorDeviceCatalog {
    private struct Catalog: Decodable {
        struct Runtime: Decodable {
            let identifier: String
            let name: String
            let isAvailable: Bool
        }
        struct Device: Decodable {
            let udid: String
            let deviceTypeIdentifier: String
            let name: String
            let state: String
            let isAvailable: Bool
            let lastUsedAt: String?
        }
        struct DeviceType: Decodable {
            let identifier: String
            let productFamily: String
            let modelIdentifier: String?
        }
        let devicetypes: [DeviceType]
        let runtimes: [Runtime]
        let devices: [String: [Device]]
        struct Pair: Decodable {
            struct Member: Decodable { let udid: String }
            let watch: Member
            let phone: Member
        }
        let pairs: [String: Pair]?
    }

    static func appendingTestingDevices(
        to devices: [SimulatorHostDevice], readTesting: () throws -> [SimulatorHostDevice], onFailure: (any Error) -> Void
    ) -> [SimulatorHostDevice] {
        do { return devices + (try readTesting()) }
        catch { onFailure(error); return devices }
    }

    static func decode(_ data: Data, deviceSetPath: String? = nil, includeUnavailable: Bool = false) throws -> [SimulatorHostDevice] {
        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        let supportedFamilies: Set<String> = ["iPhone", "iPad", "Apple TV", "Apple Watch", "Apple Vision"]
        let supportedTypes = Dictionary(uniqueKeysWithValues: catalog.devicetypes.filter { supportedFamilies.contains($0.productFamily) }.map { ($0.identifier, $0) })
        // Multiple installed builds can share a runtime identifier.
        let runtimes = Dictionary(catalog.runtimes.map { ($0.identifier, $0) }, uniquingKeysWith: { first, next in
            !first.isAvailable && next.isAvailable ? next : first
        })
        return catalog.devices.flatMap { runtimeIdentifier, devices in
            let runtime = runtimes[runtimeIdentifier]
            return devices.compactMap { device -> SimulatorHostDevice? in
                let available = device.isAvailable && runtime?.isAvailable == true
                let type = supportedTypes[device.deviceTypeIdentifier]
                guard includeUnavailable || (available && type != nil) else { return nil }
                let runtimeName = runtime?.name ?? runtimeIdentifier
                let lastUsedAt = device.lastUsedAt.flatMap { value in
                    (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
                        ?? (try? Date.ISO8601FormatStyle().parse(value))
                }
                return SimulatorHostDevice(
                    identifier: device.udid,
                    name: device.name,
                    descriptiveName: "\(device.name) — \(runtimeName)",
                    runtimeIdentifier: runtimeIdentifier,
                    runtimeName: runtimeName,
                    productFamily: type?.productFamily ?? "",
                    state: device.state,
                    deviceSetPath: deviceSetPath,
                    modelIdentifier: type?.modelIdentifier,
                    isAvailable: available,
                    lastUsedAt: lastUsedAt,
                    pairIdentifiers: Set((catalog.pairs ?? [:]).compactMap { pairID, pair in
                        pair.watch.udid == device.udid || pair.phone.udid == device.udid ? pairID : nil
                    })
                )
            }
        }.sorted {
            let order = $0.runtimeName.compare($1.runtimeName, options: .numeric)
            return order == .orderedSame
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : order == .orderedDescending
        }
    }
}

struct XcodeSimulatorConnection: Sendable, Equatable {
    struct Event: Sendable, Hashable, Comparable {
        let processIdentifier: Int32
        let startSeconds: UInt64
        let startMicroseconds: UInt64
        var startTime: TimeInterval { TimeInterval(startSeconds) + TimeInterval(startMicroseconds) / 1_000_000 }
        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds < rhs.startSeconds }
            if lhs.startMicroseconds != rhs.startMicroseconds { return lhs.startMicroseconds < rhs.startMicroseconds }
            return lhs.processIdentifier < rhs.processIdentifier
        }
    }
    let event: Event
    let deviceIdentifier: String
    var deviceID: DeviceInventoryID { .simulator(udid: deviceIdentifier, deviceSetPath: deviceSetPath) }
    let xcodeURL: URL
    let deviceSetPath: String?

    init(event: Event, deviceIdentifier: String, xcodeURL: URL, deviceSetPath: String? = nil) {
        self.event = event
        self.deviceIdentifier = deviceIdentifier
        self.xcodeURL = xcodeURL
        self.deviceSetPath = deviceSetPath
    }
}

final class XcodeConnectionTracker {
    private var latestHandled: [DeviceInventoryID: XcodeSimulatorConnection.Event] = [:]
    private var latestObserved: [DeviceInventoryID: XcodeSimulatorConnection] = [:]

    func xcodeURL(forDevice identifier: DeviceInventoryID) -> URL? { latestObserved[identifier]?.xcodeURL }
    func hasPendingConnection(forDevice identifier: DeviceInventoryID) -> Bool {
        guard let observed = latestObserved[identifier] else { return false }
        return latestHandled[identifier].map { $0 < observed.event } ?? true
    }

    nonisolated(nonsending) func synchronize(
        observations: [XcodeSimulatorConnection],
        runningDeviceIdentifiers: Set<DeviceInventoryID>,
        testingDeviceSetPath: String? = nil,
        transfer: (XcodeSimulatorConnection) async throws -> Void
    ) async throws -> Bool {
        for (identifier, connection) in latestObserved where connection.deviceSetPath != nil && connection.deviceSetPath != testingDeviceSetPath {
            latestObserved.removeValue(forKey: identifier)
            latestHandled.removeValue(forKey: identifier)
        }
        // A stopped device cancels a failed handoff, even if its originating app already exited.
        for (identifier, connection) in latestObserved where !runningDeviceIdentifiers.contains(identifier) {
            latestHandled[identifier] = connection.event
        }
        for connection in observations where runningDeviceIdentifiers.contains(connection.deviceID)
            && (connection.deviceSetPath == nil || connection.deviceSetPath == testingDeviceSetPath) {
            if let previous = latestObserved[connection.deviceID], previous.event >= connection.event { continue }
            latestObserved[connection.deviceID] = connection
        }
        var changed = false
        var firstFailure: (any Error)?
        for connection in latestObserved.values.sorted(by: { $0.event < $1.event }) {
            if let latest = latestHandled[connection.deviceID], latest >= connection.event { continue }
            do {
                try await transfer(connection)
                latestHandled[connection.deviceID] = connection.event
                changed = true
            } catch {
                if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
        return changed
    }
}

enum SimulatorProcessConnections {
    static func read() throws -> [XcodeSimulatorConnection] {
        let testingDeviceSetPath = SimulatorDeviceSets.testingPath()
        let capacity = Int(proc_listallpids(nil, 0)) + 128
        guard capacity > 128 else { throw CLIError.io("process-list", "Could not enumerate simulator application processes.") }
        var processes = [pid_t](repeating: 0, count: capacity)
        let count = processes.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count >= 0 else { throw CLIError.io("process-list", "Could not enumerate simulator application processes.") }
        var result: [XcodeSimulatorConnection] = []
        for pid in processes.prefix(Int(count)) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let executable = String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            guard executable.contains("/data/Containers/Bundle/Application/") else { continue }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  info.pbi_uid == getuid() else { continue }
            var query = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            guard sysctl(&query, UInt32(query.count), nil, &size, nil, 0) == 0, size > 4 else { continue }
            var data = Data(count: size)
            let status = data.withUnsafeMutableBytes { sysctl(&query, UInt32(query.count), $0.baseAddress, &size, nil, 0) }
            guard status == 0 else { continue } // Processes can exit while the snapshot is being read.
            data.count = size
            var current = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &current, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  current.pbi_start_tvsec == info.pbi_start_tvsec, current.pbi_start_tvusec == info.pbi_start_tvusec else { continue }
            if let connection = decode(data, executablePath: executable, event: .init(processIdentifier: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec), testingDeviceSetPath: testingDeviceSetPath) {
                result.append(connection)
            }
        }
        return result
    }

    static func decode(_ arguments: Data, executablePath: String, event: XcodeSimulatorConnection.Event, testingDeviceSetPath: String? = nil) -> XcodeSimulatorConnection? {
        guard arguments.count >= MemoryLayout<Int32>.size else { return nil }
        let argumentCount = arguments.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argumentCount >= 0 else { return nil }
        var cursor = 4
        func nextString() -> String? {
            guard cursor < arguments.count, let end = arguments[cursor...].firstIndex(of: 0) else { return nil }
            defer { cursor = end + 1 }
            return String(data: arguments[cursor..<end], encoding: .utf8)
        }
        guard nextString() != nil else { return nil } // executable path precedes argv, padded with NULs.
        while cursor < arguments.count, arguments[cursor] == 0 { cursor += 1 }
        for _ in 0..<argumentCount { guard nextString() != nil else { return nil } }
        var environment: [String: String] = [:]
        let relevant: Set<String> = ["SIMULATOR_UDID", "GPUTOOLS_XCODE_DEVELOPER_PATH", "DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH"]
        while let entry = nextString(), !entry.isEmpty {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<equals])
            if relevant.contains(key) { environment[key] = String(entry[entry.index(after: equals)...]) }
        }
        guard let rawIdentifier = environment["SIMULATOR_UDID"], let identifier = UUID(uuidString: rawIdentifier)?.uuidString else { return nil }
        let defaultDevice = executablePath.contains("/CoreSimulator/Devices/\(identifier)/data/Containers/Bundle/Application/")
        let testingDevice = testingDeviceSetPath.map { path in
            URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().path.hasPrefix(
                URL(fileURLWithPath: path).resolvingSymlinksInPath().appendingPathComponent("\(identifier)/data/Containers/Bundle/Application").path + "/"
            )
        } ?? false
        guard defaultDevice || testingDevice else { return nil }
        var candidates = Set<String>()
        for key in ["GPUTOOLS_XCODE_DEVELOPER_PATH", "DYLD_FRAMEWORK_PATH", "DYLD_LIBRARY_PATH"] {
            for path in (environment[key] ?? "").split(separator: ":") {
                guard let developer = path.range(of: ".app/Contents/Developer"),
                      key == "GPUTOOLS_XCODE_DEVELOPER_PATH" || path.contains("/Contents/Developer/Platforms/") else { continue }
                candidates.insert(String(path[..<developer.lowerBound]) + ".app")
            }
        }
        guard candidates.count == 1, let path = candidates.first, path.hasPrefix("/") else { return nil }
        return XcodeSimulatorConnection(event: event, deviceIdentifier: identifier, xcodeURL: URL(fileURLWithPath: path, isDirectory: true), deviceSetPath: testingDevice ? testingDeviceSetPath : nil)
    }
}

final class SimulatorBootTracker {
    struct Observation {
        let catalogChanged: Bool
        let devicesToAttach: [DeviceInventoryID]
    }

    private var catalog: [DeviceInventoryID: SimulatorHostDevice] = [:]
    private var pending: Set<DeviceInventoryID> = []
    private var initialized = false

    func reset() { pending = []; initialized = false }
    func didAttach(_ identifier: DeviceInventoryID) { pending.remove(identifier) }
    func forgetTestingDevices() {
        let identifiers = Set(catalog.filter { $0.value.deviceSetPath != nil }.keys)
        catalog = catalog.filter { $0.value.deviceSetPath == nil }
        pending.subtract(identifiers)
    }

    func observe(_ devices: [SimulatorHostDevice], attachInitially: Bool, allowsAttachments: Bool = true) -> Observation {
        let current = Dictionary(devices.map { ($0.inventoryID, $0) }, uniquingKeysWith: { first, _ in first })
        let changed = current != catalog
        defer { catalog = current }
        guard allowsAttachments else {
            reset()
            return Observation(catalogChanged: changed, devicesToAttach: [])
        }
        let booted = Set(current.filter { $0.value.state == "Booted" }.keys)
        pending.formIntersection(booted)
        for identifier in booted {
            if initialized {
                if catalog[identifier]?.state != "Booted" { pending.insert(identifier) }
            } else if attachInitially { pending.insert(identifier) }
        }
        initialized = true
        return Observation(catalogChanged: changed, devicesToAttach: pending.sorted { $0.sortKey < $1.sortKey })
    }
}

enum SimulatorStartupSelection {
    static func device(in devices: [SimulatorHostDevice], attachInitially: Bool, startsSession: Bool, startsLastDevice: Bool, current: DeviceInventoryID?, hasOwnedDevices: Bool) -> SimulatorHostDevice? {
        guard startsSession, startsLastDevice, !hasOwnedDevices,
              !(attachInitially && devices.contains(where: { $0.state == "Booted" })) else { return nil }
        if case .simulator(let savedIdentifier, let path)? = current,
           let identifier = UUID(uuidString: savedIdentifier),
           let chosen = devices.first(where: { $0.deviceSetPath == path && UUID(uuidString: $0.identifier) == identifier }) { return chosen }
        return devices.last(where: { $0.productFamily == "iPhone" }) ?? devices.first
    }
}

enum SimulatorDeviceSets {
    static func testingPath() -> String? {
        let renderer = UserDefaults(suiteName: ToolConstants.neoHostBundleIdentifier)
        let manager = ToolConstants.managerDefaults
        return testingPath(showTesting: renderer?.object(forKey: "ShowTestingDevices") as? Bool ?? manager?.object(forKey: "ShowTestingDevices") as? Bool ?? true,
                           customPath: renderer?.string(forKey: "TestingDeviceSetPath") ?? manager?.string(forKey: "TestingDeviceSetPath"))
    }

    static func testingPath(showTesting: Bool, customPath: String?, homeURL: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        guard showTesting else { return nil }
        let path = customPath.map { NSString(string: $0).expandingTildeInPath }
            ?? homeURL.appendingPathComponent("Library/Developer/XCTestDevices").path
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard url != homeURL.appendingPathComponent("Library/Developer/CoreSimulator/Devices").resolvingSymlinksInPath().standardizedFileURL else { return nil }
        return url.path
    }
}
