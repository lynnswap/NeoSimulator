import Foundation

/// Connection to the device's existing TVOut screen, also used for CarPlay.
/// CoreSimulator exposes no creatable screen properties for devices without one.
///
/// A request belongs to the task that makes it: cancelling the task withdraws a request that has not started.
@MainActor
package protocol SimulatorExternalScreen: AnyObject {
    var screenID: UInt32 { get }
    /// When the device last booted. The guest's CarPlay session belongs to
    /// the boot that started it.
    var deviceBootDate: Date? { get }
    /// The screen's power, size, scale, CarPlay, and refresh rate as
    /// CoreSimulator reports them now.
    func state() throws -> ExternalScreenState
    /// The modes the screen advertises, `supportedScreenModes`, which stay the
    /// same while the device runs; only their order changes between reads.
    func supportedModes() throws -> [ExternalScreenMode]
    /// Sets a supported screen mode and powers it on, optionally with CarPlay properties. Completion reports the result
    /// on the main actor. A throw means no completion follows, and that nothing was sent unless it says otherwise.
    func setMode(pixelSize: CGSize, scale: CGFloat, carPlay: Bool,
                 completion: @escaping @MainActor (Error?) -> Void) async throws
    /// `SimScreen setPowerState:0 …`. `completion` receives CoreSimulator's result on the main actor. A throw means no
    /// completion follows, and that nothing was sent unless it says otherwise.
    func powerOff(completion: @escaping @MainActor (Error?) -> Void) async throws
    /// Writes the guest configuration read on mode changes: default CarPlay values or `{stark: 0}`.
    func saveCarPlayConfiguration(carPlay: Bool) throws
    /// Sends a counted CarPlay start/end for `boot`. Completion runs on the main actor.
    /// If the device restarted, no request is sent and completion receives `CarPlayRequestMoot`.
    func setCarPlayEnabled(_ enabled: Bool, inBoot boot: Date?, completion: @escaping @MainActor (Error?) -> Void) async
    /// Creates or removes the guest's CarPlay HID service. Completion reports send status on the main actor.
    /// A throw means no completion follows, and that nothing was sent unless it says otherwise.
    func setCarPlayService(connected: Bool, completion: @escaping @MainActor (Error?) -> Void) async throws
    /// A display of the screen from the display factory, for its own window.
    func makeDisplay() async throws -> any DeviceSessionDisplay
    /// Stops the change reports.
    func disconnect()
}
