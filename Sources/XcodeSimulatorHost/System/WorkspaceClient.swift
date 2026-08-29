import AppKit
import Foundation

struct RunningApplication: Equatable {
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

private struct ManagedApplicationIdentity {
    let displayName: String
    let bundleIdentifier: String
    let expectedURL: URL
    let errorIdentifier: String
}

private let legacyHostStartupPayload = Data("ready\n".utf8)

@MainActor
private final class ApplicationTerminationWaiter {
    private let application: NSRunningApplication
    private let identity: ManagedApplicationIdentity
    private let timeoutInterval: TimeInterval
    private var observation: NSKeyValueObservation?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var cancellationRequested = false
    private var timeoutTimer: Timer?

    init(
        application: NSRunningApplication,
        identity: ManagedApplicationIdentity,
        timeoutInterval: TimeInterval
    ) {
        self.application = application
        self.identity = identity
        self.timeoutInterval = timeoutInterval
    }

    func terminate() async throws {
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

                // terminate() only confirms request delivery; isTerminated is the
                // documented terminal state and remains valid for normal GUI exits.
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

                if application.isTerminated {
                    finish(.success(()))
                    return
                }

                if !application.terminate() {
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
                                            "\(self.identity.displayName) pid \(self.application.processIdentifier) did not accept a normal termination request"
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

@MainActor
struct WorkspaceClient {
    var runningXcodes: () -> [RunningApplication]
    var runningLegacyHosts: () -> [RunningApplication]
    var terminateDeviceHubs: (URL) async throws -> Int
    var terminateLegacyHosts: (URL) async throws -> Int
    var openLegacyHost: (URL, URL) async throws -> URL

    static let live = WorkspaceClient(
        runningXcodes: {
            runningApplications(
                withBundleIdentifier: ToolConstants.xcodeBundleIdentifier
            )
        },
        runningLegacyHosts: {
            runningApplications(
                withBundleIdentifier: ToolConstants.legacyHostBundleIdentifier
            )
        },
        terminateDeviceHubs: { expectedApplicationURL in
            try await terminateApplications(
                ManagedApplicationIdentity(
                    displayName: "Device Hub",
                    bundleIdentifier: ToolConstants.deviceHubBundleIdentifier,
                    expectedURL: expectedApplicationURL,
                    errorIdentifier: "device-hub"
                )
            )
        },
        terminateLegacyHosts: { expectedApplicationURL in
            try await terminateApplications(
                ManagedApplicationIdentity(
                    displayName: "standalone simulator host",
                    bundleIdentifier: ToolConstants.legacyHostBundleIdentifier,
                    expectedURL: expectedApplicationURL,
                    errorIdentifier: "legacy-host"
                )
            )
        },
        openLegacyHost: { applicationURL, xcodeURL in
            guard Bundle(url: applicationURL)?.bundleIdentifier
                    == ToolConstants.legacyHostBundleIdentifier
            else {
                throw CLIError.configuration(
                    "legacy-host-bundle",
                    "refusing to launch \(applicationURL.path) because it is not \(ToolConstants.legacyHostBundleIdentifier)"
                )
            }

            let startupDirectory = try makeLegacyHostStartupDirectory()
            defer {
                try? FileManager.default.removeItem(at: startupDirectory)
            }
            let startupResultURL = startupDirectory.appendingPathComponent(
                "result",
                isDirectory: false
            )

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            configuration.allowsRunningApplicationSubstitution = false
            configuration.arguments = [
                "--startup-result",
                startupResultURL.path,
                "--xcode",
                xcodeURL.path,
            ]

            let application = try await NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            )
            let identity = ManagedApplicationIdentity(
                displayName: "standalone simulator host",
                bundleIdentifier: ToolConstants.legacyHostBundleIdentifier,
                expectedURL: applicationURL,
                errorIdentifier: "legacy-host"
            )
            do {
                guard application.bundleIdentifier
                        == ToolConstants.legacyHostBundleIdentifier
                else {
                    throw CLIError.configuration(
                        "legacy-host-identifier",
                        "LaunchServices opened pid \(application.processIdentifier) with bundle identifier \(application.bundleIdentifier ?? "unknown"); expected \(ToolConstants.legacyHostBundleIdentifier)"
                    )
                }
                guard let openedURL = application.bundleURL else {
                    throw CLIError.io(
                        "legacy-host-launch",
                        "LaunchServices opened the standalone simulator host without a bundle URL"
                    )
                }

                let expected = normalized(applicationURL)
                let observed = normalized(openedURL)
                guard observed == expected else {
                    throw CLIError.configuration(
                        "legacy-host-substitution",
                        "requested \(expected.path), but LaunchServices opened \(observed.path)"
                    )
                }
                try await waitForLegacyHostStartup(
                    application,
                    resultURL: startupResultURL
                )
                return observed
            } catch let launchError {
                if !application.isTerminated {
                    _ = application.terminate()
                }
                let waiter = ApplicationTerminationWaiter(
                    application: application,
                    identity: identity,
                    timeoutInterval: 10
                )
                do {
                    try await waiter.terminate()
                } catch let terminationError {
                    throw CLIError.temporary(
                        "legacy-host-launch-cleanup",
                        "standalone host launch failed (\(launchError.localizedDescription)), and pid \(application.processIdentifier) could not be terminated (\(terminationError.localizedDescription))"
                    )
                }
                throw launchError
            }
        }
    )

    private static func runningApplications(
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

    private static func terminateApplications(
        _ identity: ManagedApplicationIdentity
    ) async throws -> Int {
        let expected = normalized(identity.expectedURL)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var terminatedCount = 0

        while true {
            let applications = NSRunningApplication.runningApplications(
                withBundleIdentifier: identity.bundleIdentifier
            ).filter { !$0.isTerminated }
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
                guard observed == expected else {
                    throw CLIError.configuration(
                        "\(identity.errorIdentifier)-substitution",
                        "refusing to terminate \(identity.displayName) pid \(application.processIdentifier) from \(observed.path); expected \(expected.path)"
                    )
                }
            }

            for application in applications {
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else {
                    throw CLIError.temporary(
                        "\(identity.errorIdentifier)-termination-timeout",
                        "\(identity.displayName) kept running or relaunching for 10 seconds"
                    )
                }
                let components = remaining.components
                let timeoutInterval = TimeInterval(components.seconds)
                    + TimeInterval(components.attoseconds)
                        / 1_000_000_000_000_000_000
                let waiter = ApplicationTerminationWaiter(
                    application: application,
                    identity: identity,
                    timeoutInterval: timeoutInterval
                )
                try await waiter.terminate()
                terminatedCount += 1
            }
        }
    }

    private static func makeLegacyHostStartupDirectory() throws -> URL {
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
                "legacy-host-startup-directory",
                "could not create the standalone host startup directory: \(error.localizedDescription)"
            )
        }
        return directory
    }

    private static func waitForLegacyHostStartup(
        _ application: NSRunningApplication,
        resultURL: URL
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))

        while clock.now < deadline {
            guard !application.isTerminated else {
                throw CLIError.temporary(
                    "legacy-host-startup",
                    "the standalone simulator host exited before startup completed"
                )
            }

            if FileManager.default.fileExists(atPath: resultURL.path) {
                let result: Data
                do {
                    result = try Data(contentsOf: resultURL)
                } catch {
                    throw CLIError.io(
                        "legacy-host-startup-result",
                        "could not read the standalone host startup result: \(error.localizedDescription)"
                    )
                }
                guard result == legacyHostStartupPayload else {
                    throw CLIError.configuration(
                        "legacy-host-startup-result",
                        "the standalone host wrote an invalid startup result"
                    )
                }
                await Task.yield()
                guard !application.isTerminated else {
                    throw CLIError.temporary(
                        "legacy-host-startup",
                        "the standalone simulator host exited during startup"
                    )
                }
                return
            }

            try await Task.sleep(for: .milliseconds(50))
        }

        throw CLIError.temporary(
            "legacy-host-startup-timeout",
            "the standalone simulator host did not finish startup within 10 seconds"
        )
    }

    private static func normalized(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
