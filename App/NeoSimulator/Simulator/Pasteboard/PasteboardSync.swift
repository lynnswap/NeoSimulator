import AppKit

/// Coordinates app-wide pasteboard synchronization across all connected devices.
/// No connection sends a device-originated copy on by itself: SimPasteboardPlus
/// ignores its own host writes, and the CoreDevice pasteboard skips Mac changes
/// that originated on another pasteboard. Such a copy must be forwarded
/// explicitly to the other devices.
@MainActor
final class PasteboardSync {
    private let preferences: any PreferenceStore
    /// The connected devices, which the host's windows own.
    private let sessions: () -> [DeviceSession]
    /// Whether synchronization is on, saved as `PasteboardAutomaticSync`.
    private(set) var isOn: Bool
    /// The device whose pasteboard last replaced the Mac's, until the change
    /// is sent to the other devices.
    private var changedSession: DeviceSession?
    /// The number of the latest device copy that a connection observed. A
    /// device copy replaces the Mac pasteboard only while it is the latest, so
    /// that an earlier copy from any device, whose write comes later, does not
    /// replace a later one.
    private var latestDeviceCopy = 0

    /// Reads the choice saved in `preferences`, which is off unless it was
    /// turned on.
    init(preferences: any PreferenceStore = HostPreferences.defaults,
         sessions: @escaping () -> [DeviceSession]) {
        self.preferences = preferences
        self.sessions = sessions
        isOn = preferences.bool(forKey: HostPreferences.pasteboardAutomaticSync)
    }

    /// Saves the preference and updates all connections without an immediate transfer.
    func toggle() {
        isOn.toggle()
        preferences.set(isOn, forKey: HostPreferences.pasteboardAutomaticSync)
        for session in sessions() { session.updatePasteboardSync() }
    }

    /// Numbers a device copy that a connection observed, as the latest one.
    func observeDeviceCopy() -> Int {
        latestDeviceCopy += 1
        return latestDeviceCopy
    }

    /// Whether no device copy has been observed since the one `copy` numbers.
    func isLatestDeviceCopy(_ copy: Int) -> Bool { copy == latestDeviceCopy }

    /// Coalesces device-originated copies until the end of the run-loop pass.
    /// Only the latest host pasteboard is forwarded to other devices.
    func devicePasteboardDidReplaceHost(_ session: DeviceSession) {
        let isScheduled = changedSession != nil
        changedSession = session
        guard !isScheduled else { return }
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            MainActor.assumeIsolated { self?.sendChange() }
        }
    }

    private func sendChange() {
        guard let source = changedSession else { return }
        changedSession = nil
        // Simulator.app observes the change only while synchronization is on.
        guard isOn else { return }
        for session in sessions() where session.device.identity != source.device.identity {
            session.sendSynchronizedPasteboard()
        }
    }
}
