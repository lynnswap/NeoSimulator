import Foundation

/// A callback about a device's pasteboard connection, as SimPasteboardPlus reports it.
package enum SimulatorPasteboardEvent {
    /// The connection became active: once after connecting, and again each
    /// time the device has taken a push, which `simctl pbsync` waits for.
    case activated
    /// The managed pasteboard was replaced; `generation` is its resulting change count.
    case applied(generation: Int)
    /// Writing the device's pasteboard to the managed pasteboard failed.
    case failedToApply(Error)
    /// Sending the managed pasteboard to the device failed. SimPasteboardPlus does not report it.
    case failedToSend(Error)
    /// Automatic synchronization replaced the managed pasteboard with the device's; `generation` is its resulting
    /// change count. It completes no Get Pasteboard. SimPasteboardPlus reports `applied` instead.
    case appliedAutomatically(generation: Int)
    /// An automatic transfer in the given direction failed. It fails no requested transfer. SimPasteboardPlus does not
    /// report it.
    case automaticTransferFailed(PasteboardTransfer, Error)
    /// The device closed the connection. Later pushes and pulls on it do nothing.
    case lostConnection
    /// The connection started or stopped synchronizing automatically.
    case synchronizationChanged(Bool)
    /// Observing a pasteboard failed, which stopped automatic synchronization until it is turned on again. The
    /// connection still transfers on request. SimPasteboardPlus does not report it.
    case synchronizationFailed(Error)
}

/// A device's pasteboard connection. Releasing it closes the connection.
@MainActor
package protocol SimulatorPasteboard: AnyObject {
    /// SimPasteboardPlus `pull`: Edit ▸ Get Pasteboard.
    func pull() async throws
    /// SimPasteboardPlus `push`: Edit ▸ Send Pasteboard.
    func push() async throws
    /// Sends the managed pasteboard for automatic synchronization rather than for Send Pasteboard, so that its outcome
    /// completes no requested transfer.
    func pushAutomatically() async throws
    /// Enables bidirectional automatic synchronization without an immediate transfer.
    func setAutomaticSync(_ enabled: Bool) async throws
    /// Stops the connection's events.
    func disconnect()
}

extension SimulatorPasteboard {
    /// SimPasteboardPlus reports every push alike.
    package func pushAutomatically() async throws { try await push() }
}
