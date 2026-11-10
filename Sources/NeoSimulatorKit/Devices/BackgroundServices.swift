import NeoSimulatorDeviceIO
import Foundation
import Synchronization

/// A launchd job in a simulator that NeoSimulator can stop and start.
public struct SimulatorBackgroundService: Sendable, Hashable, Identifiable {
    /// The service's launchd label.
    public var label: String
    /// What the service does, in one short sentence.
    public var summary: String
    /// The service's launchd label.
    public var id: String { label }

    /// Creates a service description.
    /// - Parameters:
    ///   - label: The service's launchd label.
    ///   - summary: A short description of the service.
    public init(_ label: String, _ summary: String) {
        self.label = label
        self.summary = summary
    }
}

/// A service that stays enabled because simulators need it.
/// It can be enabled again after another tool disabled it, but it is never disabled.
public struct SimulatorRequiredBackgroundService: Sendable, Hashable, Identifiable {
    /// The service's launchd label.
    public var label: String
    /// Why simulators need the service.
    public var reason: String
    /// The service's launchd label.
    public var id: String { label }

    /// Creates a description of a required service.
    /// - Parameters:
    ///   - label: The service's launchd label.
    ///   - reason: Why the service must remain enabled.
    public init(_ label: String, reason: String) {
        self.label = label
        self.reason = reason
    }
}

/// Background services grouped by the feature they provide.
///
/// Categories may share services. Disabling a category keeps a shared service running
/// while another category that lists it is fully enabled. ``all`` lists every category.
public struct SimulatorBackgroundServiceCategory: Sendable, Hashable, Identifiable {
    /// The identifier to pass to ``SimulatorBackgroundServiceTarget/category(_:)``.
    public let id: String
    /// The category's display name.
    public var name: String
    /// What the category's services provide.
    public var summary: String
    /// What stops working while the category is disabled.
    public var consequence: String
    /// The services that disabling this category stops.
    public var services: [SimulatorBackgroundService]
    /// Services related to this category that stay enabled because simulators need them.
    public var requiredServices: [SimulatorRequiredBackgroundService]

    /// Creates a category of related services.
    /// - Parameters:
    ///   - id: The category identifier.
    ///   - name: The category's display name.
    ///   - summary: What the category provides.
    ///   - consequence: What stops working when the category is disabled.
    ///   - services: Services that the category can disable.
    ///   - requiredServices: Related services that must remain enabled.
    public init(id: String, name: String, summary: String, consequence: String,
         services: [SimulatorBackgroundService], requiredServices: [SimulatorRequiredBackgroundService] = []) {
        self.id = id
        self.name = name
        self.summary = summary
        self.consequence = consequence
        self.services = services
        self.requiredServices = requiredServices
    }
}

/// How much of a category is disabled, as ``SimulatorBackgroundServices/state(of:)`` reports it.
public enum SimulatorBackgroundServiceState: Sendable, Equatable {
    /// None of the services that this simulator can disable is disabled.
    case enabled
    /// Each service that this simulator can disable is disabled, or is kept running for another fully enabled category.
    case disabled
    /// Some of those services are disabled, and others are running without another fully enabled category needing them.
    case partiallyDisabled
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
    public var disabledLabels: Set<String>
    /// Managed labels loaded in the current boot session.
    public var loadedLabels: Set<String>
    /// Labels this simulator's platform keeps enabled although a category lists them.
    public var platformRequiredLabels: Set<String>
    /// The categories that decide which labels this state covers.
    package var catalog: BackgroundServiceCatalog

    /// Creates a service-state snapshot, retaining the labels managed by this Kit.
    /// - Parameters:
    ///   - disabled: Launchd labels with disable overrides.
    ///   - loaded: Launchd labels loaded in the current boot session.
    ///   - productFamily: The simulator's CoreSimulator family name, such as `iPhone` or `iPad`.
    public init(disabled: Set<String>, loaded: Set<String>, productFamily: String) {
        self.init(disabled: disabled, loaded: loaded, productFamily: productFamily, catalog: .builtIn)
    }

    /// Creates a service-state snapshot that retains the labels `catalog` manages.
    package init(disabled: Set<String>, loaded: Set<String>, productFamily: String, catalog: BackgroundServiceCatalog) {
        disabledLabels = disabled.intersection(catalog.managed)
        loadedLabels = loaded.intersection(catalog.managed)
        platformRequiredLabels = BackgroundServiceCatalog.platformRequired(productFamily: productFamily)
        self.catalog = catalog
    }

    /// Returns whether the service named `label` has no disable override.
    ///
    /// - Parameter label: The service's launchd label.
    /// - Returns: `true` if ``disabledLabels`` does not contain the label.
    public func isEnabled(_ label: String) -> Bool { !disabledLabels.contains(label) }

    /// Returns whether disabling may stop this service on this simulator.
    ///
    /// - Parameter label: The service's launchd label.
    /// - Returns: `true` if a category lists the service and this simulator's platform does not keep it enabled.
    public func canDisable(_ label: String) -> Bool {
        catalog.slimmable.contains(label) && !platformRequiredLabels.contains(label)
    }

    /// Returns how much of `category` is disabled.
    ///
    /// A category is disabled when each of its services is disabled or kept running for another fully
    /// enabled category, which is what disabling the category leaves behind.
    ///
    /// - Parameter category: The category to check.
    /// - Returns: The category's state on this simulator.
    public func state(of category: SimulatorBackgroundServiceCategory) -> SimulatorBackgroundServiceState {
        let labels = category.services.map(\.label).filter(canDisable)
        guard labels.contains(where: disabledLabels.contains) else { return .enabled }
        let settled = labels.allSatisfy { label in
            disabledLabels.contains(label)
                || catalog.categories.contains {
                $0.id != category.id && $0.services.contains { $0.label == label } && isFullyEnabled($0)
            }
        }
        return settled ? .disabled : .partiallyDisabled
    }

    /// Returns the services that disabling `categories` would leave enabled.
    ///
    /// Shared services stay enabled while another fully enabled category needs them.
    ///
    /// - Parameters:
    ///   - categories: The categories to disable.
    ///   - named: Labels to disable individually, which are never kept enabled.
    /// - Returns: The labels of the kept services.
    public func labelsKeptEnabled(disabling categories: [SimulatorBackgroundServiceCategory],
                                                    named: [String]) -> Set<String> {
        let covered = Set(categories.flatMap { $0.services.map(\.label) }).subtracting(named)
        let disabledCategoryIDs = Set(categories.map(\.id))
        var kept = Set<String>()
        for category in catalog.categories where !disabledCategoryIDs.contains(category.id) && isFullyEnabled(category)
        {
            kept.formUnion(category.services.map(\.label).filter(covered.contains))
        }
        return kept
    }

    /// Returns whether every service in `category` has no disable override.
    ///
    /// - Parameter category: The category to check.
    /// - Returns: `true` if ``disabledLabels`` contains none of the category's services.
    public func isFullyEnabled(_ category: SimulatorBackgroundServiceCategory) -> Bool {
        category.services.allSatisfy { isEnabled($0.label) }
    }
}

/// The result of a background service change, with the state read back from the simulator.
package struct SimulatorBackgroundServicesUpdate: Sendable {
    package let services: SimulatorBackgroundServices
    /// Services a disable left running because the platform or another fully enabled category needs them.
    package let stillEnabledLabels: [String]
    /// Enabled services that launchd did not load in the current boot session; they start at the next boot.
    package let notStartedLabels: [String]

    package init(services: SimulatorBackgroundServices, stillEnabledLabels: [String],
                                   notStartedLabels: [String]) {
        self.services = services
        self.stillEnabledLabels = stillEnabledLabels
        self.notStartedLabels = notStartedLabels
    }
}

/// A saved set of disabled services, which a device's profile asks for.
public struct ServiceConfiguration: Codable, Equatable, Sendable {
    /// The launchd labels that the configuration disables.
    public var disabledLabels: Set<String> = []

    /// Every label that a configuration covers: the services that ``SimulatorBackgroundServiceCategory/all`` lists.
    public static let labels = Set(SimulatorBackgroundServiceCategory.all.flatMap { $0.services.map(\.label) })

    /// Creates a configuration.
    ///
    /// - Parameter disabledLabels: The launchd labels to disable.
    public init(disabledLabels: Set<String> = []) { self.disabledLabels = disabledLabels }

    /// Returns the state that this configuration describes, with no service loaded.
    ///
    /// - Parameter productFamily: The simulator's product family name, such as `Apple Watch`, which decides the services
    ///   that its platform keeps enabled. An empty name keeps none.
    /// - Returns: The state, for evaluating categories without a simulator.
    public func state(productFamily: String = "") -> SimulatorBackgroundServices {
        state(productFamily: productFamily, catalog: .builtIn)
    }

    /// Returns the state that this configuration describes among `catalog`'s services, with no service loaded.
    package func state(productFamily: String = "", catalog: BackgroundServiceCatalog) -> SimulatorBackgroundServices {
        SimulatorBackgroundServices(
            disabled: disabledLabels, loaded: [], productFamily: productFamily, catalog: catalog)
    }

    /// Returns a copy of this configuration with per-label choices applied.
    ///
    /// - Parameter overrides: Whether to enable each launchd label.
    /// - Returns: The resulting configuration.
    public func applying(_ overrides: [String: Bool]) -> Self {
        var result = self
        for (label, enabled) in overrides {
            if enabled { result.disabledLabels.remove(label) }
            else { result.disabledLabels.insert(label) }
        }
        return result
    }

    /// Enables or disables `targets` in this configuration, following the rules that a running simulator follows.
    ///
    /// Disabling skips shared services that another fully enabled category needs and services that the platform keeps
    /// enabled. Labels outside ``labels`` are ignored.
    ///
    /// - Parameters:
    ///   - targets: The categories and services to change.
    ///   - enabled: Whether to enable or disable them.
    ///   - productFamily: The simulator's product family name, such as `Apple Watch`, which decides the services that its
    ///     platform keeps enabled. An empty name keeps none.
    /// - Returns: The labels that the change applies to.
    @discardableResult
    public mutating func set(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool,
                             productFamily: String = "") -> Set<String> {
        set(targets, enabled: enabled, productFamily: productFamily, catalog: .builtIn)
    }

    /// Enables or disables `targets` among `catalog`'s services, as ``set(_:enabled:productFamily:)`` does among
    /// ``labels``.
    @discardableResult
    package mutating func set(
        _ targets: [SimulatorBackgroundServiceTarget], enabled: Bool, productFamily: String = "",
        catalog: BackgroundServiceCatalog
    ) -> Set<String> {
        let categories = catalog.categories.filter { targets.contains(.category($0.id)) }
        let named = targets.compactMap { target -> String? in
            if case .service(let label) = target { return label }
            return nil
        }
        var affected = Set(categories.flatMap { $0.services.map(\.label) }).union(named).intersection(catalog.slimmable)
        if enabled {
            disabledLabels.subtract(affected)
        } else {
            let before = state(productFamily: productFamily, catalog: catalog)
            affected.subtract(before.labelsKeptEnabled(disabling: categories, named: named))
            affected = affected.filter { before.canDisable($0) }
            disabledLabels.formUnion(affected)
        }
        return affected
    }
}

/// A failed background service change with the state read after the attempt, including changes already made.
package struct SimulatorBackgroundServicesUpdateFailure: Error, LocalizedError, Sendable {
    /// Nil when the state could not be read after the failure.
    package let services: SimulatorBackgroundServices?
    /// Whether a launchctl command may have changed the device before the failure.
    package let mayHaveChanged: Bool
    package var outcomeIsUnknown: Bool { mayHaveChanged && services == nil }
    package let underlyingError: SimulatorHostFailure
    package var errorDescription: String? { underlyingError.errorDescription }
    package var failureReason: String? { underlyingError.failureReason }
    package var recoverySuggestion: String? { underlyingError.recoverySuggestion }
}

/// The categories whose services NeoSimulator reads and changes: the built-in ones, and those that the app adds.
package struct BackgroundServiceCatalog: Sendable, Equatable {
    package static let builtIn = BackgroundServiceCatalog(SimulatorBackgroundServiceCategory.all)
    /// Labels that wedge a simulator while disabled, which no category may list, because their disable override
    /// outlives the boot. nanoregistryd hangs every simctl operation; sleepd makes SpringBoard retry itself to death;
    /// the rest were observed to break boot in simslim.
    package static let wedgingLabels: Set<String> = [
        "com.apple.nanoregistryd", "com.apple.nanoregistrylaunchd", "com.apple.nanoprefsyncd.2",
        "com.apple.nanotimekitcompaniond", "com.apple.nanobackupd", "com.apple.sleepd", "com.apple.appprotectiond",
        "com.apple.ManagedSettingsAgent", "com.apple.managedconfiguration.profiled", "com.apple.mobiletimerd",
        "com.apple.routined", "com.apple.biomed", "com.apple.biomesyncd", "com.apple.dmd", "com.apple.donotdisturbd",
    ]

    package let categories: [SimulatorBackgroundServiceCategory]
    /// The labels that the categories list, which disabling may stop.
    package let slimmable: Set<String>
    /// The only labels NeoSimulator ever changes: required services may only be enabled again.
    package let managed: Set<String>

    package init(_ categories: [SimulatorBackgroundServiceCategory]) {
        self.categories = categories
        slimmable = Set(categories.flatMap { $0.services.map(\.label) })
        managed = slimmable.union(categories.flatMap { $0.requiredServices.map(\.label) })
    }

    package func category(_ identifier: String) -> SimulatorBackgroundServiceCategory? {
        categories.first { $0.id == identifier }
    }

    package static func platformRequired(productFamily: String) -> Set<String> {
        switch productFamily {
        // watchOS re-enables homed after startup, so a disable override does not hold.
        case "Apple Watch": ["com.apple.homed"]
        // visionOS serves its surroundings as mobile assets; without mobileassetd it boots into a black space.
        case "Apple Vision": ["com.apple.mobileassetd"]
        default: []
        }
    }
}

/// Reads and changes background services with `launchctl` in the simulator, following simslim's
/// live enable and disable: batch `load -w` / `unload -w` with the runtime's job plists, then
/// per-label transitions for what the batch missed, and a read-back of every change.
package struct SimulatorBackgroundServiceBackend: Sendable {
    /// Runs `launchctl` with these arguments in the simulator.
    package var launchctl: @Sendable ([String]) async throws -> CommandOutput
    /// Maps labels to the runtime job plists that define exactly that label; nil when the runtime root is unknown.
    package var jobPlists: @Sendable ([String]) async -> [String: String]?
    package var pause: @Sendable (Duration) async throws -> Void
    package let productFamily: String
    /// The categories and services that this reads and changes.
    package var catalog = BackgroundServiceCatalog.builtIn

    /// launchd_sim answers error 124 for a few seconds around a boot; reads and later passes wait on these.
    package static let retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8)]
    package static let transitionPasses = 3
    package static let transitionWorkers = 8
    /// Keeps one `launchctl load` / `unload` argument list far below ARG_MAX.
    package static let batchSize = 64

    package func read() async throws -> SimulatorBackgroundServices {
        async let disabled = readLaunchd(["print-disabled", "system"])
        async let loaded = readLaunchd(["list"])
        return SimulatorBackgroundServices(disabled: Self.parseDisabled(try await disabled),
            loaded: Self.parseLoaded(try await loaded), productFamily: productFamily,
            catalog: catalog)
    }

    /// Cancellation before any launchctl change ran throws `CancellationError`, since nothing changed. Any other failure,
    /// including cancellation after one may have run, is a `SimulatorBackgroundServicesUpdateFailure` with the state read afterwards,
    /// which is nil when that read fails or is cancelled too.
    package func update(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool) async throws -> SimulatorBackgroundServicesUpdate {
        let attempt = ServiceChangeAttempt()
        do { return try await apply(targets, enabled: enabled, attempt: attempt) }
        catch {
            let cancelled = error is CancellationError
            if cancelled, !attempt.mayHaveChanged { throw CancellationError() }
            let services = try? await read()
            throw SimulatorBackgroundServicesUpdateFailure(
                services: services, mayHaveChanged: attempt.mayHaveChanged,
                underlyingError: SimulatorHostFailure(
                    cancelled ? Self.failure("background-service-stopped", attempt.stoppedDescription) : error))
        }
    }

    private func apply(_ targets: [SimulatorBackgroundServiceTarget], enabled: Bool,
                       attempt: ServiceChangeAttempt) async throws -> SimulatorBackgroundServicesUpdate {
        var categories: [SimulatorBackgroundServiceCategory] = []
        var labels: [String] = []
        for target in targets {
            switch target {
            case .category(let identifier):
                guard let category = catalog.category(identifier) else {
                    throw DeviceDomainError.configuration("background-service-unknown", "“\(identifier)” is not a background service category.")
                }
                if !categories.contains(category) { categories.append(category) }
            case .service(let label):
                guard catalog.managed.contains(label) else {
                    throw DeviceDomainError.configuration("background-service-unknown", "“\(label)” is not a managed background service.")
                }
                if !labels.contains(label) { labels.append(label) }
            }
        }
        let covered = Set(categories.flatMap { $0.services.map(\.label) }).union(labels).sorted()
        return enabled ? try await start(covered, attempt: attempt)
            : try await stop(covered, categories: categories, named: labels, attempt: attempt)
    }

    private func stop(_ covered: [String], categories: [SimulatorBackgroundServiceCategory], named: [String],
                      attempt: ServiceChangeAttempt) async throws -> SimulatorBackgroundServicesUpdate {
        let before = try await read()
        let kept = before.labelsKeptEnabled(disabling: categories, named: named)
        let stopping = covered.filter { before.canDisable($0) && !kept.contains($0) }
        let stillEnabled = covered.filter { !stopping.contains($0) }
        var pending = Self.stillRunning(stopping, in: before)
        if !pending.isEmpty, let plists = await jobPlists(pending), !plists.isEmpty {
            await batch("unload", pending.compactMap { plists[$0] }, attempt: attempt)
            // A failed read only means every label takes the per-label path.
            if let after = try? await read() { pending = Self.stillRunning(pending, in: after) }
        }
        try await transition(pending, disabling: true, attempt: attempt)
        let after = try await read()
        let missing = stopping.filter(after.isEnabled)
        guard missing.isEmpty else {
            throw Self.failure("background-service-disable",
                               "\(missing.count) of \(stopping.count) services are still enabled: \(missing.joined(separator: ", "))")
        }
        return SimulatorBackgroundServicesUpdate(services: after, stillEnabledLabels: stillEnabled, notStartedLabels: [])
    }

    private func start(_ covered: [String], attempt: ServiceChangeAttempt) async throws -> SimulatorBackgroundServicesUpdate {
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
            await batch("load", paths, attempt: attempt)
            state = try await read()
        }
        let enabling = pending.filter { !state.isEnabled($0) }
        let unloaded = pending.compactMap { label in
            plists?[label].flatMap { state.loadedLabels.contains(label) ? nil : $0 }
        }
        try await transition(enabling, disabling: false, attempt: attempt)
        // An already-loaded job exits 37, so the status is not trusted; the read-back decides.
        for path in unloaded {
            _ = try? await change(["bootstrap", "system", path], summary: "bootstrap \(URL(fileURLWithPath: path).lastPathComponent)", attempt: attempt)
        }
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
    private func batch(_ verb: String, _ paths: [String], attempt: ServiceChangeAttempt) async {
        for start in stride(from: 0, to: paths.count, by: Self.batchSize) {
            let chunk = paths[start..<min(start + Self.batchSize, paths.count)]
            do { _ = try await change([verb, "-w"] + chunk, summary: "\(verb) \(chunk.count) services", attempt: attempt) }
            catch { return }
        }
    }

    private func transition(_ labels: [String], disabling: Bool, attempt: ServiceChangeAttempt) async throws {
        var pending = labels
        var failures: [String] = []
        for pass in 0..<Self.transitionPasses where !pending.isEmpty {
            if pass > 0 { try await pause(Self.retryDelays[min(pass - 1, Self.retryDelays.count - 1)]) }
            try Task.checkCancellation()
            let failed = await withTaskGroup(of: (label: String, message: String)?.self) { group in
                var queued = pending[...]
                for _ in 0..<min(Self.transitionWorkers, queued.count) {
                    let label = queued.removeFirst()
                    group.addTask { await change(label, disabling: disabling, attempt: attempt) }
                }
                var failed: [(label: String, message: String)] = []
                while let result = await group.next() {
                    if let result { failed.append(result) }
                    if let label = queued.popFirst() { group.addTask { await change(label, disabling: disabling, attempt: attempt) } }
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

    private func change(_ label: String, disabling: Bool, attempt: ServiceChangeAttempt) async -> (label: String, message: String)? {
        let verb = disabling ? "disable" : "enable"
        do {
            let output = try await change([verb, "system/" + label], summary: "\(verb) \(label)", attempt: attempt)
            guard output.terminationStatus == 0 else { return (label, Self.describe(verb, label, output)) }
            guard disabling else { return nil }
            // `disable` only blocks the next bootstrap; `bootout` stops the running job. Status 3 means it was not loaded.
            let bootout = try await change(["bootout", "system/" + label], summary: "bootout \(label)", attempt: attempt)
            guard [0, 3].contains(bootout.terminationStatus) else { return (label, Self.describe("bootout", label, bootout)) }
            return nil
        } catch {
            return (label, "\(verb) \(label): \(error.localizedDescription)")
        }
    }

    /// Runs a launchctl command that changes state. One cancelled before its child started changed nothing and leaves no record.
    private func change(_ arguments: [String], summary: String, attempt: ServiceChangeAttempt) async throws -> CommandOutput {
        do {
            let output = try await launchctl(arguments)
            attempt.record(finished: output.terminationStatus == 0 ? summary : nil)
            return output
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            attempt.record(failed: "\(summary): \(error.localizedDescription)")
            throw error
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
                failure = DeviceDomainError.io("background-service-read", Self.describe(arguments[0], nil, output))
                guard Self.isSettling(output) else { throw failure }
            case .failure(let stopped as CommandFailure) where stopped.interruption == .cancelled:
                // A read leaves nothing to account for, and the caller's state stays as it was.
                throw CancellationError()
            case .failure(let timeout as CommandFailure) where timeout.interruption != nil:
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
    package static func isSettling(_ output: CommandOutput) -> Bool {
        let text = String(decoding: output.stdout + output.stderr, as: UTF8.self)
        return output.terminationStatus == 124 || text.contains("code=124") || text.contains("Domain is tearing down")
    }

    /// Recent launchd prints `"com.apple.x" => disabled`; older builds print `=> true`.
    package static func parseDisabled(_ output: String) -> Set<String> {
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
    package static func parseLoaded(_ output: String) -> Set<String> {
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

    private static func failure(_ identifier: String, _ message: String) -> DeviceDomainError {
        DeviceDomainError(category: .io, identifier: identifier, message: message, failureReason: message)
    }
}

/// What one background service change has asked launchctl to do, so a change stopped partway can report it.
/// The change's own workers record into it concurrently.
private final class ServiceChangeAttempt: Sendable {
    private struct State {
        var mayHaveChanged = false
        var finished: [String] = []
        var failed: [String] = []
    }
    private let state = Mutex(State())

    var mayHaveChanged: Bool { state.withLock(\.mayHaveChanged) }

    /// A nil `finished` is a command that ran and reported a failure, so it may still have changed something.
    func record(finished: String?) {
        state.withLock { state in
            state.mayHaveChanged = true
            if let finished { state.finished.append(finished) }
        }
    }

    func record(failed: String) {
        state.withLock { state in
            state.mayHaveChanged = true
            state.failed.append(failed)
        }
    }

    var stoppedDescription: String {
        state.withLock { state in
            let finished = state.finished.isEmpty ? [] : ["Finished: \(state.finished.joined(separator: ", "))."]
            return (["The background service change was stopped before it finished."] + state.failed + finished).joined(separator: " ")
        }
    }
}

extension SimulatorBackgroundServiceBackend {
    package static func live(device: SimulatorHostDevice, xcodeURL: URL, catalog: BackgroundServiceCatalog) -> Self {
        let simctl = { @Sendable (arguments: [String]) async throws -> CommandOutput in
            try await SystemCommandRunner().run(.simctl(xcodeURL: xcodeURL, arguments: arguments,
                                                        deviceSetPath: device.deviceSetPath, policy: .backgroundServiceCommand))
        }
        return Self(launchctl: { try await simctl(["spawn", device.identifier, "launchctl"] + $0) },
                    jobPlists: { labels in
                        guard let output = try? await simctl(["list", "runtimes", "--json"]), output.terminationStatus == 0,
                              let root = Self.runtimeRoot(output.stdout, identifier: device.runtimeIdentifier) else { return nil }
                        return Self.jobPlists(labels, runtimeRoot: root)
                    },
            pause: { try await Task.sleep(for: $0) }, productFamily: device.productFamily, catalog: catalog)
    }

    package static func runtimeRoot(_ data: Data, identifier: String) -> URL? {
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
    package static func jobPlists(_ labels: [String], runtimeRoot: URL) -> [String: String] {
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
