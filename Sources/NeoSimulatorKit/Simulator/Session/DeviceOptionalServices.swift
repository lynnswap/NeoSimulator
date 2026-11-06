import Observation

/// How far an optional service of an open device has come. The display opens without waiting for these services.
public enum SimulatorServiceReadiness: Sendable {
    /// The device's capabilities route nothing to the service, as with touch pressure, whose touches only SimulatorKit carries.
    case notRouted
    /// The routed transport has no such service for this device.
    case unsupported
    /// The routed transport has not connected yet. A pasteboard starts connecting when a transfer first needs it.
    case pending
    case ready
    /// The routed transport could not be reached. This says nothing about whether the device supports it, so nothing else
    /// takes its place, and retrying asks it again.
    case failed(any Error)

    public var failure: (any Error)? { if case .failed(let error) = self { error } else { nil } }
}

/// The optional services of one connected display and whether each is ready.
@MainActor
@Observable
package final class DeviceOptionalServices {
    /// The device's native keyboard, trackpad and touches. Until they are ready, SimulatorKit's input stays live, as the
    /// guest has not yet been sent any native input.
    package private(set) var input = SimulatorServiceReadiness.notRouted
    /// The device's routed pasteboard transport, which only a transfer waits for.
    package private(set) var pasteboard = SimulatorServiceReadiness.notRouted
    /// Connects the input route again, set by whatever owns the route.
    @ObservationIgnored package var onRetryInput: (@MainActor () -> Void)?

    package init() {}

    package func setInput(_ readiness: SimulatorServiceReadiness) { input = readiness }
    package func setPasteboard(_ readiness: SimulatorServiceReadiness) { pasteboard = readiness }

    /// Connects the input route again after a failure. A route that is pending, ready or unsupported stays as it is.
    package func retryInput() {
        guard case .failed = input else { return }
        onRetryInput?()
    }
}
