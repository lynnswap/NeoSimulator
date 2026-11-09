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

    nonisolated private let owner = Mutex<RendererOwnerIdentity?>(nil)
    private var companions: [URL: Companion] = [:]
    private var launches: [URL: Task<Void, any Error>] = [:]
    private var workspaceObservers: [any NSObjectProtocol] = []
    private var enabled = false
    private let rendererURL: URL
    private var requestObserver: (any NSObjectProtocol)?
    package var onOpenDeviceHub: ((URL, URL?) -> Void)?
    package var onError: ((any Error) -> Void)?

    package init(rendererApplicationURL: URL) {
        rendererURL = rendererApplicationURL
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

    package func start(at applicationURL: URL) async throws {
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
                        let url = self.companions.first(where: { $0.value.process.processIdentifier == pid })?.key
                    else { return }
                    let xcode = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    if action == "open-device-hub" { self.onOpenDeviceHub?(xcode, request) }
                }
            }
        }
        try await prepare(at: applicationURL).value
        enabled = true
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
                            let task = self.prepare(at: hub)
                            Task { do { try await task.value } catch { self.onError?(error) } }
                        }
                    })
            }
        }
        for xcode in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode") {
            if let url = xcode.bundleURL {
                let hub = url.appendingPathComponent(ToolConstants.deviceHubPath)
                if FileManager.default.fileExists(atPath: hub.path) {
                    let task = prepare(at: hub)
                    Task { do { try await task.value } catch { onError?(error) } }
                }
            }
        }
    }

    /// Ends ownership before opening Device Hub's normal UI.
    package func stop() async throws {
        enabled = false
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers = []
        if let requestObserver { DistributedNotificationCenter.default().removeObserver(requestObserver) }
        requestObserver = nil
        // Launch failures are delivered to their callers. Ending ownership only needs their cleanup to finish.
        for task in launches.values { _ = await task.result }
        var failure: (any Error)?
        for (url, companion) in companions {
            do {
                try await terminate(companion, at: url)
                companions.removeValue(forKey: url)
            } catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
    }

    private func prepare(at applicationURL: URL) -> Task<Void, any Error> {
        let url = applicationURL.standardizedFileURL.resolvingSymlinksInPath()
        if let task = launches[url] { return task }
        if let companion = companions[url], companion.process.isRunning, companion.application != nil { return Task {} }

        let task = Task { [self] in
            defer { launches.removeValue(forKey: url) }
            if let previous = companions[url] {
                try await terminate(previous, at: url)
                companions.removeValue(forKey: url)
            }
            try CodeSignatureValidator.live.validateAppleApplication(url, ToolConstants.deviceHubBundleIdentifier)
            let startupDirectory = try WorkspaceClient.makeNeoHostStartupDirectory()
            defer { try? FileManager.default.removeItem(at: startupDirectory) }
            let resultURL = startupDirectory.appendingPathComponent("result")
            let xcode = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
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
                    guard let self, self.companions[url]?.process.processIdentifier == process.processIdentifier else {
                        return
                    }
                    self.companions.removeValue(forKey: url)
                    guard self.enabled, self.launches[url] == nil else { return }
                    let task = self.prepare(at: url)
                    Task { do { try await task.value } catch { self.onError?(error) } }
                }
            }
            try process.run()
            companions[url] = Companion(process: process)
            do {
                try await WorkspaceClient.waitForNeoHostStartup(
                    resultURL: resultURL, processIdentifier: process.processIdentifier,
                    isTerminated: { !process.isRunning })
                guard let application = NSRunningApplication(processIdentifier: process.processIdentifier),
                    application.bundleIdentifier == ToolConstants.deviceHubBundleIdentifier,
                    application.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == url,
                    application.executableURL?.standardizedFileURL == executableURL.standardizedFileURL
                else {
                    throw HostOperationError.configuration(
                        "device-hub-proxy-identity",
                        "The simulator display bridge did not register with LaunchServices.")
                }
                companions[url]?.application = application
            } catch let error {
                let companion = companions[url] ?? Companion(process: process)
                try await WorkspaceClient.finishFailedNeoHostLaunch(error, processIdentifier: process.processIdentifier)
                {
                    try await self.terminate(companion, at: url)
                    self.companions.removeValue(forKey: url)
                }
            }
        }
        launches[url] = task
        return task
    }

    private var executableURL: URL { rendererURL.appendingPathComponent("Contents/MacOS/NeoSimulatorRenderer") }

    private func terminate(_ companion: Companion, at url: URL) async throws {
        let process = companion.process
        if let application = companion.application {
            try await WorkspaceClient.terminateDeviceHubCompanion(application, at: url)
        } else if process.isRunning, kill(process.processIdentifier, SIGKILL) != 0, errno != ESRCH {
            throw HostOperationError.io(
                "device-hub-proxy-stop",
                "Could not stop the simulator display bridge: \(String(cString: strerror(errno)))")
        }
        try await performBlockingIO { process.waitUntilExit() }
    }

    isolated deinit {
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let requestObserver { DistributedNotificationCenter.default().removeObserver(requestObserver) }
    }
}
