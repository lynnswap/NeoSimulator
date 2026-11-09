import AppKit
import Darwin
import Foundation
import NeoSimulatorDeviceIO
import NeoSimulatorKit
import Synchronization

/// Keeps Xcode on its externally managed simulator route without launching another display host.
@MainActor
package final class DeviceHubCompanions {
    nonisolated private let owner = Mutex<RendererOwnerIdentity?>(nil)
    private var companions: [URL: Process] = [:]
    private var launches: [URL: Task<Void, any Error>] = [:]
    private var workspaceObservers: [any NSObjectProtocol] = []
    private var enabled = false
    private let rendererURL: URL
    private var requestObserver: (any NSObjectProtocol)?
    package var onOpenDeviceHub: ((URL) -> Void)?
    package var onOpenDevice: ((UUID, URL) -> Void)?
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
        enabled = true
        if requestObserver == nil {
            requestObserver = DistributedNotificationCenter.default().addObserver(
                forName: Self.requestNotification, object: Self.token(for: identity), queue: .main
            ) { [weak self] notification in
                guard let pid = notification.userInfo?["pid"] as? String,
                    let pid = pid_t(pid), let action = notification.userInfo?["action"] as? String
                else { return }
                let device = (notification.userInfo?["device"] as? String).flatMap(UUID.init(uuidString:))
                MainActor.assumeIsolated {
                    guard let self, self.enabled,
                        let url = self.companions.first(where: { $0.value.processIdentifier == pid })?.key
                    else { return }
                    let xcode = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    if action == "open-device", let device {
                        self.onOpenDevice?(device, xcode)
                    } else if action == "open-device-hub" {
                        self.onOpenDeviceHub?(xcode)
                    }
                }
            }
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
                            let task = self.prepare(at: hub)
                            Task { do { try await task.value } catch { self.onError?(error) } }
                        }
                    })
            }
        }
        try await prepare(at: applicationURL).value
        for xcode in NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode") {
            if let url = xcode.bundleURL {
                let hub = url.appendingPathComponent(ToolConstants.deviceHubPath)
                if FileManager.default.fileExists(atPath: hub.path) { try await prepare(at: hub).value }
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
        var failure: (any Error)?
        for task in launches.values {
            do { try await task.value } catch { if failure == nil { failure = error } }
        }
        for (url, process) in companions {
            do {
                try await terminate(process)
                companions.removeValue(forKey: url)
            } catch { if failure == nil { failure = error } }
        }
        // A host selection can survive its manager crashing before it released the previous companions.
        for application in NSRunningApplication.runningApplications(
            withBundleIdentifier: ToolConstants.deviceHubBundleIdentifier)
        {
            guard let previousOwner = Self.companionOwner(processIdentifier: application.processIdentifier),
                let url = application.bundleURL,
                application.executableURL?.standardizedFileURL == executableURL.standardizedFileURL
            else { continue }
            if let manager = NSRunningApplication(processIdentifier: previousOwner.processIdentifier),
                !manager.isTerminated, manager.launchDate == previousOwner.launchDate
            {
                if kill(previousOwner.processIdentifier, 0) == 0 || errno != ESRCH { continue }
            }
            do {
                try CodeSignatureValidator.live.validateAppleApplication(url, ToolConstants.deviceHubBundleIdentifier)
                try await WorkspaceClient.terminateDeviceHubCompanion(application, at: url)
            } catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
    }

    private func prepare(at applicationURL: URL) -> Task<Void, any Error> {
        let url = applicationURL.standardizedFileURL.resolvingSymlinksInPath()
        if let task = launches[url] { return task }
        if let process = companions[url], process.isRunning { return Task {} }

        let task = Task { [self] in
            defer { launches.removeValue(forKey: url) }
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
                    guard let self, self.companions[url]?.processIdentifier == process.processIdentifier else { return }
                    self.companions.removeValue(forKey: url)
                    guard self.enabled, self.launches[url] == nil else { return }
                    let task = self.prepare(at: url)
                    Task { do { try await task.value } catch { self.onError?(error) } }
                }
            }
            try process.run()
            companions[url] = process
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
            } catch let error {
                companions.removeValue(forKey: url)
                try await WorkspaceClient.finishFailedNeoHostLaunch(error, processIdentifier: process.processIdentifier)
                {
                    try await self.terminate(process)
                }
            }
        }
        launches[url] = task
        return task
    }

    private var executableURL: URL { rendererURL.appendingPathComponent("Contents/MacOS/NeoSimulatorRenderer") }

    private func terminate(_ process: Process) async throws {
        if process.isRunning, kill(process.processIdentifier, SIGKILL) != 0, errno != ESRCH {
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
