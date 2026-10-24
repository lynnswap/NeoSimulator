import AppKit
import Foundation

struct RunningApplication: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let bundleURL: URL?

    init(
        processIdentifier: pid_t,
        bundleURL: URL?,
        bundleIdentifier: String? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
    }
}

struct RendererOwnerIdentity: Equatable, Sendable {
    let processIdentifier: pid_t
    let launchDate: Date

    @MainActor static func current() throws -> Self {
        let application = NSRunningApplication.current
        guard let launchDate = application.launchDate else {
            throw CLIError.unavailable("renderer-owner", "The manager's launch identity could not be read.")
        }
        return Self(processIdentifier: application.processIdentifier, launchDate: launchDate)
    }
}

enum HostTerminationRequest: Sendable {
    case normalQuit
    case rendererHandoff
    case deviceHubHandoff

    func perform(processIdentifier: pid_t, normalQuit: () -> Bool) -> Bool {
        switch self {
        case .normalQuit: normalQuit()
        case .rendererHandoff: kill(processIdentifier, SIGTERM) == 0
        // Device Hub can acknowledge forceTerminate without exiting. SIGKILL bypasses its guest-shutdown handlers.
        case .deviceHubHandoff: kill(processIdentifier, SIGKILL) == 0
        }
    }
}

private struct ManagedApplicationIdentity {
    let displayName: String
    let bundleIdentifier: String
    let expectedURLs: [URL]
    let errorIdentifier: String
    var terminationRequest: HostTerminationRequest = .normalQuit
}

private let neoHostStartupPayload = Data("ready\n".utf8)

@MainActor
private final class ApplicationTerminationWaiter {
    private let application: NSRunningApplication
    private let identity: ManagedApplicationIdentity
    private let timeoutInterval: TimeInterval?
    private var observation: NSKeyValueObservation?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var cancellationRequested = false
    private var timeoutTimer: Timer?

    init(
        application: NSRunningApplication,
        identity: ManagedApplicationIdentity,
        timeoutInterval: TimeInterval?
    ) {
        self.application = application
        self.identity = identity
        self.timeoutInterval = timeoutInterval
    }

    func terminate(request: (() throws -> Bool)? = nil) async throws {
        guard !application.isTerminated else {
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if cancellationRequested {
                    finish(.failure(CancellationError()))
                    return
                }

                // terminate() confirms the request; isTerminated confirms the exit.
                observation = application.observe(
                    \.isTerminated,
                    options: [.new]
                ) { [weak self] application, _ in
                    guard application.isTerminated else {
                        return
                    }
                    Task { @MainActor in
                        self?.finish(.success(()))
                    }
                }
                if let timeoutInterval {
                    let timeoutTimer = Timer(
                        timeInterval: timeoutInterval,
                        repeats: false
                    ) { [weak self] _ in
                        Task { @MainActor in
                            guard let self else {
                                return
                            }
                            self.finish(
                                .failure(
                                    CLIError.temporary(
                                        "\(self.identity.errorIdentifier)-termination-timeout",
                                        "\(self.identity.displayName) pid \(self.application.processIdentifier) did not finish terminating before the operation deadline"
                                    )
                                )
                            )
                        }
                    }
                    self.timeoutTimer = timeoutTimer
                    RunLoop.main.add(timeoutTimer, forMode: .common)
                }

                if application.isTerminated {
                    finish(.success(()))
                    return
                }

                let requested: Bool
                do {
                    requested = try request?() ?? identity.terminationRequest.perform(
                        processIdentifier: application.processIdentifier,
                        normalQuit: { application.terminate() }
                    )
                } catch {
                    finish(.failure(error))
                    return
                }
                if !requested {
                    RunLoop.main.perform(inModes: [.common]) { [weak self] in
                        Task { @MainActor in
                            guard let self else {
                                return
                            }
                            if !self.application.isTerminated {
                                self.finish(
                                    .failure(
                                        CLIError.temporary(
                                            "\(self.identity.errorIdentifier)-termination",
                                            "\(self.identity.displayName) pid \(self.application.processIdentifier) did not accept the termination request"
                                        )
                                    )
                                )
                            } else {
                                self.finish(.success(()))
                            }
                        }
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancel()
            }
        }
    }

    private func cancel() {
        cancellationRequested = true
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Void, any Error>) {
        guard let continuation else {
            return
        }
        observation?.invalidate()
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        self.observation = nil
        self.continuation = nil
        continuation.resume(with: result)
    }
}

struct WorkspaceClient: Sendable {
    var runningXcodes: @MainActor @Sendable () -> [RunningApplication]
    var runningNeoHosts: @MainActor @Sendable () -> [RunningApplication]
    var terminateDeviceHubs: @MainActor @Sendable (URL) async throws -> Int
    var terminateNeoHosts: @MainActor @Sendable (URL) async throws -> Int
    var openNeoHost: @MainActor @Sendable (URL, URL, String?) async throws -> URL

    var openDeviceHub: @MainActor @Sendable (URL) async throws -> URL
    var quitNeoHost: @MainActor @Sendable (URL, [RendererRegistration], Bool?) async throws -> Int

    @MainActor static let live = WorkspaceClient(
        runningXcodes: {
            runningApplications(
                withBundleIdentifier: ToolConstants.xcodeBundleIdentifier
            )
        },
        runningNeoHosts: {
            runningApplications(
                withBundleIdentifier: ToolConstants.neoHostBundleIdentifier
            )
        },
        terminateDeviceHubs: { expectedApplicationURL in
            let running = runningApplications(withBundleIdentifier: ToolConstants.deviceHubBundleIdentifier)
            var expectedURLs = [expectedApplicationURL]
            for application in running {
                guard let url = application.bundleURL else {
                    throw CLIError.configuration("device-hub-identity", "A running Device Hub has no application URL.")
                }
                try CodeSignatureValidator.live.validateAppleApplication(url, ToolConstants.deviceHubBundleIdentifier)
                expectedURLs.append(url)
            }
            return try await terminateApplications(
                ManagedApplicationIdentity(displayName: "Device Hub", bundleIdentifier: ToolConstants.deviceHubBundleIdentifier,
                    expectedURLs: expectedURLs, errorIdentifier: "device-hub", terminationRequest: .deviceHubHandoff)
            )
        },
        terminateNeoHosts: { expectedApplicationURL in
            try await terminateApplications(
                ManagedApplicationIdentity(
                    displayName: "NeoSimulator",
                    bundleIdentifier: ToolConstants.neoHostBundleIdentifier,
                    expectedURLs: [expectedApplicationURL],
                    errorIdentifier: "neo-host",
                    terminationRequest: .rendererHandoff
                )
            )
        },
        openNeoHost: { applicationURL, xcodeURL, deviceIdentifier in
            guard Bundle(url: applicationURL)?.bundleIdentifier
                    == ToolConstants.neoHostBundleIdentifier
            else {
                throw CLIError.configuration(
                    "neo-host-bundle",
                    "refusing to launch \(applicationURL.path) because it is not \(ToolConstants.neoHostBundleIdentifier)"
                )
            }

            try await waitForPreviousRendererOwners(at: applicationURL)
            try Task.checkCancellation()
            let startupDirectory = try makeNeoHostStartupDirectory()
            defer {
                try? FileManager.default.removeItem(at: startupDirectory)
            }
            let startupResultURL = startupDirectory.appendingPathComponent(
                "result",
                isDirectory: false
            )

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = true
            configuration.allowsRunningApplicationSubstitution = false
            configuration.arguments = rendererLaunchArguments(owner: try RendererOwnerIdentity.current(),
                startupResultURL: startupResultURL, xcodeURL: xcodeURL, deviceIdentifier: deviceIdentifier)

            let application = try await NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            )
            let identity = ManagedApplicationIdentity(
                displayName: "NeoSimulator",
                bundleIdentifier: ToolConstants.neoHostBundleIdentifier,
                expectedURLs: [applicationURL],
                errorIdentifier: "neo-host",
                terminationRequest: .rendererHandoff
            )
            do {
                guard application.bundleIdentifier
                        == ToolConstants.neoHostBundleIdentifier
                else {
                    throw CLIError.configuration(
                        "neo-host-identifier",
                        "LaunchServices opened pid \(application.processIdentifier) with bundle identifier \(application.bundleIdentifier ?? "unknown"); expected \(ToolConstants.neoHostBundleIdentifier)"
                    )
                }
                guard let openedURL = application.bundleURL else {
                    throw CLIError.io(
                        "neo-host-launch",
                        "LaunchServices opened the standalone simulator host without a bundle URL"
                    )
                }

                let expected = normalized(applicationURL)
                let observed = normalized(openedURL)
                guard observed == expected else {
                    throw CLIError.configuration(
                        "neo-host-substitution",
                        "requested \(expected.path), but LaunchServices opened \(observed.path)"
                    )
                }
                try await waitForNeoHostStartup(
                    application,
                    resultURL: startupResultURL
                )
                return observed
            } catch let launchError {
                guard application.bundleIdentifier == ToolConstants.neoHostBundleIdentifier,
                      application.bundleURL.map(normalized) == normalized(applicationURL) else { throw launchError }
                let waiter = ApplicationTerminationWaiter(
                    application: application,
                    identity: identity,
                    timeoutInterval: 10
                )
                do {
                    try await waiter.terminate()
                } catch let terminationError {
                    throw CLIError.temporary(
                        "neo-host-launch-cleanup",
                        "NeoSimulator launch failed (\(launchError.localizedDescription)), and pid \(application.processIdentifier) could not be terminated (\(terminationError.localizedDescription))"
                    )
                }
                throw launchError
            }
        },
        openDeviceHub: { applicationURL in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.allowsRunningApplicationSubstitution = false
            let app = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
            guard app.bundleIdentifier == ToolConstants.deviceHubBundleIdentifier,
                  app.bundleURL.map(normalized) == normalized(applicationURL) else {
                throw CLIError.configuration("device-hub-substitution", "LaunchServices opened an unexpected Device Hub application")
            }
            return applicationURL
        },
        // Normal quit can wait for recordings, device shutdown, and error alerts.
        quitNeoHost: { applicationURL, registrations, keepingDevicesRunning in
            try await terminateApplications(ManagedApplicationIdentity(
                displayName: "NeoSimulator", bundleIdentifier: ToolConstants.neoHostBundleIdentifier,
                expectedURLs: [applicationURL], errorIdentifier: "neo-host"
            ), timeoutInterval: nil, processIdentifiers: Set(registrations.map(\.processIdentifier)), requestTermination: { application in
                guard let registration = registrations.first(where: { $0.processIdentifier == application.processIdentifier }) else {
                    throw CLIError.temporary("renderer-registration", "A renderer is still starting. Try quitting again when it is ready.")
                }
                var info: [String: Any] = ["action": "quit"]
                if let keepingDevicesRunning { info["keepRunning"] = keepingDevicesRunning }
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("dev.lynnswap.NeoSimulator.RendererRequest"), object: registration.sessionIdentifier,
                    userInfo: info, deliverImmediately: true
                )
                return true
            })
        }

    )

    @MainActor private static func waitForPreviousRendererOwners(at applicationURL: URL) async throws {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: ToolConstants.neoHostBundleIdentifier)
            .filter { !$0.isTerminated }
        let snapshots = applications.map {
            RunningApplication(processIdentifier: $0.processIdentifier, bundleURL: $0.bundleURL, bundleIdentifier: $0.bundleIdentifier)
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NeoSimulator/renderers")
        try await waitForPreviousRendererOwners(at: applicationURL, applications: snapshots, registration: { application in
            let data: Data
            do { data = try Data(contentsOf: directory.appendingPathComponent("\(application.processIdentifier).json")) }
            catch CocoaError.fileReadNoSuchFile { return nil }
            return try JSONDecoder().decode(RendererRegistration.self, from: data)
        }, ownerIsAbsent: { owner in
            if let application = NSRunningApplication(processIdentifier: owner.processIdentifier) {
                if application.isTerminated { return true }
                guard let launchDate = application.launchDate else { return false }
                return launchDate != owner.launchDate
            }
            // An unregistered app can still be alive during AppKit teardown. Only ESRCH
            // establishes process death when LaunchServices has no identity to compare.
            return kill(owner.processIdentifier, 0) == -1 && errno == ESRCH
        }, waitForTermination: { snapshot in
            guard let application = applications.first(where: { $0.processIdentifier == snapshot.processIdentifier }) else { return }
            let waiter = ApplicationTerminationWaiter(application: application,
                identity: ManagedApplicationIdentity(displayName: "The previous NeoSimulator renderer",
                    bundleIdentifier: ToolConstants.neoHostBundleIdentifier, expectedURLs: [applicationURL],
                    errorIdentifier: "previous-renderer"), timeoutInterval: 70)
            // Observe only. Its existing owner-loss monitor owns cleanup and the 60s fallback.
            try await waiter.terminate(request: { true })
        })
    }

    @MainActor static func waitForPreviousRendererOwners(at applicationURL: URL, applications: [RunningApplication],
        registration: (RunningApplication) throws -> RendererRegistration?,
        ownerIsAbsent: (RendererOwnerIdentity) -> Bool,
        waitForTermination: (RunningApplication) async throws -> Void) async throws {
        for application in applications where application.bundleIdentifier == ToolConstants.neoHostBundleIdentifier
            && application.bundleURL.map(normalized) == normalized(applicationURL) {
            try Task.checkCancellation()
            guard let record = try registration(application) else { continue }
            guard record.processIdentifier == application.processIdentifier,
                  normalized(URL(fileURLWithPath: record.applicationPath)) == normalized(applicationURL) else {
                throw CLIError.configuration("renderer-registration", "The renderer registration does not match its running application.")
            }
            guard let pid = record.ownerProcessIdentifier, let launchDate = record.ownerLaunchDate,
                  ownerIsAbsent(RendererOwnerIdentity(processIdentifier: pid, launchDate: launchDate)) else { continue }
            try await waitForTermination(application)
        }
    }

    static func rendererLaunchArguments(owner: RendererOwnerIdentity, startupResultURL: URL,
                                        xcodeURL: URL, deviceIdentifier: String?) -> [String] {
        var arguments = ["--managed", "--owner-pid", String(owner.processIdentifier),
                         "--owner-launch-date", String(owner.launchDate.timeIntervalSinceReferenceDate),
                         "--startup-result", startupResultURL.path, "--xcode", xcodeURL.path]
        if let deviceIdentifier { arguments += ["--device", deviceIdentifier] }
        return arguments
    }

    @MainActor private static func runningApplications(
        withBundleIdentifier bundleIdentifier: String
    ) -> [RunningApplication] {
        NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).filter { !$0.isTerminated }.map {
            RunningApplication(
                processIdentifier: $0.processIdentifier,
                bundleURL: $0.bundleURL,
                bundleIdentifier: $0.bundleIdentifier
            )
        }
    }

    @MainActor private static func terminateApplications(
        _ identity: ManagedApplicationIdentity,
        timeoutInterval: TimeInterval? = 10,
        processIdentifiers: Set<pid_t>? = nil,
        requestTermination: ((NSRunningApplication) throws -> Bool)? = nil
    ) async throws -> Int {
        let expected = Set(identity.expectedURLs.map(normalized))
        let clock = ContinuousClock()
        let deadline = timeoutInterval.map { clock.now.advanced(by: .seconds($0)) }
        var terminatedCount = 0

        while true {
            let applications = NSRunningApplication.runningApplications(
                withBundleIdentifier: identity.bundleIdentifier
            ).filter { !$0.isTerminated && (processIdentifiers?.contains($0.processIdentifier) ?? true) }
            guard !applications.isEmpty else {
                return terminatedCount
            }

            for application in applications {
                guard application.bundleIdentifier == identity.bundleIdentifier else {
                    throw CLIError.configuration(
                        "\(identity.errorIdentifier)-identity",
                        "refusing to terminate \(identity.displayName) pid \(application.processIdentifier) because its bundle identifier is \(application.bundleIdentifier ?? "unknown")"
                    )
                }
                guard let bundleURL = application.bundleURL else {
                    throw CLIError.configuration(
                        "\(identity.errorIdentifier)-identity",
                        "refusing to terminate \(identity.displayName) pid \(application.processIdentifier) because it has no bundle URL"
                    )
                }
                let observed = normalized(bundleURL)
                guard expected.contains(observed) else {
                    let allowedPaths = expected.map(\.path).sorted().joined(separator: ", ")
                    throw CLIError.configuration(
                        "\(identity.errorIdentifier)-substitution",
                        "refusing to terminate \(identity.displayName) pid \(application.processIdentifier) from \(observed.path); expected one of: \(allowedPaths)"
                    )
                }
            }

            for application in applications {
                let remainingTimeout: TimeInterval?
                if let deadline {
                    let remaining = clock.now.duration(to: deadline)
                    guard remaining > .zero else {
                        throw CLIError.temporary(
                            "\(identity.errorIdentifier)-termination-timeout",
                            "\(identity.displayName) kept running or relaunching until the operation deadline."
                        )
                    }
                    let components = remaining.components
                    remainingTimeout = TimeInterval(components.seconds)
                        + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
                } else {
                    remainingTimeout = nil
                }
                let waiter = ApplicationTerminationWaiter(
                    application: application,
                    identity: identity,
                    timeoutInterval: remainingTimeout
                )
                if let requestTermination {
                    // Observe termination before delivering the session-specific quit policy.
                    try await waiter.terminate(request: { try requestTermination(application) })
                } else {
                    try await waiter.terminate()
                }
                terminatedCount += 1
            }
        }
    }

    @MainActor private static func makeNeoHostStartupDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(ToolConstants.name)-startup-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw CLIError.cannotCreate(
                "neo-host-startup-directory",
                "could not create the NeoSimulator startup directory: \(error.localizedDescription)"
            )
        }
        return directory
    }

    @MainActor private static func waitForNeoHostStartup(
        _ application: NSRunningApplication,
        resultURL: URL
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))

        while clock.now < deadline {
            guard !application.isTerminated else {
                throw CLIError.temporary(
                    "neo-host-startup",
                    "NeoSimulator exited before startup completed"
                )
            }

            if FileManager.default.fileExists(atPath: resultURL.path) {
                let result: Data
                do {
                    result = try Data(contentsOf: resultURL)
                } catch {
                    throw CLIError.io(
                        "neo-host-startup-result",
                        "could not read the NeoSimulator startup result: \(error.localizedDescription)"
                    )
                }
                guard result == neoHostStartupPayload else {
                    throw CLIError.configuration(
                        "neo-host-startup-result",
                        "NeoSimulator wrote an invalid startup result"
                    )
                }
                await Task.yield()
                guard !application.isTerminated else {
                    throw CLIError.temporary(
                        "neo-host-startup",
                        "NeoSimulator exited during startup"
                    )
                }
                return
            }

            try await Task.sleep(for: .milliseconds(50))
        }

        throw CLIError.temporary(
            "neo-host-startup-timeout",
            "NeoSimulator did not finish startup within 10 seconds"
        )
    }

    @MainActor private static func normalized(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}

@MainActor
final class RendererDeviceRequestWaiter {
    typealias ScheduleTimeout = @MainActor (Duration, @escaping @MainActor () -> Void) -> () -> Void
    private let scheduleTimeout: ScheduleTimeout
    private let acknowledgements: NotificationCenter
    private let send: @MainActor ([String: String], String) -> Void

    init(acknowledgements: NotificationCenter = DistributedNotificationCenter.default(),
         scheduleTimeout: @escaping ScheduleTimeout = RendererDeviceRequestWaiter.scheduleDeadline,
         send: @escaping @MainActor ([String: String], String) -> Void = { info, sessionIdentifier in
             DistributedNotificationCenter.default().postNotificationName(
                 Notification.Name("dev.lynnswap.NeoSimulator.RendererRequest"), object: sessionIdentifier,
                 userInfo: info, deliverImmediately: true)
         }) {
        self.acknowledgements = acknowledgements
        self.scheduleTimeout = scheduleTimeout
        self.send = send
    }

    private var observer: NSObjectProtocol?
    private var cancelTimeout: (() -> Void)?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var handled = true

    func release(_ deviceID: DeviceInventoryID, from renderer: RendererRegistration) async throws {
        try await request("release-device", acknowledgement: "RendererReleased", deviceID: deviceID, renderer: renderer, timeoutSeconds: 120)
    }

    func restart(_ deviceID: DeviceInventoryID, in renderer: RendererRegistration, erasing: Bool) async throws -> Bool {
        try await request(erasing ? "erase-device" : "restart-device", acknowledgement: "RendererManaged", deviceID: deviceID, renderer: renderer, timeoutSeconds: 450)
        return handled
    }

    func open(_ deviceID: DeviceInventoryID, in renderer: RendererRegistration) async throws {
        try await request("open-device", acknowledgement: "RendererOpened", deviceID: deviceID, renderer: renderer, timeoutSeconds: 450)
    }

    func attach(_ deviceID: DeviceInventoryID, in renderer: RendererRegistration) async throws {
        try await request("attach-device", acknowledgement: "RendererOpened", deviceID: deviceID, renderer: renderer, timeoutSeconds: 450)
    }

    private func request(_ action: String, acknowledgement: String, deviceID: DeviceInventoryID, renderer: RendererRegistration, timeoutSeconds: Int) async throws {
        let (identifier, deviceSetPath) = try deviceID.simulatorAddress
        try Task.checkCancellation()
        let requestIdentifier = UUID().uuidString
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                observer = acknowledgements.addObserver(
                    forName: Notification.Name("dev.lynnswap.NeoSimulator.\(acknowledgement)"),
                    object: requestIdentifier, queue: .main
                ) { [weak self] notification in
                    let releasedIdentifier = notification.userInfo?["udid"] as? String
                    let acknowledgedSet = notification.userInfo?["deviceSetPath"] as? String
                    let failure = notification.userInfo?["error"] as? String
                    let handled = notification.userInfo?["handled"] as? Bool ?? true
                    Task { @MainActor in
                        guard releasedIdentifier == identifier, acknowledgedSet == deviceSetPath else { return }
                        if let failure {
                            self?.finish(.failure(CLIError.temporary("renderer-device-request", failure)))
                        } else {
                            self?.handled = handled
                            self?.finish(.success(()))
                        }
                    }
                }
                cancelTimeout = scheduleTimeout(.seconds(timeoutSeconds)) { [weak self] in
                    self?.finish(.failure(CLIError.temporary("renderer-device-timeout", "The simulator display did not finish the device request.")))
                }
                var info = ["action": action, "udid": identifier, "requestIdentifier": requestIdentifier]
                if let deviceSetPath { info["deviceSetPath"] = deviceSetPath }
                send(info, renderer.sessionIdentifier)
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        if let observer { acknowledgements.removeObserver(observer) }
        observer = nil
        cancelTimeout?()
        cancelTimeout = nil
        continuation.resume(with: result)
    }

    private static func scheduleDeadline(_ duration: Duration, action: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task {
            do { try await Task.sleep(for: duration) } catch { return }
            action()
        }
        return { task.cancel() }
    }

}
