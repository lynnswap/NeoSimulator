import Foundation

/// A device's audio routes: CoreSimDeviceIO's `SimAudioHostRoutable`.
@MainActor
package protocol SimulatorAudioRoutes: AnyObject {
    /// The Mac's audio devices and the guest's routes as the port reports them now.
    func state() async throws -> AudioRouteState
    /// Routes to a device UID or system default. Completion reports on the main actor. A throw means no completion
    /// follows, and that nothing was sent unless it says otherwise. CoreSimulator silently uses the default if the
    /// requested device is absent or lacks channels in this scope.
    func route(_ scope: AudioScope, to route: String, completion: @escaping @MainActor (Error?) -> Void) async throws
    /// Stops the change reports.
    func disconnect()
}
