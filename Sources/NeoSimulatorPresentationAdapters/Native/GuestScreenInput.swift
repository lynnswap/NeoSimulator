import Foundation
import NeoSimulatorDeviceIO

/// Sends touches on a simulator's integrated screen and its button usages to the guest's touchscreen and button services,
/// as the Indigo events that CoreDevice's digitizer and button services send them.
@MainActor
package final class GuestScreenInput: NativeScreenInputTransport {
    private let digitizer: GuestHIDConnection
    private let buttons: GuestHIDConnection
    private let codec: GuestHIDCodec
    private var pressed = RemoteScreenPressedInputs()

    package init(guest: SimulatorGuestHID) async throws {
        digitizer = try await guest.connection(to: CoreDeviceScreenInput.features[.digitizer]!)
        buttons = try await guest.connection(to: CoreDeviceScreenInput.features[.button]!)
        codec = guest.codec
    }

    package func send(_ input: RemoteScreenInput) async throws {
        switch input {
        case .touch(let point, let second, let phase, let edge):
            try digitizer.post(.digitizerEvent, codec.digitizerEvent(at: point, second: second, phase: phase, edge: edge))
        case .button(let page, let usage, let state):
            try buttons.postButton(usagePage: page, usage: usage, state: state)
        case .key, .pointer, .pointerButton, .trackpad, .gesturePointer:
            throw DeviceIOError.unavailable("remote-display-input", "The guest's screen input carries only touches and buttons.")
        }
        pressed.record(input)
    }

    /// Releases the touch and then the buttons that the guest holds, and waits until the connections have sent every
    /// message, since releasing a connection discards those it has not sent. What could not be released stays held for
    /// the next stop.
    package func stop() async throws {
        var failures: [String] = []
        if let (point, second, edge) = pressed.touch {
            do { try await send(.touch(point, second, .ended, edge)) } catch { failures.append(error.localizedDescription) }
        }
        for button in pressed.buttons.sorted(by: { ($0.page, $0.usage) < ($1.page, $1.usage) }) {
            do { try await send(.button(button.page, button.usage, .up)) } catch { failures.append(error.localizedDescription) }
        }
        do { try await digitizer.flush() } catch { failures.append(error.localizedDescription) }
        do { try await buttons.flush() } catch { failures.append(error.localizedDescription) }
        if !failures.isEmpty { throw DeviceIOError.io("remote-input-release", failures.joined(separator: "\n")) }
    }
}

/// Sends a simulator's button usages to the guest's button service, as the Indigo events that CoreDevice's button service
/// sends it, for a screen whose touches DeviceKit's view owns. The buttons need only the booted guest, not CoreDevice's
/// view of it. They prepare and connect at the first press, so neither holds the screen. A press whose connection has
/// ended connects again; what was sent before is not sent again.
@MainActor
package final class GuestButtonInput: NativeScreenInputTransport {
    private let prepare: @MainActor () async throws -> SimulatorGuestHID
    private var connection: GuestHIDConnection?
    private var pressed = RemoteScreenPressedInputs()

    package init(prepare: @escaping @MainActor () async throws -> SimulatorGuestHID) {
        self.prepare = prepare
    }

    package func send(_ input: RemoteScreenInput) async throws {
        guard case .button(let page, let usage, let state) = input else {
            throw DeviceIOError.unavailable("remote-display-input", "The guest's button input carries only buttons.")
        }
        let connection: GuestHIDConnection
        if let current = self.connection, !current.hasFailed {
            connection = current
        } else {
            connection = try await prepare().connection(to: CoreDeviceScreenInput.features[.button]!)
            self.connection = connection
        }
        try connection.postButton(usagePage: page, usage: usage, state: state)
        pressed.record(input)
    }

    /// Releases the buttons that the guest holds, and waits until the connection has sent every message. What could not
    /// be released stays held for the next stop.
    package func stop() async throws {
        var failures: [String] = []
        for button in pressed.buttons.sorted(by: { ($0.page, $0.usage) < ($1.page, $1.usage) }) {
            do { try await send(.button(button.page, button.usage, .up)) } catch { failures.append(error.localizedDescription) }
        }
        do { try await connection?.flush() } catch { failures.append(error.localizedDescription) }
        if !failures.isEmpty { throw DeviceIOError.io("remote-input-release", failures.joined(separator: "\n")) }
    }
}
