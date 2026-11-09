import AppKit
import Darwin
import Foundation
import NeoSimulatorDeviceIO
import NeoSimulatorKit
import Synchronization

/// Keeps Xcode on its externally managed simulator route without presenting a second display host.
@MainActor
package final class DeviceHubCompanions {
    @MainActor private final class Companion {
        let application: NSRunningApplication
        private var observations: [NSKeyValueObservation]

        init(application: NSRunningApplication, observations: [NSKeyValueObservation]) {
            self.application = application
            self.observations = observations
        }

        func stopObserving() {
            observations.forEach { $0.invalidate() }
            observations = []
        }

        isolated deinit {
            // NSRunningApplication's KVO registrations must end before its last strong reference is released.
            withExtendedLifetime(application) { observations.forEach { $0.invalidate() } }
        }
    }

    nonisolated private let owner = Mutex<RendererOwnerIdentity?>(nil)
    private var companions: [URL: Companion] = [:]
    private var launches: [URL: Task<Void, any Error>] = [:]
    private var workspaceObservers: [any NSObjectProtocol] = []
    private var enabled = false
    package var onError: ((any Error) -> Void)?

    package init() {}

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
            let marker = arguments.firstIndex(of: "-NeoSimulatorCompanionOwner"),
            arguments.indices.contains(marker + 1)
        else { return nil }
        let fields = arguments[marker + 1].split(separator: ":", maxSplits: 1)
        guard fields.count == 2, let pid = pid_t(fields[0]), pid > 0, let seconds = TimeInterval(fields[1]),
            seconds.isFinite
        else { return nil }
        return RendererOwnerIdentity(processIdentifier: pid, launchDate: Date(timeIntervalSinceReferenceDate: seconds))
    }

    nonisolated private static func token(for owner: RendererOwnerIdentity) -> String {
        "\(owner.processIdentifier):\(owner.launchDate.timeIntervalSinceReferenceDate)"
    }

    package func start(at applicationURL: URL) async throws {
        let identity = try RendererOwnerIdentity.current()
        owner.withLock { $0 = identity }
        enabled = true
        if workspaceObservers.isEmpty {
            for name in [
                NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification,
                NSWorkspace.didUnhideApplicationNotification,
            ] {
                workspaceObservers.append(
                    NSWorkspace.shared.notificationCenter.addObserver(
                        forName: name, object: nil, queue: .main
                    ) { [weak self] notification in
                        guard
                            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                                as? NSRunningApplication
                        else { return }
                        MainActor.assumeIsolated {
                            guard let self, self.enabled else { return }
                            if application.bundleIdentifier == ToolConstants.deviceHubBundleIdentifier,
                                self.allows(
                                    processIdentifier: application.processIdentifier, bundleURL: application.bundleURL)
                            {
                                if application.isFinishedLaunching { _ = application.hide() }
                                return
                            }
                            guard application.bundleIdentifier == ToolConstants.xcodeBundleIdentifier,
                                let url = application.bundleURL
                            else { return }
                            let hub = url.appendingPathComponent(ToolConstants.deviceHubPath)
                            guard FileManager.default.fileExists(atPath: hub.path) else { return }
                            let task = self.prepare(at: hub)
                            Task {
                                do { try await task.value } catch { self.onError?(error) }
                            }
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
        var failure: (any Error)?
        for task in launches.values {
            do { try await task.value } catch { if failure == nil { failure = error } }
        }
        for (url, companion) in companions {
            do {
                companion.stopObserving()
                try await WorkspaceClient.terminateDeviceHubCompanion(companion.application, at: url)
                companions.removeValue(forKey: url)
            } catch { if failure == nil { failure = error } }
        }
        // A host selection can survive its manager crashing before it released the previous companions.
        for application in NSRunningApplication.runningApplications(
            withBundleIdentifier: ToolConstants.deviceHubBundleIdentifier)
        {
            guard let previousOwner = Self.companionOwner(processIdentifier: application.processIdentifier),
                let url = application.bundleURL
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
        if let companion = companions[url], !companion.application.isTerminated {
            hide(companion.application)
            return Task {}
        }

        let task = Task {
            defer {
                launches.removeValue(forKey: url)
            }
            try CodeSignatureValidator.live.validateAppleApplication(url, ToolConstants.deviceHubBundleIdentifier)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.hides = true
            configuration.addsToRecentItems = false
            configuration.allowsRunningApplicationSubstitution = false
            configuration.arguments = [
                "-disableAutoStartLiveDeviceView", "YES",
                "-shutdownStartedDevicesOnQuit", "NO",
                "-NeoSimulatorCompanionOwner", Self.token(for: try RendererOwnerIdentity.current()),
            ]
            let application = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            guard application.bundleIdentifier == ToolConstants.deviceHubBundleIdentifier,
                application.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == url,
                allows(processIdentifier: application.processIdentifier, bundleURL: application.bundleURL)
            else {
                throw HostOperationError.configuration(
                    "device-hub-companion-identity", "LaunchServices opened an unexpected Device Hub application.")
            }
            adopt(application, at: url)
        }
        launches[url] = task
        return task
    }

    private func adopt(_ application: NSRunningApplication, at url: URL) {
        let launched = application.observe(\.isFinishedLaunching, options: [.new]) { [weak self] app, _ in
            Task { @MainActor in self?.hide(app) }
        }
        let terminated = application.observe(\.isTerminated, options: [.new]) { [weak self] app, _ in
            Task { @MainActor [weak self] in
                guard let self, app.isTerminated,
                    companions[url]?.application.processIdentifier == app.processIdentifier
                else { return }
                companions[url]?.stopObserving()
                companions.removeValue(forKey: url)
                guard enabled else { return }
                let preparation = prepare(at: url)
                Task {
                    do { try await preparation.value } catch { onError?(error) }
                }
            }
        }
        companions[url] = Companion(application: application, observations: [launched, terminated])
        hide(application)
    }

    private func hide(_ application: NSRunningApplication) {
        guard !application.isTerminated, application.isFinishedLaunching else { return }
        // hide() is a request; isHidden changes asynchronously after it returns.
        if !application.isHidden { _ = application.hide() }
    }

    isolated deinit {
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}
