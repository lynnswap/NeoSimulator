import AppKit
import Foundation
import NeoSimulatorDeviceIO
import NeoSimulatorKit
import NeoSimulatorUI

package struct RunningApplication: Equatable, Sendable {
    package let processIdentifier: pid_t
    package let bundleIdentifier: String?
    package let bundleURL: URL?

    package init(
        processIdentifier: pid_t,
        bundleURL: URL?,
        bundleIdentifier: String? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
    }
}

package enum HostTerminationRequest: Sendable {
    case normalQuit
    case rendererHandoff
    case deviceHubHandoff

    package func perform(processIdentifier: pid_t, normalQuit: () -> Bool) -> Bool {
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

/// The startup result exchanged by the manager and its bundled renderer.
package enum RendererStartupResult: Codable, Sendable {
    case ready
    case failed(message: String, recoverySuggestion: String?)
}

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
                                    HostOperationError.temporary(
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
                                        HostOperationError.temporary(
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

package struct WorkspaceClient: Sendable {
    package var runningXcodes: @MainActor @Sendable () -> [RunningApplication]
    package var runningNeoHosts: @MainActor @Sendable () -> [RunningApplication]
    package var terminateDeviceHubs: @MainActor @Sendable (URL) async throws -> Int
    package var terminateNeoHosts: @MainActor @Sendable (URL) async throws -> Int
    package var openNeoHost: @MainActor @Sendable (URL, URL, String?) async throws -> URL

    package var openDeviceHub: @MainActor @Sendable (URL) async throws -> URL
    package var quitNeoHost: @MainActor @Sendable (URL, [RendererRegistration], Bool?) async throws -> Int
    package var prepareDeviceHubCompanion: @MainActor @Sendable (URL) async throws -> Void = { _ in }
    package var stopDeviceHubCompanions: @MainActor @Sendable () async throws -> Void = {}

    @MainActor package static var live: WorkspaceClient { live(headlessRenderers: false) }

    @MainActor package static func live(headlessRenderers: Bool, deviceHubCompanions: DeviceHubCompanions? = nil)
        -> WorkspaceClient
    {
        WorkspaceClient(
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
                    throw HostOperationError.configuration("device-hub-identity", "A running Device Hub has no application URL.")
                }
                try CodeSignatureValidator.live.validateAppleApplication(url, ToolConstants.deviceHubBundleIdentifier)
                expectedURLs.append(url)
            }
                let competing = running.filter {
                    !(deviceHubCompanions?.allows(processIdentifier: $0.processIdentifier, bundleURL: $0.bundleURL)
                        ?? false)
                }
            return try await terminateApplications(
                ManagedApplicationIdentity(displayName: "Device Hub", bundleIdentifier: ToolConstants.deviceHubBundleIdentifier,
                        expectedURLs: expectedURLs, errorIdentifier: "device-hub", terminationRequest: .deviceHubHandoff
                    ),
                    processIdentifiers: Set(competing.map(\.processIdentifier))
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
                try await deviceHubCompanions?.start(at: xcodeURL.appendingPathComponent(ToolConstants.deviceHubPath))
            guard Bundle(url: applicationURL)?.bundleIdentifier
                    == ToolConstants.neoHostBundleIdentifier
            else {
                throw HostOperationError.configuration(
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
            configuration.activates = !headlessRenderers
            configuration.createsNewApplicationInstance = true
            configuration.allowsRunningApplicationSubstitution = false
            configuration.arguments = rendererLaunchArguments(owner: try RendererOwnerIdentity.current(),
                startupResultURL: startupResultURL, xcodeURL: xcodeURL, deviceIdentifier: deviceIdentifier, headless: headlessRenderers)

            try Task.checkCancellation()
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
                    throw HostOperationError.configuration(
                        "neo-host-identifier",
                        "LaunchServices opened pid \(application.processIdentifier) with bundle identifier \(application.bundleIdentifier ?? "unknown"); expected \(ToolConstants.neoHostBundleIdentifier)"
                    )
                }
                guard let openedURL = application.bundleURL else {
                    throw HostOperationError.io(
                        "neo-host-launch",
                        "LaunchServices opened the standalone simulator host without a bundle URL"
                    )
                }

                let expected = normalized(applicationURL)
                let observed = normalized(openedURL)
                guard observed == expected else {
                    throw HostOperationError.configuration(
                        "neo-host-substitution",
                        "requested \(expected.path), but LaunchServices opened \(observed.path)"
                    )
                }
                try await waitForNeoHostStartup(resultURL: startupResultURL, processIdentifier: application.processIdentifier,
                                                isTerminated: { application.isTerminated })
                try Task.checkCancellation()
                return observed
            } catch let launchError {
                guard application.bundleIdentifier == ToolConstants.neoHostBundleIdentifier,
                      application.bundleURL.map(normalized) == normalized(applicationURL) else { throw launchError }
                let waiter = ApplicationTerminationWaiter(
                    application: application,
                    identity: identity,
                    timeoutInterval: 10
                )
                try await finishFailedNeoHostLaunch(launchError, processIdentifier: application.processIdentifier) {
                    try await waiter.terminate()
                }
            }
        },
        openDeviceHub: { applicationURL in
                try await deviceHubCompanions?.stop()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.allowsRunningApplicationSubstitution = false
            try Task.checkCancellation()
            let app = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
            guard app.bundleIdentifier == ToolConstants.deviceHubBundleIdentifier,
                  app.bundleURL.map(normalized) == normalized(applicationURL) else {
                throw HostOperationError.configuration("device-hub-substitution", "LaunchServices opened an unexpected Device Hub application")
            }
            // LaunchServices has already committed this external launch; it may be a shared instance.
            try Task.checkCancellation()
            return applicationURL
        },
        // Normal quit can wait for recordings, device shutdown, and error alerts.
        quitNeoHost: { applicationURL, registrations, keepingDevicesRunning in
            try await terminateApplications(ManagedApplicationIdentity(
                displayName: "NeoSimulator", bundleIdentifier: ToolConstants.neoHostBundleIdentifier,
                expectedURLs: [applicationURL], errorIdentifier: "neo-host"
            ), timeoutInterval: nil, processIdentifiers: Set(registrations.map(\.processIdentifier)), requestTermination: { application in
                guard let registration = registrations.first(where: { $0.processIdentifier == application.processIdentifier }) else {
                    throw HostOperationError.temporary("renderer-registration", "A renderer is still starting. Try quitting again when it is ready.")
                }
                var info: [String: Any] = ["action": "quit"]
                if let keepingDevicesRunning { info["keepRunning"] = keepingDevicesRunning }
                DistributedNotificationCenter.default().postNotificationName(
                    RendererRequest.notificationName, object: registration.sessionIdentifier,
                    userInfo: info, deliverImmediately: true
                )
                return true
            })
            },
            prepareDeviceHubCompanion: { try await deviceHubCompanions?.start(at: $0) },
            stopDeviceHubCompanions: { try await deviceHubCompanions?.stop() }

    ) }

    @MainActor package static func terminateDeviceHubCompanion(_ application: NSRunningApplication, at url: URL)
        async throws
    {
        let identity = ManagedApplicationIdentity(
            displayName: "Device Hub", bundleIdentifier: ToolConstants.deviceHubBundleIdentifier,
            expectedURLs: [url], errorIdentifier: "device-hub-companion", terminationRequest: .deviceHubHandoff)
        try await ApplicationTerminationWaiter(application: application, identity: identity, timeoutInterval: 10)
            .terminate()
    }

    @MainActor private static func waitForPreviousRendererOwners(at applicationURL: URL) async throws {
        let applications = NSRunningApplication.runningApplications(withBundleIdentifier: ToolConstants.neoHostBundleIdentifier)
            .filter { !$0.isTerminated }
        let snapshots = applications.map {
            RunningApplication(processIdentifier: $0.processIdentifier, bundleURL: $0.bundleURL, bundleIdentifier: $0.bundleIdentifier)
        }
        let directory = RendererRegistration.directoryURL
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

    @MainActor package static func waitForPreviousRendererOwners(at applicationURL: URL, applications: [RunningApplication],
        registration: (RunningApplication) throws -> RendererRegistration?,
        ownerIsAbsent: (RendererOwnerIdentity) -> Bool,
        waitForTermination: (RunningApplication) async throws -> Void) async throws {
        for application in applications where application.bundleIdentifier == ToolConstants.neoHostBundleIdentifier
            && application.bundleURL.map(normalized) == normalized(applicationURL) {
            try Task.checkCancellation()
            guard let record = try registration(application) else { continue }
            guard record.processIdentifier == application.processIdentifier,
                  normalized(URL(fileURLWithPath: record.applicationPath)) == normalized(applicationURL) else {
                throw HostOperationError.configuration("renderer-registration", "The renderer registration does not match its running application.")
            }
            guard let pid = record.ownerProcessIdentifier, let launchDate = record.ownerLaunchDate,
                  ownerIsAbsent(RendererOwnerIdentity(processIdentifier: pid, launchDate: launchDate)) else { continue }
            try await waitForTermination(application)
        }
    }

    package static func rendererLaunchArguments(owner: RendererOwnerIdentity, startupResultURL: URL,
                                        xcodeURL: URL, deviceIdentifier: String?, headless: Bool = false) -> [String] {
        var arguments = ["--managed", "--owner-pid", String(owner.processIdentifier),
                         "--owner-launch-date", String(owner.launchDate.timeIntervalSinceReferenceDate),
                         "--startup-result", startupResultURL.path, "--xcode", xcodeURL.path]
        if let deviceIdentifier { arguments += ["--device", deviceIdentifier] }
        if headless { arguments.append("--headless") }
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
                    throw HostOperationError.configuration(
                        "\(identity.errorIdentifier)-identity",
                        "refusing to terminate \(identity.displayName) pid \(application.processIdentifier) because its bundle identifier is \(application.bundleIdentifier ?? "unknown")"
                    )
                }
                guard let bundleURL = application.bundleURL else {
                    throw HostOperationError.configuration(
                        "\(identity.errorIdentifier)-identity",
                        "refusing to terminate \(identity.displayName) pid \(application.processIdentifier) because it has no bundle URL"
                    )
                }
                let observed = normalized(bundleURL)
                guard expected.contains(observed) else {
                    let allowedPaths = expected.map(\.path).sorted().joined(separator: ", ")
                    throw HostOperationError.configuration(
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
                        throw HostOperationError.temporary(
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

    @MainActor package static func makeNeoHostStartupDirectory() throws -> URL {
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
            throw HostOperationError.cannotCreate(
                "neo-host-startup-directory",
                "could not create the NeoSimulator startup directory: \(error.localizedDescription)"
            )
        }
        return directory
    }

    @MainActor package static func finishFailedNeoHostLaunch(
        _ launchError: any Error,
        processIdentifier: pid_t,
        terminate: @escaping @MainActor @Sendable () async throws -> Void
    ) async throws -> Never {
        do {
            try await Task { try await terminate() }.value
        } catch let terminationError {
            let message = "NeoSimulator launch failed (\(launchError.localizedDescription)), and pid \(processIdentifier) could not be terminated (\(terminationError.localizedDescription))"
            let failure = launchError as? any LocalizedError
            throw HostOperationError(category: .temporary, identifier: "neo-host-launch-cleanup", message: message,
                           failureReason: failure?.failureReason == nil ? nil : message,
                           recoverySuggestion: failure?.recoverySuggestion)
        }
        throw launchError
    }

    @MainActor package static func waitForNeoHostStartup(
        resultURL: URL,
        processIdentifier: pid_t? = nil,
        isTerminated: () -> Bool
    ) async throws {
        let descriptor = open(resultURL.deletingLastPathComponent().path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw HostOperationError.io("neo-host-startup-result", "Could not observe the NeoSimulator startup result: \(String(cString: strerror(errno)))")
        }
        let (events, continuation) = AsyncThrowingStream<Void, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let files = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete], queue: .main)
        files.setEventHandler { continuation.yield(()) }
        files.setRegistrationHandler { continuation.yield(()) }
        files.setCancelHandler { close(descriptor) }
        files.activate()
        let process = processIdentifier.map { DispatchSource.makeProcessSource(identifier: $0, eventMask: .exit, queue: .main) }
        process?.setEventHandler { continuation.yield(()) }
        process?.activate()
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            continuation.finish(throwing: HostOperationError.temporary(
                "neo-host-startup-timeout", "NeoSimulator did not finish startup within 10 seconds"))
        }
        defer { files.cancel(); process?.cancel(); timeout.cancel(); continuation.finish() }
        continuation.yield(())
        for try await _ in events {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: resultURL.path) {
                let data: Data
                do { data = try Data(contentsOf: resultURL) }
                catch {
                    throw HostOperationError.io("neo-host-startup-result",
                        "could not read the NeoSimulator startup result: \(error.localizedDescription)")
                }
                let result: RendererStartupResult
                do { result = try JSONDecoder().decode(RendererStartupResult.self, from: data) }
                catch {
                    throw HostOperationError.configuration("neo-host-startup-result", "NeoSimulator wrote an invalid startup result")
                }
                switch result {
                case .failed(let message, let recovery):
                    throw HostOperationError(category: .temporary, identifier: "neo-host-startup", message: message,
                                   failureReason: message, recoverySuggestion: recovery)
                case .ready:
                    guard !isTerminated() else {
                        throw HostOperationError.temporary("neo-host-startup", "NeoSimulator exited during startup")
                    }
                    return
                }
            }
            guard !isTerminated() else {
                throw HostOperationError.temporary("neo-host-startup", "NeoSimulator exited before startup completed")
            }
        }
        try Task.checkCancellation()
    }

    @MainActor private static func normalized(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}

@MainActor
package final class RendererDeviceRequestWaiter {
    package typealias ScheduleTimeout = @MainActor (Duration, @escaping @MainActor () -> Void) -> () -> Void
    private let scheduleTimeout: ScheduleTimeout
    private let acknowledgements: NotificationCenter
    private let send: @MainActor ([String: String], String) -> Void

    package init(acknowledgements: NotificationCenter = DistributedNotificationCenter.default(),
         scheduleTimeout: @escaping ScheduleTimeout = RendererDeviceRequestWaiter.scheduleDeadline,
         send: @escaping @MainActor ([String: String], String) -> Void = { info, sessionIdentifier in
             DistributedNotificationCenter.default().postNotificationName(
                 RendererRequest.notificationName, object: sessionIdentifier,
                 userInfo: info, deliverImmediately: true)
         }) {
        self.acknowledgements = acknowledgements
        self.scheduleTimeout = scheduleTimeout
        self.send = send
    }

    private var observer: NSObjectProtocol?
    private var cancelTimeout: (() -> Void)?
    private var cancelExitObservation: (() -> Void)?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var handled = true
    private var cancellationRequest: (() -> Void)?
    private var activeRequestIdentifier: String?
    private var cancelledOpen = false

    package func release(_ deviceID: DeviceInventoryID, from renderer: RendererRegistration) async throws {
        try await request("release-device", acknowledgement: "RendererReleased", deviceID: deviceID, renderer: renderer, timeoutSeconds: 120)
    }

    package func restart(_ deviceID: DeviceInventoryID, in renderer: RendererRegistration, erasing: Bool) async throws -> Bool {
        try await request(erasing ? "erase-device" : "restart-device", acknowledgement: "RendererManaged", deviceID: deviceID, renderer: renderer, timeoutSeconds: 450)
        return handled
    }

    package func open(_ deviceID: DeviceInventoryID, in renderer: RendererRegistration) async throws {
        try await request("open-device", acknowledgement: "RendererOpened", deviceID: deviceID, renderer: renderer, timeoutSeconds: 450)
    }

    package func attach(_ deviceID: DeviceInventoryID, in renderer: RendererRegistration) async throws {
        try await request("attach-device", acknowledgement: "RendererOpened", deviceID: deviceID, renderer: renderer, timeoutSeconds: 450)
    }

    package func close(_ deviceID: DeviceInventoryID, in renderer: RendererRegistration, keepingDeviceRunning: Bool) async throws {
        try await request("close-device", acknowledgement: "RendererClosed", deviceID: deviceID, renderer: renderer,
                          timeoutSeconds: 120, additionalInfo: ["keepRunning": keepingDeviceRunning ? "true" : "false"])
    }

    private func request(_ action: String, acknowledgement: String, deviceID: DeviceInventoryID, renderer: RendererRegistration, timeoutSeconds: Int,
                         additionalInfo: [String: String] = [:]) async throws {
        let (identifier, deviceSetPath) = try deviceID.simulatorAddress
        try Task.checkCancellation()
        let requestIdentifier = UUID().uuidString
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.activeRequestIdentifier = requestIdentifier
                if action == "open-device" || action == "attach-device" {
                    self.cancellationRequest = { [weak self] in
                        guard let self else { return }
                        self.cancelledOpen = true
                        var info = ["action": "cancel-open", "udid": identifier, "requestIdentifier": requestIdentifier]
                        if let deviceSetPath { info["deviceSetPath"] = deviceSetPath }
                        self.send(info, renderer.sessionIdentifier)
                    }
                }
                observer = acknowledgements.addObserver(
                    forName: Notification.Name("dev.lynnswap.NeoSimulator.\(acknowledgement)"),
                    object: requestIdentifier, queue: .main
                ) { [weak self] notification in
                    let acknowledged = (notification.userInfo?["udid"] as? String).map {
                        DeviceInventoryID.simulator(udid: $0, deviceSetPath: notification.userInfo?["deviceSetPath"] as? String)
                    }
                    let failure = notification.userInfo?["error"] as? String
                    let didStartSimulator = notification.userInfo?["didStartSimulator"] as? Bool ?? false
                    let handled = notification.userInfo?["handled"] as? Bool ?? true
                    Task { @MainActor in
                        guard acknowledged == deviceID else { return }
                        if let failure {
                            let error = HostOperationError.temporary("renderer-device-request", failure)
                            self?.finish(.failure(didStartSimulator ? DeviceRestartedWithFailure(underlyingError: error) : error))
                        } else {
                            self?.handled = handled
                            self?.finish(self?.cancelledOpen == true ? .failure(CancellationError()) : .success(()))
                        }
                    }
                }
                cancelTimeout = scheduleTimeout(.seconds(timeoutSeconds)) { [weak self] in
                    self?.finish(.failure(HostOperationError.temporary("renderer-device-timeout", "The simulator display did not finish the device request.")))
                }
                cancelExitObservation = Self.observeExit(of: renderer.processIdentifier) { [weak self] in
                    guard let self, self.activeRequestIdentifier == requestIdentifier else { return }
                    // A release retires only presentation state owned by the renderer process, which its exit also retires.
                    if action == "release-device" { self.finish(.success(())) }
                    // Other requests and the cancellation of an open can no longer be completed.
                    else {
                        self.finish(.failure(self.cancelledOpen ? CancellationError()
                            : HostOperationError.temporary("renderer-device-exit", "The simulator display exited before finishing the device request.")))
                    }
                }
                var info = ["action": action, "udid": identifier, "requestIdentifier": requestIdentifier]
                info.merge(additionalInfo) { _, additional in additional }
                if let deviceSetPath { info["deviceSetPath"] = deviceSetPath }
                send(info, renderer.sessionIdentifier)
            }
        } onCancel: {
            Task { @MainActor in
                guard self.activeRequestIdentifier == requestIdentifier else { return }
                if let cancel = self.cancellationRequest { cancel() }
                else { self.finish(.failure(CancellationError())) }
            }
        }
    }

    private func finish(_ result: Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        cancellationRequest = nil
        activeRequestIdentifier = nil
        cancelledOpen = false
        if let observer { acknowledgements.removeObserver(observer) }
        observer = nil
        cancelTimeout?()
        cancelTimeout = nil
        cancelExitObservation?()
        cancelExitObservation = nil
        continuation.resume(with: result)
    }

    private static func scheduleDeadline(_ duration: Duration, action: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task {
            do { try await Task.sleep(for: duration) } catch { return }
            action()
        }
        return { task.cancel() }
    }

    /// Dispatch also reports a process that exited before the source was registered.
    private static func observeExit(of processIdentifier: pid_t, exited: @escaping @MainActor () -> Void) -> () -> Void {
        let source = DispatchSource.makeProcessSource(identifier: processIdentifier, eventMask: .exit, queue: .main)
        // Acknowledgements also reach the waiter through main-actor tasks, so one delivered before the exit wins.
        source.setEventHandler { Task { @MainActor in exited() } }
        source.activate()
        return { source.cancel() }
    }

}
