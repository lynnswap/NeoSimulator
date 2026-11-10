import NeoSimulatorDeviceIO
import NeoSimulatorKit
import Foundation
import Darwin
import OSLog
import Synchronization

package struct SimulatorXcode: Sendable, Equatable {
    package let url: URL
    package let version: String
    package let name: String
}

/// The catalog and destination selected for a simulator creation session.
package struct SimulatorCreationContext: Sendable {
    package let xcodeURL: URL
    package let data: Data
    /// A custom simulator set, or `nil` for the default set. Creation and pairing retain this destination.
    package let deviceSetPath: String?

    package init(xcodeURL: URL, data: Data, deviceSetPath: String? = nil) {
        self.xcodeURL = xcodeURL
        self.data = data
        self.deviceSetPath = deviceSetPath
    }
}

/// The simulator address and backend selected before presenting its screen.
package struct SimulatorPresentationContext: Sendable {
    /// Distinguishes a user request from an open screen moving to the Xcode that launched its simulator's app.
    package enum Purpose: Sendable { case requested, automatic }

    package let deviceID: DeviceInventoryID
    package let xcodeURL: URL
    package let purpose: Purpose
}

package struct SimulatorHostStatus: Sendable {
    /// The display host available in this app session.
    package let host: SimulatorHost
    /// The display app explicitly selected for this manager session.
    package let preferredHost: SimulatorHost
    package let restorationAvailable: Bool
    package let rendererRunning: Bool

    package init(
        host: SimulatorHost, preferredHost: SimulatorHost = .neo,
        restorationAvailable: Bool, rendererRunning: Bool
    ) {
        self.host = host
        self.preferredHost = preferredHost
        self.restorationAvailable = restorationAvailable
        self.rendererRunning = rendererRunning
    }
}

package struct RendererRegistration: Codable, Sendable {
    package static var directoryURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NeoSimulator/renderers", isDirectory: true)
    }

    package let processIdentifier: Int32
    package let applicationPath: String
    package let xcodePath: String
    package let sessionIdentifier: String
    package let deviceIdentifiers: [DeviceInventoryID]
    package let ownerProcessIdentifier: Int32?
    package let ownerLaunchDate: Date?

    package init(processIdentifier: Int32, applicationPath: String, xcodePath: String, sessionIdentifier: String,
         deviceIdentifiers: [DeviceInventoryID], ownerProcessIdentifier: Int32? = nil, ownerLaunchDate: Date? = nil) {
        self.processIdentifier = processIdentifier
        self.applicationPath = applicationPath
        self.xcodePath = xcodePath
        self.sessionIdentifier = sessionIdentifier
        self.deviceIdentifiers = deviceIdentifiers
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.ownerLaunchDate = ownerLaunchDate
    }

    package func isOwned(by owner: RendererOwnerIdentity) -> Bool {
        ownerProcessIdentifier == owner.processIdentifier && ownerLaunchDate == owner.launchDate
    }
}

/// An accepted screen-open intent, including the time it spends waiting in the manager queue.
package final class SimulatorScreenOpenRequest: Sendable {
    package let deviceID: DeviceInventoryID
    fileprivate let identifier = UUID()
    fileprivate let cancellationIdentity: UUID?
    private let cancelled = Mutex(false)
    private let onCancel: @Sendable () -> Void

    package convenience init(deviceID: DeviceInventoryID, onCancel: @escaping @Sendable () -> Void) {
        self.init(deviceID: deviceID, cancellationIdentity: nil, onCancel: onCancel)
    }

    fileprivate init(deviceID: DeviceInventoryID, cancellationIdentity: UUID?, onCancel: @escaping @Sendable () -> Void) {
        self.deviceID = deviceID
        self.cancellationIdentity = cancellationIdentity
        self.onCancel = onCancel
    }

    package func cancel() {
        let first = cancelled.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
        if first { onCancel() }
    }

    fileprivate var isCancelled: Bool { cancelled.withLock { $0 } }
}

private final class ScreenOpenCancellations: Sendable {
    private struct Cancellation {
        let identity: UUID
        let instant: TimeInterval
    }
    private struct Active {
        let request: SimulatorScreenOpenRequest
        let task: Task<Void, any Error>
    }
    private struct State {
        var latest: [DeviceInventoryID: Cancellation] = [:]
        var active: [UUID: Active] = [:]
    }
    private let state = Mutex(State())

    func request(for deviceID: DeviceInventoryID) -> SimulatorScreenOpenRequest {
        let cancellationIdentity = state.withLock { $0.latest[deviceID]?.identity }
        return SimulatorScreenOpenRequest(deviceID: deviceID, cancellationIdentity: cancellationIdentity) {
            self.cancel(deviceID)
        }
    }

    private func cancel(_ deviceID: DeviceInventoryID) {
        let tasks = state.withLock { state in
            state.latest[deviceID] = Cancellation(identity: UUID(), instant: Date().timeIntervalSince1970)
            return state.active.values.filter { $0.request.deviceID == deviceID }.map(\.task)
        }
        // A task's cancellation handlers can publish another request. Never invoke them under the lock.
        for task in tasks { task.cancel() }
    }

    func admit(_ request: SimulatorScreenOpenRequest, task: Task<Void, any Error>, processStartedAt: TimeInterval?) -> Bool {
        state.withLock { state in
            let cancellation = state.latest[request.deviceID]
            guard !request.isCancelled, cancellation?.identity == request.cancellationIdentity,
                  processStartedAt.map({ start in cancellation.map { start > $0.instant } ?? true }) ?? true else { return false }
            state.active[request.identifier] = Active(request: request, task: task)
            return true
        }
    }

    func finish(_ request: SimulatorScreenOpenRequest) {
        _ = state.withLock { state in
            state.active.removeValue(forKey: request.identifier)
        }
    }

    func isCancelled(_ connection: XcodeSimulatorConnection) -> Bool {
        state.withLock { state in
            state.latest[connection.deviceID].map { connection.event.startTime <= $0.instant } ?? false
        }
    }
}

package struct ScreenOpenCatalogObservation: Sendable {
    package let catalogs: [(xcode: XcodeInstallation, devices: [SimulatorHostDevice])]
    /// The devices that a change was altering during the read, so that their states may be only steps of it.
    fileprivate let changingDevices: Set<DeviceInventoryID>
    package var devices: [SimulatorHostDevice] { catalogs.flatMap(\.devices) }
}

/// What an operation of ``SimulatorHostController`` concerns, which decides what it follows in accepted order.
package enum HostOperationScope {
    /// A change of the host, its preferences or a renderer's lifetime. Follows all earlier work and holds all later work.
    case hostTransition
    /// Work on these devices. Follows only earlier work on them and earlier host transitions.
    case devices(Set<DeviceInventoryID>)
    /// Reads, and work on no existing device. Follows only earlier host transitions.
    case independent

    fileprivate func conflicts(with other: Self) -> Bool {
        switch (self, other) {
        case (.hostTransition, _), (_, .hostTransition): true
        case (.devices(let first), .devices(let second)): !first.isDisjoint(with: second)
        default: false
        }
    }
}

/// Serializes preference transactions while each Xcode owns a separate renderer process.
package actor SimulatorHostController {
    package let rendererApplicationURL: URL
    private let presentSimulator: (@MainActor @Sendable (SimulatorPresentationContext) async throws -> Void)?
    private let deviceHubCompanions: DeviceHubCompanions?
    private let catalogLogger = Logger(subsystem: "dev.lynnswap.NeoSimulator", category: "Catalog")
    private var lastTestingCatalogDiagnostic: String?
    private let startedAt = Date().timeIntervalSince1970
    private let connectionTracker = XcodeConnectionTracker()
    private let catalogTracker = SimulatorCatalogTracker()
    private nonisolated let screenOpenCancellations = ScreenOpenCancellations()
    /// Every catalog and installation read. Mutations keep their own policies, so stopping these never interrupts one.
    let reads = CommandReads()
    private var preferredHost: SimulatorHost = .neo
    private var allowsSessionHosting = false
    private var awaitingDeviceHubExit = false
    private var screenOpenTasks: [DeviceInventoryID: (id: UUID, task: Task<Void, any Error>)] = [:]
    private var connectionSynchronization: Task<Bool, any Error>?
    private struct AcceptedOperation {
        let id: UUID
        var scope: HostOperationScope
        /// Present while the operation waits for its turn.
        var continuation: CheckedContinuation<Void, any Error>?
    }
    /// Running and waiting operations, in accepted order.
    private var operations: [AcceptedOperation] = []
    /// The devices being changed at some time during each catalog read in progress.
    private var catalogReads: [UUID: Set<DeviceInventoryID>] = [:]
    var shutdownTransactions: [SimulatorShutdownTransaction] = []

    package init(rendererApplicationURL: URL,
        presentSimulator: (@MainActor @Sendable (SimulatorPresentationContext) async throws -> Void)? = nil,
        deviceHubCompanions: DeviceHubCompanions? = nil
    ) {
        self.rendererApplicationURL = rendererApplicationURL.resolvingSymlinksInPath().standardizedFileURL
        self.presentSimulator = presentSimulator
        self.deviceHubCompanions = deviceHubCompanions
    }

    /// Stops the catalog and installation reads running now and refuses new ones until ``resumeReads()``.
    /// An operation that was waiting on one ends as cancelled, or continues if it can without that read.
    package nonisolated func stopReads() { reads.stop() }
    package nonisolated func resumeReads() { reads.resume() }

    /// The operations waiting for their turn.
    package var waitingOperations: Int { operations.count { $0.continuation != nil } }

    package func status() async throws -> SimulatorHostStatus {
        try await operation(.independent) {
            let selection = try await self.hostSessionStatus()
            return SimulatorHostStatus(
                host: self.allowsSessionHosting ? .neo : .deviceHub,
                preferredHost: self.preferredHost,
                restorationAvailable: selection.restorationAvailable,
                rendererRunning: try await !self.registeredRenderers().isEmpty
            )
        }
    }

    /// Registers NeoSimulator on each launch without opening a screen.
    package func beginSession() async throws {
        try await operation(.hostTransition) {
            let xcode = try await self.resolveXcode(nil)
            self.preferredHost = .neo
            try await self.beginHostSession(xcodeURL: xcode.applicationURL)
            self.allowsSessionHosting = true
            self.awaitingDeviceHubExit = false
        }
    }

    /// Releases this session's bridges while leaving the selected routing settings in place.
    package func endSession() async throws {
        await cancelConnectionSynchronization()
        try await operation(.hostTransition) {
            self.awaitingDeviceHubExit = false
            try await self.deviceHubCompanions?.stop()
            self.allowsSessionHosting = false
        }
    }

    package func installedXcodes() async throws -> [SimulatorXcode] {
        try await operation(.independent) {
            try await self.availableXcodes().map {
                SimulatorXcode(url: $0.applicationURL, version: $0.version.description, name: $0.applicationURL.deletingPathExtension().lastPathComponent)
            }
        }
    }

    package func creationCatalog() async throws -> SimulatorCreationContext {
        try await operation(.independent) { try await self.readCreationCatalog() }
    }

    /// Uses the selected simulator's Xcode and device set for companion creation.
    package func creationCatalog(for deviceID: DeviceInventoryID) async throws -> SimulatorCreationContext {
        let address = try deviceID.simulatorAddress
        return try await operation(.independent) {
            let xcodeURL = try await self.resolvedXcodeURL(for: deviceID)
            return try await self.readCreationCatalog(xcodeURL: xcodeURL, deviceSetPath: address.deviceSetPath)
        }
    }

    @concurrent
    private func readCreationCatalog(xcodeURL: URL? = nil, deviceSetPath: String? = nil) async throws -> SimulatorCreationContext {
        guard let bundle = Bundle(url: rendererApplicationURL), bundle.bundleIdentifier == ToolConstants.neoHostBundleIdentifier,
              let executable = bundle.executableURL else {
            throw HostOperationError.unavailable("neo-host-bundle", "The embedded simulator display could not be found.")
        }
        var candidates: [XcodeInstallation] = []
        if let xcodeURL {
            candidates = [try await resolveXcode(xcodeURL)]
        } else {
            if let selected = try await XcodeInstallationInspector(reads: reads).selectedXcodeIfUsable() { candidates.append(selected) }
            candidates.append(contentsOf: try await availableXcodes())
        }
        var seen = Set<URL>()
        var firstFailure: (any Error)?
        for xcode in candidates where seen.insert(xcode.applicationURL).inserted {
            do {
                let output = try await reads.run(SystemCommand(
                    executable: executable, arguments: ["--creation-catalog", "--xcode", xcode.applicationURL.path], policy: .cancellable))
                guard output.terminationStatus == 0 else { throw HostOperationError.unavailable("creation-catalog", output.stderrText) }
                return SimulatorCreationContext(xcodeURL: xcode.applicationURL, data: output.stdout, deviceSetPath: deviceSetPath)
            } catch is CancellationError { throw CancellationError() }
            catch {
                if firstFailure == nil { firstFailure = error }
                catalogLogger.warning("Simulator creation catalog unavailable for \(xcode.applicationURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if let firstFailure { throw firstFailure }
        throw HostOperationError.unavailable("creation-catalog", "No compatible simulator creation catalog is available.")
    }

    package func createSimulator(named name: String, deviceType: String, runtime: String, context: SimulatorCreationContext) async throws -> String {
        try await operation(.independent) {
            let xcode = try await self.resolveXcode(context.xcodeURL)
            let output = try await self.runSimctl(xcode: xcode, arguments: ["create", name, deviceType, runtime], deviceSetPath: context.deviceSetPath)
            return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    package func pairSimulators(watch: String, phone: String, context: SimulatorCreationContext) async throws {
        let devices = Set([watch, phone].map { DeviceInventoryID.simulator(udid: $0, deviceSetPath: context.deviceSetPath) })
        try await operation(.devices(devices)) {
            let xcode = try await self.resolveXcode(context.xcodeURL)
            _ = try await self.runSimctl(xcode: xcode, arguments: ["pair", watch, phone], deviceSetPath: context.deviceSetPath)
        }
    }

    package func openDeviceHub(xcodeURL: URL, requestURL: URL?) async throws {
        await cancelConnectionSynchronization()
        try await operation(.hostTransition) {
            let xcode = try await self.resolveXcode(xcodeURL)
            try await self.handoffToDeviceHub(
                xcode: xcode, requestURL: requestURL, resumesOnExit: self.preferredHost == .neo)
        }
    }

    package func selectHost(_ host: SimulatorHost, xcodeURL: URL? = nil) async throws {
        await cancelConnectionSynchronization()
        try await operation(.hostTransition) {
            let xcode = try await self.resolveXcode(xcodeURL)
            switch host {
            case .neo:
                do { try await self.beginHostSession(xcodeURL: xcode.applicationURL) }
                catch {
                    self.invalidateHostAfterFailedChange(error)
                    throw error
                }
                self.allowsSessionHosting = true
                self.awaitingDeviceHubExit = false
            case .deviceHub:
                try await self.handoffToDeviceHub(xcode: xcode, requestURL: nil, resumesOnExit: false)
            }
            self.preferredHost = host
        }
    }

    private func handoffToDeviceHub(xcode: XcodeInstallation, requestURL: URL?, resumesOnExit: Bool) async throws {
        let wasHosting = self.allowsSessionHosting
        do { try await self.handoffToDeviceHub(xcodeURL: xcode.applicationURL) } catch let handoffError {
            self.invalidateHostAfterFailedChange(handoffError)
            if wasHosting, SimulatorHostFailure(handoffError).kind == .partialSuccess {
                do {
                    try await self.beginHostSession(xcodeURL: xcode.applicationURL)
                    self.allowsSessionHosting = true
                } catch let recoveryError {
                    throw HostOperationError.temporary(
                        "device-hub-handoff-recovery",
                        "Could not open Device Hub (\(handoffError.localizedDescription)) or resume NeoSimulator (\(recoveryError.localizedDescription))."
                    )
                }
            }
            throw handoffError
        }
        self.allowsSessionHosting = false
        self.awaitingDeviceHubExit = resumesOnExit
        if let requestURL {
            try await WorkspaceClient.openDeviceHubRequest(requestURL, at: xcode.deviceHubApplicationURL)
        }
    }

    package func deviceHubDidExit(xcodeURL: URL) async throws {
        try await operation(.hostTransition) {
            guard self.awaitingDeviceHubExit, self.preferredHost == .neo else { return }
            self.awaitingDeviceHubExit = false
            try await self.beginHostSession(xcodeURL: xcodeURL)
            self.allowsSessionHosting = true
        }
    }

    package func activate(xcodeURL: URL? = nil) async throws {
        try await operation(.hostTransition) {
            let xcode = try await self.resolveXcode(xcodeURL)
            if self.preferredHost == .deviceHub {
                try await self.launchDeviceHub(xcode: xcode)
                return
            }
            try await self.ensureNeoSession(xcodeURL: xcode.applicationURL)
            if let renderer = try await self.registeredRenderers().first(where: { self.sameURL(URL(fileURLWithPath: $0.xcodePath), xcode.applicationURL) }) {
                self.send("activate", to: renderer)
            } else {
                try await self.launchNeoHost(xcodeURL: xcode.applicationURL)
                if let renderer = try await self.registeredRenderers().first(where: { self.sameURL(URL(fileURLWithPath: $0.xcodePath), xcode.applicationURL) }) {
                    self.send("show-browser", to: renderer)
                }
            }
        }
    }

    package func restore(force: Bool = false) async throws {
        await cancelConnectionSynchronization()
        try await operation(.hostTransition) {
            do { try await self.restoreHost(force: force) }
            catch {
                self.invalidateHostAfterFailedChange(error)
                throw error
            }
            self.allowsSessionHosting = false
            self.awaitingDeviceHubExit = false
        }
    }

    package func devices(xcodeURL: URL? = nil) async throws -> [SimulatorHostDevice] {
        try await operation(.independent) {
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
    package func openDevice(identifier: String, xcodeURL: URL? = nil) async throws {
        try await openDevice(.simulator(udid: identifier, deviceSetPath: nil), xcodeURL: xcodeURL)
    }

    /// Opens or brings forward the exact simulator, retaining its owning Xcode and device set.
    package func openDevice(_ deviceID: DeviceInventoryID, xcodeURL: URL? = nil) async throws {
        try await openDevice(makeScreenOpenRequest(for: deviceID), xcodeURL: xcodeURL)
    }

        package nonisolated func makeScreenOpenRequest(for deviceID: DeviceInventoryID) -> SimulatorScreenOpenRequest {
        screenOpenCancellations.request(for: deviceID)
    }

    /// Opens the requested simulator's screen. With `bootIfNeeded` false, the request only attaches a running
    /// simulator: it does not start one that stopped before the request reached its host.
        package func openDevice(_ request: SimulatorScreenOpenRequest, xcodeURL: URL? = nil, bootIfNeeded: Bool = true) async throws {
        _ = try request.deviceID.simulatorAddress
        try await screenOpen(request) {
            try await self.openDeviceBody(deviceID: request.deviceID, xcodeURL: xcodeURL, bootIfNeeded: bootIfNeeded,
                                          purpose: .requested)
        }
    }

    package func screenOpen(_ request: SimulatorScreenOpenRequest, processStartedAt: TimeInterval? = nil,
                    operation: @escaping @Sendable () async throws -> Void) async throws {
        try await withTaskCancellationHandler {
            let previous = screenOpenTasks[request.deviceID]?.task
            // Only requests for the same device wait for one another.
            let task = Task {
                _ = await previous?.result
                try await self.performScreenOpen(operation)
            }
            screenOpenTasks[request.deviceID] = (request.identifier, task)
            if !screenOpenCancellations.admit(request, task: task, processStartedAt: processStartedAt) { task.cancel() }
            defer {
                if screenOpenTasks[request.deviceID]?.id == request.identifier {
                    screenOpenTasks.removeValue(forKey: request.deviceID)
                }
                screenOpenCancellations.finish(request)
            }
            try await task.value
        } onCancel: { request.cancel() }
    }

    private func performScreenOpen(_ operation: @Sendable () async throws -> Void) async throws {
        do {
            try Task.checkCancellation()
            try await operation()
            try Task.checkCancellation()
        } catch is CancellationError { throw CancellationError() }
        catch let error as SimulatorHostFailure { throw error }
        catch { throw SimulatorHostFailure(error) }
    }

    package nonisolated func isCancelledScreenConnection(_ connection: XcodeSimulatorConnection) -> Bool {
        screenOpenCancellations.isCancelled(connection)
    }

    private func openDeviceBody(deviceID: DeviceInventoryID, xcodeURL: URL?, bootIfNeeded: Bool = true,
                                catalogs: [(xcode: XcodeInstallation, devices: [SimulatorHostDevice])] = [],
                                purpose: SimulatorPresentationContext.Purpose) async throws {
        let open = try await prepareOpen(of: deviceID) { startingRenderer in
            try Task.checkCancellation()
            let renderers = try await self.registeredRenderers()
            let owner = renderers.first { $0.deviceIdentifiers.contains(deviceID) }
            if self.preferredHost == .neo, self.allowsSessionHosting, let owner,
               xcodeURL.map({ self.sameURL($0, URL(fileURLWithPath: owner.xcodePath)) }) ?? true {
                return {
                    try await Self.openRendererDevice(deviceID, in: owner, bootIfNeeded: bootIfNeeded, launchesRenderer: false) {
                        try await self.present(deviceID, xcodeURL: URL(fileURLWithPath: owner.xcodePath), purpose: purpose)
                    }
                }
            }
            let (xcode, device) = try await self.resolveDevice(
                deviceID: deviceID, preferredURL: xcodeURL, catalogs: catalogs)
            if self.preferredHost == .deviceHub {
                let (identifier, _) = try deviceID.simulatorAddress
                return {
                    try await Self.openDeviceHub(
                        boot: {
                            if bootIfNeeded && device.state == "Shutdown" {
                                let output = try await SystemCommandRunner().runCancellable(
                                    .simctl(
                                        xcodeURL: xcode.applicationURL,
                                        arguments: ["boot", identifier], deviceSetPath: device.deviceSetPath,
                                        policy: .cancellable))
                                guard output.terminationStatus == 0 else {
                                    throw HostOperationError.io("simctl", output.stderrText)
                                }
                            }
                        }, launch: { try await self.launchDeviceHub(xcode: xcode) })
                }
            }
            if !self.allowsSessionHosting {
                guard startingRenderer else { return nil }
                try await self.ensureNeoSession(xcodeURL: xcode.applicationURL)
            }
            guard
                let open = try await self.prepareRendererDevice(
                    deviceID, xcode: xcode, bootIfNeeded: bootIfNeeded, purpose: purpose,
                    startingRenderer: startingRenderer)
            else { return nil }
            return {
                if let owner { try await RendererDeviceRequestWaiter().release(deviceID, from: owner) }
                try Task.checkCancellation()
                try await open()
            }
        }
        try await open?()
    }

    /// Prepares an open in its device's order. An open that needs a new renderer prepares again as a host transition in
    /// the same place, which `prepare` must then complete.
    func prepareOpen(of deviceID: DeviceInventoryID,
                     _ prepare: (_ startingRenderer: Bool) async throws -> (@Sendable () async throws -> Void)?)
        async throws -> (@Sendable () async throws -> Void)? {
        let id = UUID()
        return try await runOperation(id, .devices([deviceID])) {
            if let open = try await prepare(false) { return open }
            try await self.escalateToHostTransition(id)
            return try await prepare(true)
        }
    }

    package nonisolated static func openDeviceHub(
        boot: @Sendable () async throws -> Void,
        launch: @Sendable () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try await boot()
        try Task.checkCancellation()
        try await launch()
        try Task.checkCancellation()
    }

    private func openRendererDevice(_ deviceID: DeviceInventoryID, xcode: XcodeInstallation, bootIfNeeded: Bool = true,
                                    purpose: SimulatorPresentationContext.Purpose) async throws {
        let open = try await prepareOpen(of: deviceID) { startingRenderer in
            try await self.prepareRendererDevice(deviceID, xcode: xcode, bootIfNeeded: bootIfNeeded, purpose: purpose,
                                                 startingRenderer: startingRenderer)
        }
        try await open?()
    }

    /// Called inside an operation; guest boot and screen connection run after it.
    /// Returns nil if the Xcode needs a new renderer and the operation is not `startingRenderer`.
    private func prepareRendererDevice(_ deviceID: DeviceInventoryID, xcode: XcodeInstallation, bootIfNeeded: Bool,
                                       purpose: SimulatorPresentationContext.Purpose,
                                       startingRenderer: Bool) async throws -> (@Sendable () async throws -> Void)? {
        let launchesRenderer = try await !registeredRenderers().contains(where: { sameURL(URL(fileURLWithPath: $0.xcodePath), xcode.applicationURL) })
        try Task.checkCancellation()
        if launchesRenderer {
            guard startingRenderer else { return nil }
            try await launchNeoHost(xcodeURL: xcode.applicationURL)
        }
        guard let target = try await registeredRenderers().first(where: { sameURL(URL(fileURLWithPath: $0.xcodePath), xcode.applicationURL) }) else {
            throw HostOperationError.temporary("renderer-startup", "The simulator display exited before opening the device.")
        }
        return {
            try await Self.openRendererDevice(deviceID, in: target, bootIfNeeded: bootIfNeeded, launchesRenderer: launchesRenderer) {
                try await self.present(deviceID, xcodeURL: xcode.applicationURL, purpose: purpose)
            }
        }
    }

    @MainActor package static func openRendererDevice(_ deviceID: DeviceInventoryID, in target: RendererRegistration, bootIfNeeded: Bool,
                                              launchesRenderer: Bool,
                                              makeWaiter: @escaping @MainActor () -> RendererDeviceRequestWaiter = { RendererDeviceRequestWaiter() },
                                              present: @Sendable () async throws -> Void) async throws {
        let preservesOwnership = target.deviceIdentifiers.contains(deviceID)
        do {
            if bootIfNeeded { try await makeWaiter().open(deviceID, in: target) }
            else { try await makeWaiter().attach(deviceID, in: target) }
            try await present()
        } catch is CancellationError {
            if !preservesOwnership {
                // Cancellation can win after the renderer emitted its original open acknowledgement.
                try await Task { try await makeWaiter().release(deviceID, from: target) }.value
            }
            throw CancellationError()
        } catch {
            throw HostOperationError.temporary(launchesRenderer ? "neo-host-launch-partial-success" : "renderer-device-launch", error.localizedDescription)
        }
    }

    private func present(_ deviceID: DeviceInventoryID, xcodeURL: URL, purpose: SimulatorPresentationContext.Purpose) async throws {
        try Task.checkCancellation()
        guard let presentSimulator else { return }
        try await presentSimulator(SimulatorPresentationContext(deviceID: deviceID, xcodeURL: xcodeURL, purpose: purpose))
    }

    /// Closes the presentation's backend ownership, optionally leaving the guest running.
    package func closeDevice(_ deviceID: DeviceInventoryID, keepingDeviceRunning: Bool) async throws {
        _ = try deviceID.simulatorAddress
        try await operation(.devices([deviceID])) {
            guard let owner = try await self.registeredRenderers().first(where: { $0.deviceIdentifiers.contains(deviceID) }) else { return }
            try await RendererDeviceRequestWaiter().close(deviceID, in: owner, keepingDeviceRunning: keepingDeviceRunning)
        }
    }

    /// Associates devices with the Xcode that launched their current simulator app processes, and moves open screens to
    /// it. Attaching a debugger to an already running process does not change its launch environment.
    /// A simulator without an open screen stays closed, whether it was running at launch or started later: only an
    /// explicit request opens one.
    /// - Returns: Whether the catalog changed or a screen moved.
    package func synchronizeXcodeConnections() async throws -> Bool {
        if let connectionSynchronization { return try await connectionSynchronization.value }
        let task = Task { try await self.synchronizeConnections() }
        connectionSynchronization = task
        defer { connectionSynchronization = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    private func cancelConnectionSynchronization() async {
        guard let task = connectionSynchronization else { return }
        task.cancel()
        _ = await task.result
    }

    private func synchronizeConnections() async throws -> Bool {
        let (observedCatalog, selection) = try await operation(.independent) {
            let catalog = try await self.readScreenOpenCatalog { try await self.availableCatalogs() }
            return (catalog, try await self.hostSessionStatus())
        }
        let catalogChanged = catalogTracker.observe(observedCatalog.devices, changing: observedCatalog.changingDevices)
        guard selection.allowsAutomaticHosting else { return catalogChanged }
        let catalogs = observedCatalog.catalogs
        let moved = try await moveOpenScreens(
            to: try await Self.readProcessConnections(), in: observedCatalog, owners: try await registeredRenderers()
        ) { connection in
            let cached = catalogs.first { self.sameURL($0.xcode.applicationURL, connection.xcodeURL) }
            let xcode = if let cached { cached.xcode } else { try await self.resolveXcode(connection.xcodeURL) }
            let devices = try await Self.connectionCatalog(for: connection.deviceID, cachedDevices: cached?.devices) {
                try await self.deviceCatalog(xcode: xcode)
            }
            guard devices.contains(where: { $0.inventoryID == connection.deviceID && $0.state == "Booted" }) else {
                return
            }
            // The screen may have closed or moved while this waited for the device's earlier opens.
            guard
                let owner = try await self.registeredRenderers().first(where: {
                    $0.deviceIdentifiers.contains(connection.deviceID)
                }),
                !self.sameURL(URL(fileURLWithPath: owner.xcodePath), xcode.applicationURL)
            else { return }
            try await RendererDeviceRequestWaiter().release(connection.deviceID, from: owner)
            try await self.openRendererDevice(
                connection.deviceID, xcode: xcode, bootIfNeeded: false, purpose: .automatic)
        }
        return catalogChanged || moved
    }

    /// Moves each open screen whose simulator runs an app that another Xcode launched, using `move`.
    /// - Parameters:
    ///   - connections: The simulator app processes and the Xcode that launched each.
    ///   - catalog: The devices that the connections' devices must be running in.
    ///   - owners: The renderers and the screens they have open.
    ///   - move: Reopens the connection's device with its Xcode.
    /// - Returns: Whether a connection was new.
    package func moveOpenScreens(
        to connections: [XcodeSimulatorConnection], in catalog: ScreenOpenCatalogObservation,
        owners: [RendererRegistration], move: @escaping @Sendable (XcodeSimulatorConnection) async throws -> Void
    ) async throws -> Bool {
        try await connectionTracker.synchronize(
            observations: connections,
            runningDeviceIdentifiers: Set(catalog.devices.filter { $0.state == "Booted" }.map(\.inventoryID)),
            changingDeviceIdentifiers: catalog.changingDevices,
            testingDeviceSetPath: SimulatorDeviceSets.testingPath(),
            isCancelled: { self.isCancelledScreenConnection($0) }
        ) { connection in
            guard let owner = owners.first(where: { $0.deviceIdentifiers.contains(connection.deviceID) }),
                !self.sameURL(URL(fileURLWithPath: owner.xcodePath), connection.xcodeURL)
            else { return }
            let request = self.makeScreenOpenRequest(for: connection.deviceID)
            try await self.screenOpen(request, processStartedAt: connection.event.startTime) {
                try await move(connection)
            }
        }
    }

    package func readScreenOpenCatalog(
        _ read: @Sendable () async throws -> [(xcode: XcodeInstallation, devices: [SimulatorHostDevice])]
    ) async throws -> ScreenOpenCatalogObservation {
        let id = UUID()
        catalogReads[id] = operations.reduce(into: []) { changing, operation in
            if operation.continuation == nil, case .devices(let devices) = operation.scope { changing.formUnion(devices) }
        }
        defer { catalogReads[id] = nil }
        let catalogs = try await read()
        return ScreenOpenCatalogObservation(catalogs: catalogs, changingDevices: catalogReads[id] ?? [])
    }

    package func quitRenderer(keepingDevicesRunning: Bool? = nil) async throws {
        await cancelConnectionSynchronization()
        try await operation(.hostTransition) {
            let workspace = await WorkspaceClient.live
            _ = try await workspace.quitNeoHost(self.rendererApplicationURL, self.registeredRenderers(), keepingDevicesRunning)
        }
    }

    private func invalidateHostAfterFailedChange(_ error: any Error) {
        switch SimulatorHostFailure(error).kind {
        case .partialSuccess, .preferencesChanged: allowsSessionHosting = false
        default: break
        }
    }

    @concurrent
    package func registeredRenderers() async throws -> [RendererRegistration] {
        let workspace = await WorkspaceClient.live
        let applications = (await workspace.runningNeoHosts()).filter {
            $0.bundleURL.map({ sameURL($0, rendererApplicationURL) }) == true
        }
        guard !applications.isEmpty else { return [] }
        let owner = try await RendererOwnerIdentity.current()
        let directory = RendererRegistration.directoryURL
        var registrations: [RendererRegistration] = []
        for application in applications {
            let url = directory.appendingPathComponent("\(application.processIdentifier).json")
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch CocoaError.fileReadNoSuchFile { continue }
            let registration = try JSONDecoder().decode(RendererRegistration.self, from: data)
            guard registration.processIdentifier == application.processIdentifier,
                  sameURL(URL(fileURLWithPath: registration.applicationPath), rendererApplicationURL) else {
                throw HostOperationError.configuration("renderer-registration", "The renderer registration does not match its running application.")
            }
            if registration.isOwned(by: owner) { registrations.append(registration) }
        }
        return registrations
    }

    private func send(_ action: String, to renderer: RendererRegistration) {
        let info = ["action": action]
        DistributedNotificationCenter.default().postNotificationName(
            RendererRequest.notificationName, object: renderer.sessionIdentifier,
            userInfo: info, deliverImmediately: true
        )
    }

    nonisolated private func sameURL(_ lhs: URL, _ rhs: URL) -> Bool { lhs.resolvingSymlinksInPath().standardizedFileURL.path == rhs.resolvingSymlinksInPath().standardizedFileURL.path }
    nonisolated private func makeInspector() -> InstallationInspector {
        InstallationInspector(runner: reads, xcodes: XcodeInstallationInspector(reads: reads), rendererApplicationURL: rendererApplicationURL)
    }
    @concurrent
    private func availableXcodes() async throws -> [XcodeInstallation] {
        try await XcodeInstallationInspector(reads: reads).discoverXcodes()
    }

    @concurrent
    private func resolveXcode(_ url: URL?) async throws -> XcodeInstallation {
        if let url { return try XcodeInstallationInspector().xcode(at: url) }
        if let selected = try await XcodeInstallationInspector(reads: reads).selectedXcodeIfUsable() { return selected }
        return try await availableXcodes()[0]
    }

    package nonisolated(nonsending) static func connectionCatalog(for deviceID: DeviceInventoryID, cachedDevices: [SimulatorHostDevice]?,
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
            catch is CancellationError { throw CancellationError() }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        if catalogs.isEmpty, let firstFailure { throw firstFailure }
        return catalogs
    }

    /// Resolves developer tools without requiring a user-visible Xcode selection.
    package func xcodeURL(forDevice identifier: String) async throws -> URL {
        try await xcodeURL(forDevice: .simulator(udid: identifier, deviceSetPath: nil))
    }

    package func xcodeURL(forDevice deviceID: DeviceInventoryID) async throws -> URL {
        _ = try deviceID.simulatorAddress
        return try await operation(.independent) { try await self.resolvedXcodeURL(for: deviceID) }
    }

    private func resolvedXcodeURL(for deviceID: DeviceInventoryID) async throws -> URL {
        if let owner = try await registeredRenderers().first(where: { $0.deviceIdentifiers.contains(deviceID) }) {
            return URL(fileURLWithPath: owner.xcodePath, isDirectory: true)
        }
        return try await resolveDevice(deviceID: deviceID, preferredURL: nil).xcode.applicationURL
    }

    // Settings reads remain available while a renderer command waits for a screen.
    package func settingsDevice(_ deviceID: DeviceInventoryID) async throws -> (SimulatorHostDevice, URL) {
        _ = try deviceID.simulatorAddress
        let owner = try await registeredRenderers().first { $0.deviceIdentifiers.contains(deviceID) }
        let preferredURL = owner.map { URL(fileURLWithPath: $0.xcodePath) }
        let (xcode, device) = try await resolveDevice(deviceID: deviceID, preferredURL: preferredURL)
        return (device, xcode.applicationURL)
    }

    package func deviceManagementContext(for original: SimulatorHostDevice, requiresRenderer: Bool) async throws -> DeviceManagementContext {
        let owner = try await registeredRenderers().first { $0.deviceIdentifiers.contains(original.inventoryID) }
        let candidates: [XcodeInstallation]
        if let owner { candidates = [try await resolveXcode(URL(fileURLWithPath: owner.xcodePath))] }
        else { candidates = try await availableXcodes() }
        let selected = try await Self.managementDevice(for: original, xcodeURLs: candidates.map(\.applicationURL),
            readCatalog: { try await self.readManagementCatalog(xcodeURL: $0, path: $1) })
        return DeviceManagementContext(device: selected.device, xcodeURL: selected.xcodeURL, renderer: requiresRenderer ? owner : nil)
    }

    package static func managementDevice(for original: SimulatorHostDevice, xcodeURLs: [URL],
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
            } catch is CancellationError { throw CancellationError() }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        if let unavailable { return unavailable }
        if let firstFailure { throw firstFailure }
        throw HostOperationError.unavailable("simulator-device", "The selected simulator is no longer available.")
    }

    @concurrent
    private func readManagementCatalog(xcodeURL: URL, path: String?) async throws -> [SimulatorHostDevice] {
        try await reads.read {
            try await SimulatorDeviceCatalog.read(xcodeURL: xcodeURL, deviceSetPath: path, includeUnavailable: true)
        }
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
            } catch is CancellationError { throw CancellationError() }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        if !readAnyCatalog, let firstFailure { throw firstFailure }
        throw HostOperationError.unavailable("simulator-device", "The selected simulator is no longer available.")
    }

    @concurrent
    private func deviceXcodeCandidates(source: URL?) async throws -> [XcodeInstallation] {
        var candidates: [XcodeInstallation] = []
        if let source, let installation = try? XcodeInstallationInspector().xcode(at: source) { candidates.append(installation) }
        if let selected = try await XcodeInstallationInspector(reads: reads).selectedXcodeIfUsable() { candidates.append(selected) }
        candidates.append(contentsOf: try await availableXcodes())
        return candidates
    }

    nonisolated private func makeCore(workspace: WorkspaceClient) throws -> HostModeController {
        HostModeController(defaultsStore: DefaultsStore(), receiptStore: try ReceiptStore(),
                           installationInspector: makeInspector(), workspace: workspace)
    }

    @concurrent
    private func readSessionStatus() async throws -> SimulatorSessionStatus {
        let workspace = await WorkspaceClient.live(
            headlessRenderers: presentSimulator != nil, deviceHubCompanions: deviceHubCompanions)
        return try await makeCore(workspace: workspace).sessionStatus()
    }

    private func hostSessionStatus() async throws -> SimulatorSessionStatus {
        let status = try await readSessionStatus()
        return SimulatorSessionStatus(
            restorationAvailable: status.restorationAvailable,
            allowsAutomaticHosting: allowsSessionHosting && status.allowsAutomaticHosting)
    }

    private func ensureNeoSession(xcodeURL: URL) async throws {
        guard !allowsSessionHosting else { return }
        try await beginHostSession(xcodeURL: xcodeURL)
        allowsSessionHosting = true
        awaitingDeviceHubExit = false
    }

    @concurrent
    private func beginHostSession(xcodeURL: URL) async throws {
        let workspace = await WorkspaceClient.live(
            headlessRenderers: presentSimulator != nil, deviceHubCompanions: deviceHubCompanions)
        _ = try await makeCore(workspace: workspace).beginSession(xcodeURL: xcodeURL)
    }

    @concurrent
    private func launchNeoHost(xcodeURL: URL) async throws {
        let workspace = await WorkspaceClient.live(
            headlessRenderers: presentSimulator != nil, deviceHubCompanions: deviceHubCompanions)
        try await makeCore(workspace: workspace).launchNeoHost(xcodeURL: xcodeURL)
    }

    @concurrent
    private func handoffToDeviceHub(xcodeURL: URL) async throws {
        let workspace = await WorkspaceClient.live(
            headlessRenderers: presentSimulator != nil, deviceHubCompanions: deviceHubCompanions)
        _ = try await makeCore(workspace: workspace).use(.deviceHub, xcodeURL: xcodeURL)
    }

    @concurrent
    private func launchDeviceHub(xcode: XcodeInstallation) async throws {
        let workspace = await WorkspaceClient.live(
            headlessRenderers: presentSimulator != nil, deviceHubCompanions: deviceHubCompanions)
        _ = try await workspace.openDeviceHub(xcode)
    }

    @concurrent
    private func restoreHost(force: Bool) async throws {
        let workspace = await WorkspaceClient.live(
            headlessRenderers: presentSimulator != nil, deviceHubCompanions: deviceHubCompanions)
        _ = try await makeCore(workspace: workspace).restore(force: force)
    }

    @concurrent
    private static func readProcessConnections() async throws -> [XcodeSimulatorConnection] {
        try SimulatorProcessConnections.read()
    }
    /// Runs `body` once nothing accepted before it conflicts with `scope`, so that a long change to one device holds only
    /// what concerns that device, and a host transition stays ahead of everything accepted after it.
    package func operation<T>(_ scope: HostOperationScope, _ body: () async throws -> T) async throws -> T {
        try await runOperation(UUID(), scope, body)
    }

    private func runOperation<T>(_ id: UUID, _ scope: HostOperationScope, _ body: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        try await waitForTurn(of: id) { operations.append(AcceptedOperation(id: id, scope: scope, continuation: $0)) }
        defer {
            operations.removeAll { $0.id == id }
            admitOperations()
        }
        do {
            try Task.checkCancellation()
            return try await body()
        } catch is CancellationError { throw CancellationError() }
        catch let error as SimulatorHostFailure { throw error }
        catch { throw SimulatorHostFailure(error) }
    }

    /// Turns a running operation into a waiting host transition in its accepted place. Work accepted before it ends first,
    /// and none of that concerns its devices, or it could not have started. Work accepted after it stays behind it, and
    /// another operation in this state no longer runs, so neither holds the other beyond their order.
    private func escalateToHostTransition(_ id: UUID) async throws {
        try await waitForTurn(of: id) { continuation in
            for index in operations.indices where operations[index].id == id {
                operations[index].scope = .hostTransition
                operations[index].continuation = continuation
            }
        }
    }

    private func waitForTurn(of id: UUID, joining join: (CheckedContinuation<Void, any Error>) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                join(continuation)
                admitOperations()
            }
        } onCancel: {
            Task { await self.cancelOperationWaiter(id) }
        }
    }

    /// Starts every waiter that conflicts with nothing running or waiting ahead of it.
    private func admitOperations() {
        var ahead = operations.filter { $0.continuation == nil }.map(\.scope)
        for index in operations.indices {
            guard let continuation = operations[index].continuation else { continue }
            let scope = operations[index].scope
            defer { ahead.append(scope) }
            guard !ahead.contains(where: { $0.conflicts(with: scope) }) else { continue }
            operations[index].continuation = nil
            if case .devices(let devices) = scope {
                for read in catalogReads.keys { catalogReads[read]?.formUnion(devices) }
            }
            continuation.resume()
        }
    }

    private func cancelOperationWaiter(_ id: UUID) {
        guard let index = operations.firstIndex(where: { $0.id == id }),
              let continuation = operations[index].continuation else { return }
        operations.remove(at: index)
        continuation.resume(throwing: CancellationError())
        admitOperations()
    }
    /// For a change. A catalog read goes through ``readSimulatorCatalog(xcode:deviceSetPath:)`` instead.
    @concurrent
    private func runSimctl(xcode: XcodeInstallation, arguments: [String], deviceSetPath: String? = nil) async throws -> Data {
        let output = try await SystemCommandRunner().run(.simctl(xcodeURL: xcode.applicationURL, arguments: arguments, deviceSetPath: deviceSetPath, policy: .uninterrupted))
        guard output.terminationStatus == 0 else { throw HostOperationError.io("simctl", output.stderrText) }
        return output.stdout
    }

    @concurrent
    private func readSimulatorCatalog(xcode: XcodeInstallation, deviceSetPath: String? = nil) async throws -> [SimulatorHostDevice] {
        try await reads.read {
            try await SimulatorDeviceCatalog.read(xcodeURL: xcode.applicationURL, deviceSetPath: deviceSetPath)
        }
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
        let devices = try await readSimulatorCatalog(xcode: xcode)
        guard let path = SimulatorDeviceSets.testingPath(), FileManager.default.fileExists(atPath: path) else {
            return CatalogResult(devices: devices)
        }
        var diagnostic: String?
        let combined = try await SimulatorDeviceCatalog.appendingTestingDevices(to: devices, readTesting: {
            try await self.readSimulatorCatalog(xcode: xcode, deviceSetPath: path)
        }, onFailure: { error in
            diagnostic = "\(path): \(error.localizedDescription)"
        })
        return CatalogResult(devices: combined, testingDiagnostic: diagnostic)
    }
}

package struct XcodeSimulatorConnection: Sendable, Equatable {
    package struct Event: Sendable, Hashable, Comparable {
        package let processIdentifier: Int32
        package let startSeconds: UInt64
        package let startMicroseconds: UInt64
        package var startTime: TimeInterval { TimeInterval(startSeconds) + TimeInterval(startMicroseconds) / 1_000_000 }
        package static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.startSeconds != rhs.startSeconds { return lhs.startSeconds < rhs.startSeconds }
            if lhs.startMicroseconds != rhs.startMicroseconds { return lhs.startMicroseconds < rhs.startMicroseconds }
            return lhs.processIdentifier < rhs.processIdentifier
        }
    }
    package let event: Event
    package let deviceIdentifier: String
    package var deviceID: DeviceInventoryID { .simulator(udid: deviceIdentifier, deviceSetPath: deviceSetPath) }
    package let xcodeURL: URL
    package let deviceSetPath: String?

    package init(event: Event, deviceIdentifier: String, xcodeURL: URL, deviceSetPath: String? = nil) {
        self.event = event
        self.deviceIdentifier = deviceIdentifier
        self.xcodeURL = xcodeURL
        self.deviceSetPath = deviceSetPath
    }
}

package final class XcodeConnectionTracker {
    private var latestHandled: [DeviceInventoryID: XcodeSimulatorConnection.Event] = [:]
    private var latestObserved: [DeviceInventoryID: XcodeSimulatorConnection] = [:]

    package func xcodeURL(forDevice identifier: DeviceInventoryID) -> URL? { latestObserved[identifier]?.xcodeURL }
    package func hasPendingConnection(forDevice identifier: DeviceInventoryID,
                              isCancelled: (XcodeSimulatorConnection) -> Bool = { _ in false }) -> Bool {
        guard let observed = latestObserved[identifier], !isCancelled(observed) else { return false }
        return latestHandled[identifier].map { $0 < observed.event } ?? true
    }

    package nonisolated(nonsending) func synchronize(
        observations: [XcodeSimulatorConnection],
        runningDeviceIdentifiers: Set<DeviceInventoryID>,
        changingDeviceIdentifiers: Set<DeviceInventoryID> = [],
        testingDeviceSetPath: String? = nil,
        isCancelled: (XcodeSimulatorConnection) -> Bool = { _ in false },
        transfer: (XcodeSimulatorConnection) async throws -> Void
    ) async throws -> Bool {
        for (identifier, connection) in latestObserved where connection.deviceSetPath != nil && connection.deviceSetPath != testingDeviceSetPath {
            latestObserved.removeValue(forKey: identifier)
            latestHandled.removeValue(forKey: identifier)
        }
        // A stopped device cancels a failed handoff, even if its originating app already exited.
        // A device under change is only passing through this state, so the next observation decides it.
        for (identifier, connection) in latestObserved where !runningDeviceIdentifiers.contains(identifier)
            && !changingDeviceIdentifiers.contains(identifier) {
            latestHandled[identifier] = connection.event
        }
        // The originating app may exit before the change ends, so its event is kept now and transferred afterwards.
        for connection in observations where (runningDeviceIdentifiers.contains(connection.deviceID)
            || changingDeviceIdentifiers.contains(connection.deviceID))
            && (connection.deviceSetPath == nil || connection.deviceSetPath == testingDeviceSetPath) {
            if let previous = latestObserved[connection.deviceID], previous.event >= connection.event { continue }
            latestObserved[connection.deviceID] = connection
        }
        var changed = false
        var firstFailure: (any Error)?
        for connection in latestObserved.values.sorted(by: { $0.event < $1.event }) where !changingDeviceIdentifiers.contains(connection.deviceID) {
            if let latest = latestHandled[connection.deviceID], latest >= connection.event { continue }
            if isCancelled(connection) {
                latestHandled[connection.deviceID] = connection.event
                continue
            }
            do {
                try await transfer(connection)
                latestHandled[connection.deviceID] = connection.event
                changed = true
            } catch {
                if error is CancellationError, isCancelled(connection) {
                    latestHandled[connection.deviceID] = connection.event
                } else if firstFailure == nil { firstFailure = error }
            }
        }
        if let firstFailure { throw firstFailure }
        return changed
    }
}

package enum SimulatorProcessConnections {
    package static func read() throws -> [XcodeSimulatorConnection] {
        let user = getuid()
        let capacity = Int(proc_listpids(UInt32(PROC_UID_ONLY), user, nil, 0)) / MemoryLayout<pid_t>.stride + 128
        guard capacity > 128 else { throw HostOperationError.io("process-list", "Could not enumerate simulator application processes.") }
        var processes = [pid_t](repeating: 0, count: capacity)
        let bytes = processes.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), user, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { throw HostOperationError.io("process-list", "Could not enumerate simulator application processes.") }
        return try read(processIdentifiers: Array(processes.prefix(Int(bytes) / MemoryLayout<pid_t>.stride)))
    }

    package static func read(processIdentifiers: [pid_t]) throws -> [XcodeSimulatorConnection] {
        let testingDeviceSetPath = SimulatorDeviceSets.testingPath()
        let user = getuid()
        var result: [XcodeSimulatorConnection] = []
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        for pid in processIdentifiers where pid > 0 {
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            let executable = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            guard executable.contains("/data/Containers/Bundle/Application/") else { continue }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  info.pbi_uid == user else { continue }
            guard let data = ProcessArguments.readRaw(processIdentifier: pid) else { continue }
            var current = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &current, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  current.pbi_start_tvsec == info.pbi_start_tvsec, current.pbi_start_tvusec == info.pbi_start_tvusec else { continue }
            if let connection = decode(data, executablePath: executable, event: .init(processIdentifier: pid, startSeconds: info.pbi_start_tvsec, startMicroseconds: info.pbi_start_tvusec), testingDeviceSetPath: testingDeviceSetPath) {
                result.append(connection)
            }
        }
        return result
    }

    package static func decode(_ arguments: Data, executablePath: String, event: XcodeSimulatorConnection.Event, testingDeviceSetPath: String? = nil) -> XcodeSimulatorConnection? {
        guard let process = ProcessArguments(data: arguments) else { return nil }
        let environment = process.environment
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

/// The catalog that the last synchronization read, which tells whether the inventory needs reading again.
package final class SimulatorCatalogTracker {
    private var catalog: [DeviceInventoryID: SimulatorHostDevice] = [:]

    /// Records `devices` and returns whether they differ from the previous observation.
    /// - Parameter changing: Devices that a change was altering during the read, which keep their previous state.
    package func observe(_ devices: [SimulatorHostDevice], changing: Set<DeviceInventoryID> = []) -> Bool {
        var current = Dictionary(devices.map { ($0.inventoryID, $0) }, uniquingKeysWith: { first, _ in first })
        // A restart's stop and boot are steps of that change, not a device that newly booted.
        for identifier in changing {
            if let previous = catalog[identifier] { current[identifier] = previous }
        }
        defer { catalog = current }
        return current != catalog
    }
}


package struct ProcessArguments {
    package let arguments: [String]
    package let environment: [String: String]

    package static func readRaw(processIdentifier: pid_t) -> Data? {
        var query = [CTL_KERN, KERN_PROCARGS2, processIdentifier]
        var size = 0
        guard sysctl(&query, UInt32(query.count), nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var data = Data(count: size)
        guard data.withUnsafeMutableBytes({ sysctl(&query, UInt32(query.count), $0.baseAddress, &size, nil, 0) }) == 0
        else { return nil }
        data.count = size
        return data
    }

    package init?(data: Data) {
        guard data.count >= MemoryLayout<Int32>.size else { return nil }
        let count = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count >= 0 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        func nextString() -> String? {
            guard cursor < data.count, let end = data[cursor...].firstIndex(of: 0) else { return nil }
            defer { cursor = end + 1 }
            return String(data: data[cursor..<end], encoding: .utf8)
        }
        guard nextString() != nil else { return nil }
        while cursor < data.count, data[cursor] == 0 { cursor += 1 }
        var arguments: [String] = []
        for _ in 0..<count {
            guard let argument = nextString() else { return nil }
            arguments.append(argument)
        }
        var environment: [String: String] = [:]
        while let entry = nextString(), !entry.isEmpty {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        self.arguments = arguments
        self.environment = environment
    }
}
