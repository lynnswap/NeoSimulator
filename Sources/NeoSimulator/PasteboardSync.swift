import AppKit

/// Edit ▸ Automatically Sync Pasteboard: the app-wide choice, which
/// Simulator.app's app delegate keeps, and the exchange between devices.
///
/// While it is on, each device's pasteboard connection synchronizes:
/// SimPasteboardPlus sends each change of the Mac pasteboard to every device
/// and applies each copy on a device to the Mac pasteboard. A device's copy
/// does not reach the other devices that way, because SimPasteboardPlus
/// ignores the changes it makes to the Mac pasteboard itself, so the Mac
/// pasteboard is then sent to every other device, as Simulator.app's
/// `SimDeviceChangedLocalPasteboard` observer does. Like Simulator.app,
/// synchronization does not follow window focus: every connected device
/// takes part.
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

    /// Reads the choice saved in `preferences`, which is off unless it was
    /// turned on.
    init(preferences: any PreferenceStore = UserDefaults.standard,
         sessions: @escaping () -> [DeviceSession]) {
        self.preferences = preferences
        self.sessions = sessions
        isOn = preferences.bool(forKey: HostPreferences.pasteboardAutomaticSync)
    }

    /// Turns synchronization on or off, saves the choice, and tells every
    /// device's connection, as Simulator.app's `togglePasteboardAutomaticSync:`
    /// does. Turning it on transfers nothing until the Mac's or a device's
    /// pasteboard changes; turning it off stops every exchange that the user
    /// does not choose.
    func toggle() {
        isOn.toggle()
        preferences.set(isOn, forKey: HostPreferences.pasteboardAutomaticSync)
        for session in sessions() { session.updatePasteboardSync() }
    }

    /// Reports that `session`'s device pasteboard replaced the Mac's. Like
    /// Simulator.app's `SimDeviceChangedLocalPasteboard`, which it posts as
    /// soon as possible and coalesces by name, the change goes to the other
    /// devices when the current pass of the run loop ends, and of several
    /// changes in one pass, only the last does.
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
        for session in sessions() where session.device.id != source.device.id {
            session.sendSynchronizedPasteboard()
        }
    }
}
