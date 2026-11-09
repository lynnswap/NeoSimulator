import AppKit
import NeoSimulatorKit
import os

@MainActor
package final class HostConflictMonitor: HostConflictChecking {
    private let observedConflict = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let notificationCenter: NotificationCenter
    private let allowsDeviceHub: @Sendable (pid_t, URL?) -> Bool
    private var observer: (any NSObjectProtocol)?
    package var onConflict: (() -> Void)?

    package init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        allowsDeviceHub: @escaping @Sendable (pid_t, URL?) -> Bool = { _, _ in false }
    ) {
        self.notificationCenter = notificationCenter
        self.allowsDeviceHub = allowsDeviceHub
        let observedConflict = observedConflict
        observer = notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
        ) { [weak self, observedConflict] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let name = Self.conflictName(for: application.bundleIdentifier) else { return }
            if application.bundleIdentifier == "com.apple.dt.Devices",
                allowsDeviceHub(application.processIdentifier, application.bundleURL)
            {
                return
            }
            // Startup may still be synchronous on the main actor. Retain the
            // notification immediately, before scheduling display teardown.
            observedConflict.withLock { $0 = name }
            Task { @MainActor [weak self] in self?.onConflict?() }
        }
    }

    package var conflictingHostName: String? {
        if let recorded = observedConflict.withLock({ $0 }) { return recorded }
        for identifier in ["com.apple.dt.Devices", "com.apple.iphonesimulator"] {
            if NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: {
                identifier != "com.apple.dt.Devices" || !allowsDeviceHub($0.processIdentifier, $0.bundleURL)
            }) {
                return Self.conflictName(for: identifier)
            }
        }
        return nil
    }

    package func check() throws {
        if let name = conflictingHostName {
            throw SimulatorError.conflict("\(name) is running or launched during startup; close it before opening the simulator display")
        }
    }

    nonisolated private static func conflictName(for identifier: String?) -> String? {
        switch identifier {
        case "com.apple.dt.Devices": "Device Hub"
        case "com.apple.iphonesimulator": "Simulator"
        default: nil
        }
    }

    isolated deinit {
        if let observer { notificationCenter.removeObserver(observer) }
    }
}
