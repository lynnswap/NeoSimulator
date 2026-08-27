import AppKit
import Foundation

struct RunningApplication: Equatable {
    let processIdentifier: pid_t
    let bundleURL: URL?
}

@MainActor
private final class ApplicationTerminationWaiter {
    private let application: NSRunningApplication
    private let timeoutInterval: TimeInterval
    private var observation: NSKeyValueObservation?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var cancellationRequested = false
    private var timeoutTimer: Timer?

    init(
        application: NSRunningApplication,
        timeoutInterval: TimeInterval
    ) {
        self.application = application
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
                                    "device-hub-termination-timeout",
                                    "Device Hub pid \(self.application.processIdentifier) did not finish terminating before the operation deadline"
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
                                withBundleIdentifier: ToolConstants.deviceHubBundleIdentifier
                            ).contains {
                                // Do not compare PIDs: AppKit documents that an
                                // NSRunningApplication PID may change.
                                $0.isEqual(self.application) && !$0.isTerminated
                            }
                            if isStillRunning {
                                self.finish(
                                    .failure(
                                        CLIError.temporary(
                                            "device-hub-termination",
                                            "Device Hub pid \(self.application.processIdentifier) did not accept a normal termination request"
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
    var terminateDeviceHubs: (URL) async throws -> Int
    var openApplication: (URL) async throws -> URL

    static let live = WorkspaceClient(
        runningXcodes: {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: ToolConstants.xcodeBundleIdentifier
            ).map {
                RunningApplication(
                    processIdentifier: $0.processIdentifier,
                    bundleURL: $0.bundleURL
                )
            }
        },
        terminateDeviceHubs: { expectedApplicationURL in
            let expected = expectedApplicationURL
                .resolvingSymlinksInPath()
                .standardizedFileURL
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            var terminatedCount = 0

            while true {
                let applications = NSRunningApplication.runningApplications(
                    withBundleIdentifier: ToolConstants.deviceHubBundleIdentifier
                ).filter { !$0.isTerminated }
                guard !applications.isEmpty else {
                    return terminatedCount
                }

                for application in applications {
                    guard let bundleURL = application.bundleURL else {
                        throw CLIError.configuration(
                            "device-hub-identity",
                            "refusing to terminate Device Hub pid \(application.processIdentifier) because it has no bundle URL"
                        )
                    }
                    let observed = bundleURL
                        .resolvingSymlinksInPath()
                        .standardizedFileURL
                    guard observed == expected else {
                        throw CLIError.configuration(
                            "device-hub-substitution",
                            "refusing to terminate Device Hub pid \(application.processIdentifier) from \(observed.path); expected \(expected.path)"
                        )
                    }
                }

                for application in applications {
                    let remaining = clock.now.duration(to: deadline)
                    guard remaining > .zero else {
                        throw CLIError.temporary(
                            "device-hub-termination-timeout",
                            "Device Hub kept running or relaunching for 10 seconds"
                        )
                    }
                    let components = remaining.components
                    let timeoutInterval = TimeInterval(components.seconds)
                        + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
                    let waiter = ApplicationTerminationWaiter(
                        application: application,
                        timeoutInterval: timeoutInterval
                    )
                    try await waiter.terminate()
                    terminatedCount += 1
                }
            }
        },
        openApplication: { applicationURL in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            configuration.allowsRunningApplicationSubstitution = false

            let application = try await NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            )
            guard let openedURL = application.bundleURL else {
                throw CLIError.io(
                    "simulator-launch",
                    "LaunchServices opened Simulator without a bundle URL"
                )
            }

            let expected = applicationURL.resolvingSymlinksInPath().standardizedFileURL
            let observed = openedURL.resolvingSymlinksInPath().standardizedFileURL
            guard observed == expected else {
                throw CLIError.io(
                    "simulator-substitution",
                    "requested \(expected.path), but LaunchServices opened \(observed.path)"
                )
            }
            return observed
        }
    )
}
