import AppKit
import os

@MainActor
final class HostConflictMonitor {
    private let observedConflict = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let notificationCenter: NotificationCenter
    private var observer: (any NSObjectProtocol)?
    var onConflict: (() -> Void)?

    init(notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.notificationCenter = notificationCenter
        let observedConflict = observedConflict
        observer = notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
        ) { [weak self, observedConflict] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let name = Self.conflictName(for: application.bundleIdentifier) else { return }
            // Startup may still be synchronous on the main actor. Retain the
            // notification immediately, before scheduling display teardown.
            observedConflict.withLock { $0 = name }
            Task { @MainActor [weak self] in self?.onConflict?() }
        }
    }

    var conflictingHostName: String? {
        if let recorded = observedConflict.withLock({ $0 }) { return recorded }
        for identifier in ["com.apple.dt.Devices", "com.apple.iphonesimulator"] {
            if !NSRunningApplication.runningApplications(withBundleIdentifier: identifier).isEmpty {
                return Self.conflictName(for: identifier)
            }
        }
        return nil
    }

    func check() throws {
        if let name = conflictingHostName {
            throw HostError.conflict("\(name) is running or launched during startup; close it before opening NeoSimulator")
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
