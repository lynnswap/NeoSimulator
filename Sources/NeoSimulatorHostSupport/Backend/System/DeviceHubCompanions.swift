import AppKit
import Darwin
import Foundation
import NeoSimulatorDeviceIO
import NeoSimulatorKit
import Synchronization

/// Keeps Xcode on its externally managed simulator route without launching another display host.
@MainActor
package final class DeviceHubCompanions {
    private struct Companion {
        let process: Process
        var application: NSRunningApplication?
    }

    package typealias ObserveExit = @MainActor (pid_t, @escaping @MainActor () -> Void) -> () -> Void
    private let observeExit: ObserveExit
    private var deviceHubObservations: [URL: (pid: pid_t, cancel: () -> Void)] = [:]
    package var onDeviceHubExit: ((URL) -> Void)?

    nonisolated private let owner = Mutex<RendererOwnerIdentity?>(nil)
    private var companions: [URL: Companion] = [:]
    private var launches: [URL: Task<Void, any Error>] = [:]
    private var workspaceObservers: [any NSObjectProtocol] = []
    private var enabled = false
    private let rendererURL: URL
    private var requestObserver: (any NSObjectProtocol)?
    package var onOpenDeviceHub: ((URL, URL?) -> Void)?
    package var onError: ((any Error) -> Void)?

    package init(rendererApplicationURL: URL, observeExit: ObserveExit? = nil) {
        rendererURL = rendererApplicationURL
        self.observeExit = observeExit ?? Self.observeProcessExit
    }

    package func observeDeviceHub(processIdentifier: pid_t, xcodeURL: URL) {
        let xcode = xcodeURL.standardizedFileURL.resolvingSymlinksInPath()
        deviceHubObservations.removeValue(forKey: xcode)?.cancel()
        let cancel = observeExit(processIdentifier) { [weak self] in
            guard let self, self.deviceHubObservations[xcode]?.pid == processIdentifier else { return }
            self.deviceHubObservations.removeValue(forKey: xcode)?.cancel()
            self.onDeviceHubExit?(xcode)
        }
        deviceHubObservations[xcode] = (processIdentifier, cancel)
    }

    private static func observeProcessExit(of processIdentifier: pid_t, exited: @escaping @MainActor () -> Void) -> ()
        -> Void
    {
        let source = DispatchSource.makeProcessSource(identifier: processIdentifier, eventMask: .exit, queue: .main)
        source.setEventHandler { Task { @MainActor in exited() } }
        source.activate()
        return { source.cancel() }
    }

    nonisolated package func allows(processIdentifier: pid_t, bundleURL: URL?) -> Bool {
        guard bundleURL != nil, let owner = owner.withLock({ $0 }) else { return false }
        return Self.allows(processIdentifier: processIdentifier, owner: owner)
    }

    nonisolated package static func allows(processIdentifier: pid_t, owner: RendererOwnerIdentity) -> Bool {
        companionOwner(processIdentifier: processIdentifier) == owner
    }

    nonisolated private static func companionOwner(processIdentifier: pid_t) -> RendererOwnerIdentity? {
        guard let data = ProcessArguments.readRaw(processIdentifier: processIdentifier),
            let arguments = ProcessArguments(data: data)?.arguments,
            arguments.contains("--device-hub-proxy"),
            let pidIndex = arguments.firstIndex(of: "--owner-pid"), arguments.indices.contains(pidIndex + 1),
            let dateIndex = arguments.firstIndex(of: "--owner-launch-date"), arguments.indices.contains(dateIndex + 1),
            let pid = pid_t(arguments[pidIndex + 1]), pid > 0,
            let seconds = TimeInterval(arguments[dateIndex + 1]), seconds.isFinite
        else { return nil }
        return RendererOwnerIdentity(processIdentifier: pid, launchDate: Date(timeIntervalSinceReferenceDate: seconds))
    }

    package static func token(for owner: RendererOwnerIdentity) -> String {
        "\(owner.processIdentifier):\(owner.launchDate.timeIntervalSinceReferenceDate)"
    }

    package static let requestNotification = Notification.Name("dev.lynnswap.NeoSimulator.DeviceHubProxyRequest")

    package func start(xcodeURL: URL) async throws {
        let identity = try RendererOwnerIdentity.current()
        owner.withLock { $0 = identity }
        if requestObserver == nil {
            requestObserver = DistributedNotificationCenter.default().addObserver(
                forName: Self.requestNotification, object: Self.token(for: identity), queue: .main
            ) { [weak self] notification in
                guard let pid = notification.userInfo?["pid"] as? String,
                    let pid = pid_t(pid), let action = notification.userInfo?["action"] as? String
                else { return }
                let request = (notification.userInfo?["url"] as? String).flatMap(URL.init(string:))
                MainActor.assumeIsolated {
                    guard let self, self.requestObserver != nil,
                        let xcodeURL = self.companions.first(where: { $0.value.process.processIdentifier == pid })?.key
                    else { return }
                    if action == "open-device-hub" { self.onOpenDeviceHub?(xcodeURL, request) }
                }
            }
        }
        let wasEnabled = enabled
        enabled = true
        do { try await prepare(xcodeURL: xcodeURL).value } catch let startupError {
            if !wasEnabled {
                do { try await stop() } catch let cleanupError {
                    throw HostOperationError.temporary(
                        "device-hub-startup-cleanup",
                        "Could not prepare the display bridge (\(startupError.localizedDescription)) or release its processes (\(cleanupError.localizedDescription))."
                    )
                }
            }
            throw startupError
        }
        if workspaceObservers.isEmpty {
            for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
                workspaceObservers.append(
                    NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                        [weak self] notification in
                        guard
                            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                                as? NSRunningApplication,
                            application.bundleIdentifier == ToolConstants.xcodeBundleIdentifier,
                            let url = application.bundleURL
                        else { return }
                        MainActor.assumeIsolated {
                            guard let self, self.enabled else { return }
                            let hub = url.appendingPathComponent(ToolConstants.deviceHubPath)
                            guard FileManager.default.fileExists(atPath: hub.path) else { return }
                            let task = self.prepare(xcodeURL: url)
                            Task { do { try await task.value } catch { self.onError?(error) } }
                        }
                    })
            }
        }
        for xcode in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode") {
            if let url = xcode.bundleURL {
                let hub = url.appendingPathComponent(ToolConstants.deviceHubPath)
                if FileManager.default.fileExists(atPath: hub.path) {
                    let task = prepare(xcodeURL: url)
                    do { try await task.value } catch { onError?(error) }
                }
            }
        }
    }

    package func stop() async throws {
        for observation in deviceHubObservations.values { observation.cancel() }
        deviceHubObservations = [:]
        try await releaseBridges()
    }

    /// Ends bridge ownership while continuing to observe Device Hub's normal UI.
    package func releaseBridges() async throws {
        enabled = false
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers = []
        if let requestObserver { DistributedNotificationCenter.default().removeObserver(requestObserver) }
        requestObserver = nil
        // Launch failures are delivered to their callers. Ending ownership only needs their cleanup to finish.
        for task in launches.values { _ = await task.result }
        var failure: (any Error)?
        for (xcodeURL, companion) in companions {
            do {
                try await terminate(companion, xcodeURL: xcodeURL)
                companions.removeValue(forKey: xcodeURL)
            } catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
    }

    private func prepare(xcodeURL: URL) -> Task<Void, any Error> {
        let xcode = xcodeURL.standardizedFileURL.resolvingSymlinksInPath()
        let applicationURL = xcode.appendingPathComponent(ToolConstants.deviceHubPath)
        if let task = launches[xcode] { return task }
        if let companion = companions[xcode], companion.process.isRunning, companion.application != nil {
            return Task {}
        }

        let task = Task { [self] in
            defer { launches.removeValue(forKey: xcode) }
            if let previous = companions[xcode] {
                try await terminate(previous, xcodeURL: xcode)
                companions.removeValue(forKey: xcode)
            }
            try CodeSignatureValidator.live.validateAppleApplication(
                applicationURL, ToolConstants.deviceHubBundleIdentifier)
            let startupDirectory = try WorkspaceClient.makeNeoHostStartupDirectory()
            defer { try? FileManager.default.removeItem(at: startupDirectory) }
            let resultURL = startupDirectory.appendingPathComponent("result")
            let process = Process()
            process.executableURL = executableURL
            process.arguments =
                WorkspaceClient.rendererLaunchArguments(
                    owner: try RendererOwnerIdentity.current(),
                    startupResultURL: resultURL, xcodeURL: xcode, deviceIdentifier: nil) + ["--device-hub-proxy"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.standardError
            process.terminationHandler = { [weak self] process in
                Task { @MainActor in
                    guard let self, let companion = self.companions[xcode],
                        companion.process.processIdentifier == process.processIdentifier
                    else {
                        return
                    }
                    self.companions.removeValue(forKey: xcode)
                    guard self.enabled, companion.application != nil, self.launches[xcode] == nil else { return }
                    let task = self.prepare(xcodeURL: xcode)
                    Task { do { try await task.value } catch { self.onError?(error) } }
                }
            }
            try process.run()
            companions[xcode] = Companion(process: process)
            do {
                try await WorkspaceClient.waitForNeoHostStartup(
                    resultURL: resultURL, processIdentifier: process.processIdentifier,
                    isTerminated: { !process.isRunning })
                guard let application = NSRunningApplication(processIdentifier: process.processIdentifier),
                    application.bundleIdentifier == ToolConstants.deviceHubBundleIdentifier,
                    application.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == applicationURL,
                    application.executableURL?.standardizedFileURL == executableURL.standardizedFileURL
                else {
                    throw HostOperationError.configuration(
                        "device-hub-proxy-identity",
                        "The simulator display bridge did not register with LaunchServices.")
                }
                companions[xcode]?.application = application
            } catch let error {
                let companion = companions[xcode] ?? Companion(process: process)
                try await WorkspaceClient.finishFailedNeoHostLaunch(error, processIdentifier: process.processIdentifier)
                {
                    try await self.terminate(companion, xcodeURL: xcode)
                    self.companions.removeValue(forKey: xcode)
                }
            }
        }
        launches[xcode] = task
        return task
    }

    private var executableURL: URL { rendererURL.appendingPathComponent("Contents/MacOS/NeoSimulatorRenderer") }

    private func terminate(_ companion: Companion, xcodeURL: URL) async throws {
        let process = companion.process
        if let application = companion.application {
            try await WorkspaceClient.terminateDeviceHubCompanion(
                application, at: xcodeURL.appendingPathComponent(ToolConstants.deviceHubPath))
        } else if process.isRunning, kill(process.processIdentifier, SIGKILL) != 0, errno != ESRCH {
            throw HostOperationError.io(
                "device-hub-proxy-stop",
                "Could not stop the simulator display bridge: \(String(cString: strerror(errno)))")
        }
        try await performBlockingIO { process.waitUntilExit() }
    }

    isolated deinit {
        for observation in deviceHubObservations.values { observation.cancel() }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let requestObserver { DistributedNotificationCenter.default().removeObserver(requestObserver) }
    }
}
