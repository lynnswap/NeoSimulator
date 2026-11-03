import Foundation

/// A launchd job in a simulator that NeoSimulator can stop and start.
public struct SimulatorBackgroundService: Sendable, Hashable, Identifiable {
    public let label: String
    /// What the service does, in one short sentence.
    public let summary: String
    public var id: String { label }

    init(_ label: String, _ summary: String) {
        self.label = label
        self.summary = summary
    }
}

/// A service that stays enabled because simulators need it.
/// It can be enabled again after another tool disabled it, but it is never disabled.
public struct SimulatorRequiredBackgroundService: Sendable, Hashable, Identifiable {
    public let label: String
    public let reason: String
    public var id: String { label }

    init(_ label: String, reason: String) {
        self.label = label
        self.reason = reason
    }
}

/// Background services grouped by the feature they provide.
///
/// Categories may share services. Disabling a category keeps a shared service running
/// while another category that lists it is fully enabled.
public struct SimulatorBackgroundServiceCategory: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let summary: String
    /// What stops working while the category is disabled.
    public let consequence: String
    public let services: [SimulatorBackgroundService]
    public let requiredServices: [SimulatorRequiredBackgroundService]

    init(id: String, name: String, summary: String, consequence: String,
         services: [SimulatorBackgroundService], requiredServices: [SimulatorRequiredBackgroundService] = []) {
        self.id = id
        self.name = name
        self.summary = summary
        self.consequence = consequence
        self.services = services
        self.requiredServices = requiredServices
    }
}

public enum SimulatorBackgroundServiceState: Sendable, Equatable {
    case enabled, disabled, partiallyDisabled
}

/// What a background service change applies to.
public enum SimulatorBackgroundServiceTarget: Sendable, Hashable {
    /// Every service in the category with this identifier.
    case category(String)
    /// One managed service, by its launchd label.
    case service(String)
}

/// A booted simulator's managed background services, as its launchd reports them.
public struct SimulatorBackgroundServices: Sendable, Equatable {
    /// Managed labels that have a disable override.
    public let disabledLabels: Set<String>
    /// Managed labels loaded in the current boot session.
    public let loadedLabels: Set<String>
    /// Labels this simulator's platform keeps enabled although a category lists them.
    public let platformRequiredLabels: Set<String>

    @_spi(NeoSimulator) public init(disabled: Set<String>, loaded: Set<String>, productFamily: String) {
        disabledLabels = disabled.intersection(BackgroundServiceCatalog.managed)
        loadedLabels = loaded.intersection(BackgroundServiceCatalog.managed)
        platformRequiredLabels = BackgroundServiceCatalog.platformRequired(productFamily: productFamily)
    }

    public func isEnabled(_ label: String) -> Bool { !disabledLabels.contains(label) }

    /// Whether disabling may stop this service on this simulator.
    public func canDisable(_ label: String) -> Bool {
        BackgroundServiceCatalog.slimmable.contains(label) && !platformRequiredLabels.contains(label)
    }

    /// A category is disabled when each of its services is disabled or kept running for another fully
    /// enabled category, which is what disabling the category leaves behind.
    public func state(of category: SimulatorBackgroundServiceCategory) -> SimulatorBackgroundServiceState {
        let labels = category.services.map(\.label).filter(canDisable)
        guard labels.contains(where: disabledLabels.contains) else { return .enabled }
        let settled = labels.allSatisfy { label in
            disabledLabels.contains(label) || SimulatorBackgroundServiceCategory.all.contains {
                $0.id != category.id && $0.services.contains { $0.label == label } && isFullyEnabled($0)
            }
        }
        return settled ? .disabled : .partiallyDisabled
    }

    /// Shared services stay enabled while another fully enabled category needs them.
    @_spi(NeoSimulator) public func labelsKeptEnabled(disabling categories: [SimulatorBackgroundServiceCategory],
                                                    named: [String]) -> Set<String> {
        let covered = Set(categories.flatMap { $0.services.map(\.label) }).subtracting(named)
        var kept = Set<String>()
        for category in SimulatorBackgroundServiceCategory.all where !categories.contains(category) && isFullyEnabled(category) {
            kept.formUnion(category.services.map(\.label).filter(covered.contains))
        }
        return kept
    }

    func isFullyEnabled(_ category: SimulatorBackgroundServiceCategory) -> Bool {
        category.services.allSatisfy { isEnabled($0.label) }
    }
}

/// The result of a background service change, with the state read back from the simulator.
public struct SimulatorBackgroundServicesUpdate: Sendable {
    public let services: SimulatorBackgroundServices
    /// Services a disable left running because the platform or another fully enabled category needs them.
    public let stillEnabledLabels: [String]
    /// Enabled services that launchd did not load in the current boot session; they start at the next boot.
    public let notStartedLabels: [String]
}

/// A failed background service change with the state read after the attempt, including changes already made.
@_spi(NeoSimulator) public struct SimulatorBackgroundServicesUpdateFailure: Error, LocalizedError, Sendable {
    /// Nil when the state could not be read after the failure.
    public let services: SimulatorBackgroundServices?
    public let underlyingError: SimulatorHostFailure
    public var errorDescription: String? { underlyingError.errorDescription }
    public var failureReason: String? { underlyingError.failureReason }
    public var recoverySuggestion: String? { underlyingError.recoverySuggestion }
}

enum BackgroundServiceCatalog {
    static let slimmable = Set(SimulatorBackgroundServiceCategory.all.flatMap { $0.services.map(\.label) })
    /// The only labels NeoSimulator ever changes: required services may only be enabled again.
    static let managed = slimmable.union(SimulatorBackgroundServiceCategory.all.flatMap { $0.requiredServices.map(\.label) })

    static func category(_ identifier: String) -> SimulatorBackgroundServiceCategory? {
        SimulatorBackgroundServiceCategory.all.first { $0.id == identifier }
    }

    static func platformRequired(productFamily: String) -> Set<String> {
        switch productFamily {
        // watchOS re-enables homed after startup, so a disable override does not hold.
        case "Apple Watch": ["com.apple.homed"]
        // visionOS serves its surroundings as mobile assets; without mobileassetd it boots into a black space.
        case "Apple Vision": ["com.apple.mobileassetd"]
        default: []
        }
    }
}

extension SimulatorHostController {
    /// Reads the managed background services of a booted simulator.
    public func backgroundServices(for device: InventoryDevice) async throws -> SimulatorBackgroundServices {
        do { return try await backgroundServiceBackend(for: device).read() }
        catch is CancellationError { throw CancellationError() }
        catch let error as SimulatorHostFailure { throw error }
        catch { throw SimulatorHostFailure(error) }
    }

    /// Enables or disables services in a booted simulator without rebooting it.
    /// The disable overrides persist, so the change also applies to later boots. Once launchctl may have run,
    /// a failure is a `SimulatorBackgroundServicesUpdateFailure` with the state read after the attempt.
    public func setBackgroundServices(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool,
                                      for device: InventoryDevice) async throws -> SimulatorBackgroundServicesUpdate {
        let backend: SimulatorBackgroundServiceBackend
        do { backend = try await backgroundServiceBackend(for: device) }
        catch is CancellationError { throw CancellationError() }
        catch let error as SimulatorHostFailure { throw error }
        catch { throw SimulatorHostFailure(error) }
        return try await backend.update(targets, enabled: enabled)
    }

    private func backgroundServiceBackend(for device: InventoryDevice) async throws -> SimulatorBackgroundServiceBackend {
        guard case .simulator(let simulator) = device, simulator.state == "Booted" else {
            throw CLIError.unavailable("background-services-unavailable",
                                       "Background services are available only on a booted simulator.")
        }
        guard let xcodeURL = try await inspector(for: device).simulatorXcodeURL else {
            throw CLIError.configuration("background-services-source", "simctl requires the simulator's developer tools.")
        }
        return .live(device: simulator, xcodeURL: xcodeURL)
    }
}

/// Reads and changes background services with `launchctl` in the simulator, following simslim's
/// live enable and disable: batch `load -w` / `unload -w` with the runtime's job plists, then
/// per-label transitions for what the batch missed, and a read-back of every change.
struct SimulatorBackgroundServiceBackend: Sendable {
    /// Runs `launchctl` with these arguments in the simulator.
    var launchctl: @Sendable ([String]) async throws -> CommandOutput
    /// Maps labels to the runtime job plists that define exactly that label; nil when the runtime root is unknown.
    var jobPlists: @Sendable ([String]) async -> [String: String]?
    var pause: @Sendable (Duration) async throws -> Void
    let productFamily: String

    /// launchd_sim answers error 124 for a few seconds around a boot; reads and later passes wait on these.
    static let retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]
    static let transitionPasses = 3
    static let transitionWorkers = 8
    /// Keeps one `launchctl load` / `unload` argument list far below ARG_MAX.
    static let batchSize = 64
    static let commandLimit: Duration = .seconds(120)

    func read() async throws -> SimulatorBackgroundServices {
        async let disabled = readLaunchd(["print-disabled", "system"])
        async let loaded = readLaunchd(["list"])
        return SimulatorBackgroundServices(disabled: Self.parseDisabled(try await disabled),
                                           loaded: Self.parseLoaded(try await loaded), productFamily: productFamily)
    }

    /// A failure other than cancellation is a `SimulatorBackgroundServicesUpdateFailure` with the state read afterwards.
    func update(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool) async throws -> SimulatorBackgroundServicesUpdate {
        do { return try await apply(targets, enabled: enabled) }
        catch is CancellationError { throw CancellationError() }
        catch {
            let services = try? await read()
            throw SimulatorBackgroundServicesUpdateFailure(services: services, underlyingError: SimulatorHostFailure(error))
        }
    }

    private func apply(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool) async throws -> SimulatorBackgroundServicesUpdate {
        var categories: [SimulatorBackgroundServiceCategory] = []
        var labels: [String] = []
        for target in targets {
            switch target {
            case .category(let identifier):
                guard let category = BackgroundServiceCatalog.category(identifier) else {
                    throw CLIError.configuration("background-service-unknown", "“\(identifier)” is not a background service category.")
                }
                if !categories.contains(category) { categories.append(category) }
            case .service(let label):
                guard BackgroundServiceCatalog.managed.contains(label) else {
                    throw CLIError.configuration("background-service-unknown", "“\(label)” is not a managed background service.")
                }
                if !labels.contains(label) { labels.append(label) }
            }
        }
        let covered = Set(categories.flatMap { $0.services.map(\.label) }).union(labels).sorted()
        return enabled ? try await start(covered) : try await stop(covered, categories: categories, named: labels)
    }

    private func stop(_ covered: [String], categories: [SimulatorBackgroundServiceCategory],
                      named: [String]) async throws -> SimulatorBackgroundServicesUpdate {
        let before = try await read()
        let kept = before.labelsKeptEnabled(disabling: categories, named: named)
        let stopping = covered.filter { before.canDisable($0) && !kept.contains($0) }
        let stillEnabled = covered.filter { !stopping.contains($0) }
        var pending = Self.stillRunning(stopping, in: before)
        if !pending.isEmpty, let plists = await jobPlists(pending), !plists.isEmpty {
            await batch("unload", pending.compactMap { plists[$0] })
            // A failed read only means every label takes the per-label path.
            if let after = try? await read() { pending = Self.stillRunning(pending, in: after) }
        }
        try await transition(pending, disabling: true)
        let after = try await read()
        let missing = stopping.filter(after.isEnabled)
        guard missing.isEmpty else {
            throw Self.failure("background-service-disable",
                               "\(missing.count) of \(stopping.count) services are still enabled: \(missing.joined(separator: ", "))")
        }
        return SimulatorBackgroundServicesUpdate(services: after, stillEnabledLabels: stillEnabled, notStartedLabels: [])
    }

    private func start(_ covered: [String]) async throws -> SimulatorBackgroundServicesUpdate {
        var state = try await read()
        let candidates = covered.filter { !state.isEnabled($0) || !state.loadedLabels.contains($0) }
        let plists = candidates.isEmpty ? [:] : await jobPlists(candidates)
        // Without the runtime root a missing plist cannot be told from an unknown one, so every unloaded
        // label counts as one launchd should load. A label without a plist only needs its override lifted.
        let loadable = { (label: String) in plists == nil || plists?[label] != nil }
        let pending = candidates.filter { !state.isEnabled($0) || loadable($0) }
        guard !pending.isEmpty else {
            return SimulatorBackgroundServicesUpdate(services: state, stillEnabledLabels: [], notStartedLabels: [])
        }
        let paths = pending.compactMap { plists?[$0] }
        if !paths.isEmpty {
            await batch("load", paths)
            state = try await read()
        }
        let enabling = pending.filter { !state.isEnabled($0) }
        let unloaded = pending.compactMap { label in
            plists?[label].flatMap { state.loadedLabels.contains(label) ? nil : $0 }
        }
        try await transition(enabling, disabling: false)
        // An already-loaded job exits 37, so the status is not trusted; the read-back decides.
        for path in unloaded { _ = try? await launchctl(["bootstrap", "system", path]) }
        if !enabling.isEmpty || !unloaded.isEmpty { state = try await read() }
        let still = pending.filter { !state.isEnabled($0) }
        guard still.isEmpty else {
            throw Self.failure("background-service-enable",
                               "\(still.count) of \(pending.count) services are still disabled: \(still.joined(separator: ", "))")
        }
        let notStarted = pending.filter { !state.loadedLabels.contains($0) && loadable($0) }
        return SimulatorBackgroundServicesUpdate(services: state, stillEnabledLabels: [], notStartedLabels: notStarted)
    }

    private static func stillRunning(_ labels: [String], in state: SimulatorBackgroundServices) -> [String] {
        labels.filter { state.isEnabled($0) || state.loadedLabels.contains($0) }
    }

    /// The exit status is not trusted: launchctl reports one job's failure for the whole call, so the
    /// caller reads the state back. A chunk that fails to finish ends the batch.
    private func batch(_ verb: String, _ paths: [String]) async {
        for start in stride(from: 0, to: paths.count, by: Self.batchSize) {
            do { _ = try await launchctl([verb, "-w"] + paths[start..<min(start + Self.batchSize, paths.count)]) }
            catch { return }
        }
    }

    private func transition(_ labels: [String], disabling: Bool) async throws {
        var pending = labels
        var failures: [String] = []
        for pass in 0..<Self.transitionPasses where !pending.isEmpty {
            if pass > 0 { try await pause(Self.retryDelays[min(pass - 1, Self.retryDelays.count - 1)]) }
            try Task.checkCancellation()
            let failed = await withTaskGroup(of: (label: String, message: String)?.self) { group in
                var queued = pending[...]
                for _ in 0..<min(Self.transitionWorkers, queued.count) {
                    let label = queued.removeFirst()
                    group.addTask { await change(label, disabling: disabling) }
                }
                var failed: [(label: String, message: String)] = []
                while let result = await group.next() {
                    if let result { failed.append(result) }
                    if let label = queued.popFirst() { group.addTask { await change(label, disabling: disabling) } }
                }
                return failed.sorted { $0.label < $1.label }
            }
            pending = failed.map(\.label)
            failures = failed.map(\.message)
        }
        try Task.checkCancellation()
        guard pending.isEmpty else {
            throw Self.failure("background-service-change",
                               "\(pending.count) of \(labels.count) launchctl changes failed: \(failures.joined(separator: "; "))")
        }
    }

    private func change(_ label: String, disabling: Bool) async -> (label: String, message: String)? {
        let verb = disabling ? "disable" : "enable"
        do {
            let output = try await launchctl([verb, "system/" + label])
            guard output.terminationStatus == 0 else { return (label, Self.describe(verb, label, output)) }
            guard disabling else { return nil }
            // `disable` only blocks the next bootstrap; `bootout` stops the running job. Status 3 means it was not loaded.
            let bootout = try await launchctl(["bootout", "system/" + label])
            guard [0, 3].contains(bootout.terminationStatus) else { return (label, Self.describe("bootout", label, bootout)) }
            return nil
        } catch {
            return (label, "\(verb) \(label): \(error.localizedDescription)")
        }
    }

    private func readLaunchd(_ arguments: [String]) async throws -> String {
        var attempt = 0
        while true {
            let failure: any Error
            switch await Result(catching: { try await launchctl(arguments) }) {
            case .success(let output) where output.terminationStatus == 0:
                return String(decoding: output.stdout, as: UTF8.self)
            case .success(let output):
                failure = CLIError.io("background-service-read", Self.describe(arguments[0], nil, output))
                guard Self.isSettling(output) else { throw failure }
            case .failure(let timeout as BackgroundServiceCommandTimeout):
                failure = timeout
            case .failure(let error):
                throw error
            }
            guard attempt < Self.retryDelays.count else { throw failure }
            try await pause(Self.retryDelays[attempt])
            attempt += 1
        }
    }

    /// launchd_sim's error 124, "Domain is tearing down", while a boot session starts or ends.
    static func isSettling(_ output: CommandOutput) -> Bool {
        let text = String(decoding: output.stdout + output.stderr, as: UTF8.self)
        return output.terminationStatus == 124 || text.contains("code=124") || text.contains("Domain is tearing down")
    }

    /// Recent launchd prints `"com.apple.x" => disabled`; older builds print `=> true`.
    static func parseDisabled(_ output: String) -> Set<String> {
        var labels = Set<String>()
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "\"", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let arrow = parts[2].range(of: "=>") else { continue }
            let value = parts[2][arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("disabled") || value.hasPrefix("true") { labels.insert(String(parts[1])) }
        }
        return labels
    }

    /// Rows are "PID<TAB>Status<TAB>Label"; a loaded job that is not running has "-" as its PID.
    static func parseLoaded(_ output: String) -> Set<String> {
        Set(output.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count == 3 && fields[2] != "Label" ? String(fields[2]) : nil
        })
    }

    private static func describe(_ verb: String, _ label: String?, _ output: CommandOutput) -> String {
        let detail = output.stderrText.isEmpty ? output.stdoutText : output.stderrText
        return ([verb, label].compactMap(\.self).joined(separator: " ")) + " exited with status \(output.terminationStatus)"
            + (detail.isEmpty ? "" : ": \(detail)")
    }

    private static func failure(_ identifier: String, _ message: String) -> CLIError {
        CLIError(category: .io, identifier: identifier, message: message, failureReason: message)
    }
}

struct BackgroundServiceCommandTimeout: LocalizedError {
    var errorDescription: String? { "launchctl did not finish in time." }
}

extension SimulatorBackgroundServiceBackend {
    static func live(device: SimulatorHostDevice, xcodeURL: URL) -> Self {
        let simctl = { @Sendable (arguments: [String]) async throws -> CommandOutput in
            try await withThrowingTaskGroup(of: CommandOutput.self) { group in
                group.addTask {
                    try await SystemCommandRunner.runSimctlCancellable(xcodeURL: xcodeURL, arguments: arguments,
                                                                       deviceSetPath: device.deviceSetPath)
                }
                group.addTask {
                    try await Task.sleep(for: Self.commandLimit)
                    throw BackgroundServiceCommandTimeout()
                }
                defer { group.cancelAll() }
                guard let output = try await group.next() else { throw CancellationError() }
                return output
            }
        }
        return Self(launchctl: { try await simctl(["spawn", device.identifier, "launchctl"] + $0) },
                    jobPlists: { labels in
                        guard let output = try? await simctl(["list", "runtimes", "--json"]), output.terminationStatus == 0,
                              let root = Self.runtimeRoot(output.stdout, identifier: device.runtimeIdentifier) else { return nil }
                        return Self.jobPlists(labels, runtimeRoot: root)
                    },
                    pause: { try await Task.sleep(for: $0) }, productFamily: device.productFamily)
    }

    static func runtimeRoot(_ data: Data, identifier: String) -> URL? {
        struct Runtimes: Decodable {
            struct Runtime: Decodable { let identifier: String; let runtimeRoot: String? }
            let runtimes: [Runtime]
        }
        let path = (try? JSONDecoder().decode(Runtimes.self, from: data))?.runtimes.first { $0.identifier == identifier }?.runtimeRoot
        return path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Finds plists by the Label they define, not by file name: iOS 27 defines `com.apple.imcore.imtransferagent`
    /// in `com.apple.imtransferagent.plist`, and a file named after a label may define another job.
    /// Simulator processes see the host file system, so these paths work in launchctl.
    static func jobPlists(_ labels: [String], runtimeRoot: URL) -> [String: String] {
        let wanted = Set(labels)
        var plists: [String: String] = [:]
        for directory in ["System/Library/LaunchDaemons", "System/Library/LaunchAgents"] {
            let folder = runtimeRoot.appending(path: directory)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".plist") {
                let file = folder.appending(path: name)
                guard let data = FileManager.default.contents(atPath: file.path),
                      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let label = plist["Label"] as? String, wanted.contains(label), plists[label] == nil else { continue }
                plists[label] = file.path
            }
        }
        return plists
    }
}
