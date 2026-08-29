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
                            let isStillRunning = NSRunningApplication.runningApplications(
                                withBundleIdentifier: self.identity.bundleIdentifier
                            ).contains {
                                // Do not compare PIDs: AppKit documents that an
                                // NSRunningApplication PID may change.
                                $0.isEqual(self.application) && !$0.isTerminated
                            }
                            if isStillRunning {
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

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            configuration.allowsRunningApplicationSubstitution = false
            configuration.arguments = ["--xcode", xcodeURL.path]

            let application = try await NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            )
            guard application.bundleIdentifier == ToolConstants.legacyHostBundleIdentifier else {
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
            return observed
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

    private static func normalized(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }
}
