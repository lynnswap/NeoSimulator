import Foundation
import NeoSimulatorDeviceIO

/// A check of whether another application is already displaying the simulators.
@MainActor
package protocol HostConflictChecking: AnyObject {
    /// The name of an application that displays the simulators now, if any.
    var conflictingHostName: String? { get }
    /// Called on the main actor when such an application appears.
    var onConflict: (() -> Void)? { get set }
    /// Throws ``SimulatorError/conflict(_:)`` when such an application is running.
    func check() throws
}

/// A check for a host that nothing can conflict with, as nothing displays its devices.
@MainActor
package final class NoHostConflicts: HostConflictChecking {
    package var conflictingHostName: String? { nil }
    package var onConflict: (() -> Void)?
    package init() {}
    package func check() throws {}
}

/// What a host wants connected. `checkWanted` throws once the connection is no longer wanted, whether by cancellation or
/// by a conflict; a connection checks it whenever it has waited.
@MainActor
package struct DeviceConnectionRequest {
    package let device: SimulatorDevice
    package let runtime: SimulatorIORuntime
    package let checkWanted: @MainActor () throws -> Void

    package init(device: SimulatorDevice, runtime: SimulatorIORuntime, checkWanted: @escaping @MainActor () throws -> Void) {
        self.device = device
        self.runtime = runtime
        self.checkWanted = checkWanted
    }
}

/// A connected display, which is usable before its optional services are. `startOptionalServices` connects those and
/// activates them in place, and the display's `stop()` ends what it started.
@MainActor
package struct ConnectedDeviceDisplay {
    package let display: any DeviceSessionDisplay
    package let capabilities: DeviceCapabilities
    package let optionalServices: DeviceOptionalServices
    package let startOptionalServices: @MainActor () -> Void

    package init(display: any DeviceSessionDisplay, capabilities: DeviceCapabilities,
                 optionalServices: DeviceOptionalServices = DeviceOptionalServices(),
                 startOptionalServices: @escaping @MainActor () -> Void = {}) {
        self.display = display
        self.capabilities = capabilities
        self.optionalServices = optionalServices
        self.startOptionalServices = startOptionalServices
    }
}

/// What a presentation tells its host.
@MainActor
package struct DevicePresentationEvents {
    package let reportDetachedCapture: @MainActor (any Error) -> Void
    package let onClose: @MainActor (any DevicePresentation, DeviceLifetimeChoice?) -> Void
    package let onRestart: @MainActor (any DevicePresentation, Bool) -> Void
    package let onShutDown: (@MainActor (any DevicePresentation) -> Void)?

    package init(reportDetachedCapture: @escaping @MainActor (any Error) -> Void,
                 onClose: @escaping @MainActor (any DevicePresentation, DeviceLifetimeChoice?) -> Void,
                 onRestart: @escaping @MainActor (any DevicePresentation, Bool) -> Void,
                 onShutDown: (@MainActor (any DevicePresentation) -> Void)?) {
        self.reportDetachedCapture = reportDetachedCapture
        self.onClose = onClose
        self.onRestart = onRestart
        self.onShutDown = onShutDown
    }
}

/// One device's presentation, which a host keeps across its device's restarts.
@MainActor
package protocol DevicePresentation: AnyObject {
    var session: DeviceSession { get }
    var isVisible: Bool { get }
    /// Ends the session's input and stops following it, keeping the presentation for `reconnect`.
    func prepareForRestart() async
    func reconnect(_ session: DeviceSession, present: Bool)
    func invalidate()
    func present(_ error: any Error)
    func showAndActivate()
    /// Shows a new presentation for the first time.
    func showNew()
    func setDeviceBezelVisible(_ visible: Bool)
}

/// What draws a host's devices. A host without a presenter reads and manages its devices but attaches no display.
@MainActor
package protocol DevicePresenter: AnyObject {
    /// Connects `request`'s device's display. Everything this waits for is what the display itself needs, so an optional
    /// service neither delays it nor fails it.
    func connectDisplay(_ request: DeviceConnectionRequest) async throws -> ConnectedDeviceDisplay
    /// Makes the presentation of a new session.
    func makePresentation(of session: DeviceSession, offersLifetimeChoice: Bool,
                          events: DevicePresentationEvents) throws -> any DevicePresentation
    /// Finishes the captures that outlive their sessions, and returns their failures.
    func finishCaptures() -> [any Error]
    /// Shows a device's log file.
    func openLog(_ log: URL) async throws
    /// The first language of the Mac's current keyboard input source.
    func hostKeyboardLanguage() -> String?
}
