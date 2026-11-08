@testable import NeoSimulatorDeviceIO
@testable import NeoSimulatorKit
@testable import NeoSimulatorHostSupport
import Darwin
import Foundation
import Synchronization
import Testing

@Suite
struct BackgroundServicesTests {
    /// Answers launchctl like a simulator's launchd: overrides, loaded jobs, and the runtime's job plists.
    final class FakeLaunchd: Sendable {
        struct State {
            var disabled: Set<String> = []
            var loaded: Set<String>
            var commands: [[String]] = []
            var pauses: [Duration] = []
            var settlingReads = 0
        }
        let state: Mutex<State>
        let plists: [String: String]
        /// Jobs launchd re-enables but does not load in the current boot session.
        let loadsAtNextBoot: Set<String>
        /// Jobs whose override launchctl refuses to change.
        let refusing: Set<String>

        init(
            loaded: Set<String> = BackgroundServiceCatalog.builtIn.slimmable, disabled: Set<String> = [],
            plists: Set<String> = BackgroundServiceCatalog.builtIn.managed, loadsAtNextBoot: Set<String> = [],
             refusing: Set<String> = [], settlingReads: Int = 0) {
            state = Mutex(State(disabled: disabled, loaded: loaded, settlingReads: settlingReads))
            self.plists = Dictionary(uniqueKeysWithValues: plists.map { ($0, "/Runtime/System/Library/LaunchDaemons/\($0).plist") })
            self.loadsAtNextBoot = loadsAtNextBoot
            self.refusing = refusing
        }

        func backend(productFamily: String = "iPhone", catalog: BackgroundServiceCatalog = .builtIn)
            -> SimulatorBackgroundServiceBackend
        {
            SimulatorBackgroundServiceBackend(launchctl: { self.run($0) }, jobPlists: { labels in
                self.plists.filter { labels.contains($0.key) }
                }, pause: { delay in self.state.withLock { $0.pauses.append(delay) } }, productFamily: productFamily,
                catalog: catalog)
        }

        var disabled: Set<String> { state.withLock(\.disabled) }
        var loaded: Set<String> { state.withLock(\.loaded) }
        var commands: [[String]] { state.withLock(\.commands) }

        private func run(_ arguments: [String]) -> CommandOutput {
            state.withLock { state in
                state.commands.append(arguments)
                let label = { (path: String) in URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
                func output(_ status: Int32 = 0, _ text: String = "") -> CommandOutput {
                    CommandOutput(terminationStatus: status, stdout: Data(text.utf8), stderr: Data())
                }
                switch (arguments.first, arguments.dropFirst().first) {
                case ("print-disabled", _):
                    if state.settlingReads > 0 {
                        state.settlingReads -= 1
                        return CommandOutput(terminationStatus: 124, stdout: Data(),
                                             stderr: Data("Domain is tearing down".utf8))
                    }
                    return output(0, "disabled services = {\n" + state.disabled.sorted().map { "\t\"\($0)\" => disabled\n" }.joined() + "}\n")
                case ("list", _):
                    return output(0, "PID\tStatus\tLabel\n" + state.loaded.sorted().map { "-\t0\t\($0)\n" }.joined())
                case ("unload", _):
                    for name in arguments.dropFirst(2).map(label) where !refusing.contains(name) {
                        state.disabled.insert(name)
                        state.loaded.remove(name)
                    }
                    return output(refusing.isEmpty ? 0 : 1)
                case ("load", _):
                    for name in arguments.dropFirst(2).map(label) where !refusing.contains(name) {
                        state.disabled.remove(name)
                        if !loadsAtNextBoot.contains(name) { state.loaded.insert(name) }
                    }
                    return output()
                case ("disable", let target?), ("enable", let target?):
                    let name = String(target.dropFirst("system/".count))
                    if refusing.contains(name) { return CommandOutput(terminationStatus: 1, stdout: Data(), stderr: Data("refused".utf8)) }
                    if arguments[0] == "disable" { state.disabled.insert(name) } else { state.disabled.remove(name) }
                    return output()
                case ("bootout", let target?):
                    return output(state.loaded.remove(String(target.dropFirst("system/".count))) == nil ? 3 : 0)
                case ("bootstrap", _):
                    let name = label(arguments[2])
                    guard !loadsAtNextBoot.contains(name), state.loaded.insert(name).inserted else { return output(37) }
                    return output()
                default:
                    Issue.record("Unexpected launchctl \(arguments)")
                    return output(1)
                }
            }
        }
    }

    private func category(_ identifier: String) throws -> SimulatorBackgroundServiceCategory {
        try #require(BackgroundServiceCatalog.builtIn.category(identifier))
    }

    private static let sharedWithStore: Set<String> = ["com.apple.amsaccountsd", "com.apple.amsengagementd", "com.apple.amsondevicestoraged"]

    @Test func catalogNeverManagesServicesThatWedgeASimulator() {
        #expect(BackgroundServiceCatalog.builtIn.managed.isDisjoint(with: BackgroundServiceCatalog.wedgingLabels))
        for category in SimulatorBackgroundServiceCategory.all {
            let labels = category.services.map(\.label)
            #expect(Set(labels).count == labels.count, "\(category.id) lists a service twice")
            #expect(!category.consequence.isEmpty)
            for service in category.services {
                #expect(!service.summary.isEmpty && service.summary.count <= 90 && !service.summary.contains("\n"),
                        "\(service.label) needs a short one-line summary")
            }
            for required in category.requiredServices {
                #expect(
                    !BackgroundServiceCatalog.builtIn.slimmable.contains(required.label),
                    "\(required.label) is required")
            }
        }
    }

    @Test func categoryStateCountsServicesKeptForAnotherFullyEnabledCategory() throws {
        var icloud = try category("icloud")
        icloud.name = "Localized iCloud"
        let store = try category("store"), health = try category("health")
        let enabled = SimulatorBackgroundServices(disabled: [], loaded: [], productFamily: "iPhone")
        #expect(enabled.labelsKeptEnabled(disabling: [icloud], named: []) == Self.sharedWithStore)
        let icloudOnly = Set(icloud.services.map(\.label)).subtracting(Self.sharedWithStore)
        let slimICloud = SimulatorBackgroundServices(disabled: icloudOnly, loaded: [], productFamily: "iPhone")
        #expect(slimICloud.state(of: icloud) == .disabled)
        #expect(slimICloud.state(of: store) == .enabled)

        let storekit = SimulatorBackgroundServices(disabled: icloudOnly.union(["com.apple.storekitd"]), loaded: [], productFamily: "iPhone")
        #expect(storekit.state(of: icloud) == .partiallyDisabled)
        #expect(storekit.state(of: store) == .partiallyDisabled)

        let slimHealth = Set(health.services.map(\.label)).subtracting(["com.apple.homed"])
        #expect(SimulatorBackgroundServices(disabled: slimHealth, loaded: [], productFamily: "Apple Watch").state(of: health) == .disabled)
        #expect(SimulatorBackgroundServices(disabled: slimHealth, loaded: [], productFamily: "iPhone").state(of: health) == .partiallyDisabled)
    }

    @Test func disablingACategoryKeepsServicesAnotherEnabledCategoryNeeds() async throws {
        let icloud = try category("icloud")
        let withoutPlist = "com.apple.cloudd"
        let launchd = FakeLaunchd(plists: BackgroundServiceCatalog.builtIn.managed.subtracting([withoutPlist]))
        let update = try await launchd.backend().update([.category("icloud")], enabled: false)

        #expect(Set(update.stillEnabledLabels) == Self.sharedWithStore)
        let stopped = Set(icloud.services.map(\.label)).subtracting(Self.sharedWithStore)
        #expect(launchd.disabled == stopped)
        #expect(launchd.loaded.isDisjoint(with: stopped))
        #expect(update.services == SimulatorBackgroundServices(disabled: launchd.disabled, loaded: launchd.loaded, productFamily: "iPhone"))
        #expect(update.services.state(of: icloud) == .disabled)
        #expect(launchd.commands.contains(["disable", "system/" + withoutPlist]))
        #expect(launchd.commands.filter { $0.first == "disable" }.count == 1, "The batch unload stops every job with a plist")

        let named = try await launchd.backend().update([.service("com.apple.amsaccountsd")], enabled: false)
        #expect(named.stillEnabledLabels.isEmpty)
        #expect(launchd.disabled.contains("com.apple.amsaccountsd"))
    }

    @Test func aCatalogWithAnAddedCategoryChangesAndReadsItsServices() async throws {
        let label = "com.example.agent"
        let added = SimulatorBackgroundServiceCategory(
            id: "custom.agents", name: "Agents", summary: "", consequence: "",
            services: [.init(label, "")])
        let catalog = BackgroundServiceCatalog([added] + SimulatorBackgroundServiceCategory.all)
        let launchd = FakeLaunchd(
            loaded: BackgroundServiceCatalog.builtIn.slimmable.union([label]),
            plists: catalog.managed)
        let update = try await launchd.backend(catalog: catalog).update([.category(added.id)], enabled: false)
        #expect(launchd.disabled == [label] && update.services.disabledLabels == [label])
        #expect(update.services.state(of: added) == .disabled)
    }

    @Test func requiredServicesAreKeptRunningWhenNamed() async throws {
        let launchd = FakeLaunchd()
        let update = try await launchd.backend(productFamily: "Apple Watch")
            .update([.service("com.apple.sharingd"), .service("com.apple.homed")], enabled: false)
        #expect(update.stillEnabledLabels == ["com.apple.homed", "com.apple.sharingd"])
        #expect(launchd.disabled.isEmpty)
    }

    @Test func enablingReportsServicesThatStartAtTheNextBoot() async throws {
        let search = Set(try category("search").services.map(\.label))
        let launchd = FakeLaunchd(loaded: [], disabled: search, plists: search.subtracting(["com.apple.searchtoold"]),
                                  loadsAtNextBoot: ["com.apple.searchd"])
        let update = try await launchd.backend().update([.category("search")], enabled: true)

        #expect(launchd.disabled.isEmpty)
        #expect(update.notStartedLabels == ["com.apple.searchd"])
        #expect(update.services.state(of: try category("search")) == .enabled)
    }

    @Test func aFailedChangeReportsTheStateAfterTheAttempt() async throws {
        let search = Set(try category("search").services.map(\.label))
        let launchd = FakeLaunchd(refusing: ["com.apple.searchd"])
        let error = await #expect(throws: SimulatorBackgroundServicesUpdateFailure.self) {
            try await launchd.backend().update([.category("search")], enabled: false)
        }
        let failure = try #require(error)
        #expect(failure.services?.disabledLabels == search.subtracting(["com.apple.searchd"]))
        #expect(failure.failureReason?.contains("com.apple.searchd") == true)
        #expect(launchd.commands.filter { $0 == ["disable", "system/com.apple.searchd"] }.count == SimulatorBackgroundServiceBackend.transitionPasses)
    }

    /// `bootout` runs in an owned child that never exits by itself, and `disable` finished before it started.
    @Test(.timeLimit(.minutes(1))) func cancellingAStartedChangeReportsTheStoppedCommandAndWhatFinished() async throws {
        let directory = try TemporaryTestDirectory()
        let held = try HeldChildren(in: directory.url)
        defer { held.release() }
        let command = try held.command(then: "", policy: .backgroundServiceCommand)
        let label = "com.apple.searchd"
        let launchd = FakeLaunchd()
        let answering = launchd.backend().launchctl
        let backend = SimulatorBackgroundServiceBackend(launchctl: { arguments in
            guard arguments == ["bootout", "system/" + label] else { return try await answering(arguments) }
            return try await SystemCommandRunner().run(command)
        }, jobPlists: { _ in [:] }, pause: { _ in }, productFamily: "iPhone")
        let change = Task { try await backend.update([.service(label)], enabled: false) }
        let identifier = try #require(try await held.waitUntilStarted(1).first)
        change.cancel()
        let failure = try await #require(throws: SimulatorBackgroundServicesUpdateFailure.self) { try await change.value }
        #expect(kill(identifier, 0) == -1 && errno == ESRCH)
        let reason = try #require(failure.failureReason)
        #expect(reason.contains("bootout \(label): sh was stopped before it finished, so what it changed is unknown."))
        #expect(reason.contains("Finished: disable \(label)."))
        #expect(failure.underlyingError.technicalDetails.hasPrefix("background-service-stopped: "))
        #expect(failure.services?.disabledLabels == [label])
        // The cancelled change does not start another pass.
        #expect(launchd.commands.filter { $0 == ["disable", "system/" + label] }.count == 1)
    }

    /// A batch's exit status is not trusted, but a chunk that was stopped still leaves its outcome unknown.
    @Test(.timeLimit(.minutes(1))) func cancellingAStartedBatchIsNotReportedAsPlainCancellation() async throws {
        let directory = try TemporaryTestDirectory()
        let held = try HeldChildren(in: directory.url)
        defer { held.release() }
        let command = try held.command(then: "", policy: .backgroundServiceCommand)
        let label = "com.apple.searchd"
        let launchd = FakeLaunchd()
        let answering = launchd.backend()
        let backend = SimulatorBackgroundServiceBackend(launchctl: { arguments in
            guard arguments.first == "unload" else { return try await answering.launchctl(arguments) }
            return try await SystemCommandRunner().run(command)
        }, jobPlists: answering.jobPlists, pause: { _ in }, productFamily: "iPhone")
        let change = Task { try await backend.update([.service(label)], enabled: false) }
        let identifier = try #require(try await held.waitUntilStarted(1).first)
        change.cancel()
        let failure = try await #require(throws: SimulatorBackgroundServicesUpdateFailure.self) { try await change.value }
        #expect(kill(identifier, 0) == -1 && errno == ESRCH)
        #expect(failure.failureReason?.contains("unload 1 services: sh was stopped before it finished") == true)
    }

    @Test func cancellingBeforeAnyChangeRanEndsAsCancellation() async throws {
        let launchd = FakeLaunchd(plists: [])
        let backend = launchd.backend()
        let change = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await backend.update([.service("com.apple.searchd")], enabled: false)
        }
        await #expect(throws: CancellationError.self) { try await change.value }
        #expect(launchd.disabled.isEmpty)
    }

    /// A read leaves nothing to account for, and retrying it would only delay the caller.
    @Test(.timeLimit(.minutes(1))) func stoppingALiveStyleReadEndsItWithoutARetry() async throws {
        let directory = try TemporaryTestDirectory()
        let held = try HeldChildren(in: directory.url)
        defer { held.release() }
        let command = try held.command(then: "", policy: .backgroundServiceCommand)
        let pauses = Mutex(0)
        let backend = SimulatorBackgroundServiceBackend(launchctl: { _ in try await SystemCommandRunner().run(command) },
            jobPlists: { _ in nil }, pause: { _ in pauses.withLock { $0 += 1 } }, productFamily: "iPhone")
        let reading = Task { try await backend.read() }
        _ = try await held.waitUntilStarted(1)
        reading.cancel()
        await #expect(throws: CancellationError.self) { try await reading.value }
        #expect(pauses.withLock { $0 } == 0)
    }

    @Test func readsWaitWhileLaunchdStartsABootSession() async throws {
        let launchd = FakeLaunchd(disabled: ["com.apple.searchd"], settlingReads: 2)
        let services = try await launchd.backend().read()
        #expect(services.disabledLabels == ["com.apple.searchd"])
        #expect(launchd.state.withLock(\.pauses) == Array(SimulatorBackgroundServiceBackend.retryDelays.prefix(2)))
        #expect(SimulatorBackgroundServiceBackend.parseDisabled("\t\"com.apple.a\" => true\n\t\"com.apple.b\" => false\n") == ["com.apple.a"])
    }

    @Test func jobPlistsAreFoundByTheLabelTheyDefine() throws {
        let root = try TemporaryTestDirectory()
        func write(_ label: String, to path: String) throws -> String {
            let url = root.url.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: ["Label": label], format: .binary, options: 0).write(to: url)
            return url.path
        }
        let renamed = try write("com.apple.imcore.imtransferagent", to: "System/Library/LaunchDaemons/com.apple.imtransferagent.plist")
        let agent = try write("com.apple.cloudd", to: "System/Library/LaunchAgents/com.apple.cloudd.plist")
        _ = try write("com.apple.searchd.helper", to: "System/Library/LaunchDaemons/com.apple.searchd.plist")

        let plists = SimulatorBackgroundServiceBackend.jobPlists(
            ["com.apple.imcore.imtransferagent", "com.apple.cloudd", "com.apple.searchd"], runtimeRoot: root.url)
        #expect(plists == ["com.apple.imcore.imtransferagent": renamed, "com.apple.cloudd": agent])
    }
}
