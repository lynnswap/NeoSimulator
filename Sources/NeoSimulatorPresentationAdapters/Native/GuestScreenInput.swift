import ABIBridge
import Foundation
import NeoSimulatorDeviceIO

/// Sends integrated-screen touches and buttons through guest HID services.
/// When explicit contact identities are needed, mouse and trackpad touches share the built-in digitizer connection.
@MainActor
package final class GuestScreenInput: NativeScreenInputTransport {
    private enum Digitizer {
        case indigo(GuestHIDConnection)
        case contacts(GuestContactInput)
    }
    private let digitizer: Digitizer
    private let buttons: GuestHIDConnection
    private let codec: GuestHIDCodec
    private var pressed = RemoteScreenPressedInputs()

    package init(guest: SimulatorGuestHID, contactIdentities: Bool = false) async throws {
        if contactIdentities {
            digitizer = .contacts(try await GuestContactInput(guest: guest))
        } else {
            digitizer = .indigo(try await guest.connection(to: CoreDeviceScreenInput.features[.digitizer]!))
        }
        buttons = try await guest.connection(to: CoreDeviceScreenInput.features[.button]!)
        codec = guest.codec
    }

    package func send(_ input: RemoteScreenInput) async throws {
        switch input {
        case .touch(let point, let second, let phase, let edge):
            switch digitizer {
            case .indigo(let connection):
                try connection.post(.digitizerEvent, codec.digitizerEvent(at: point, second: second, phase: phase, edge: edge))
            case .contacts(let input):
                try await input.send(point: point, second: second, phase: phase, edge: edge)
            }
        case .contacts(let contacts):
            guard case .contacts(let input) = digitizer else {
                throw DeviceIOError.unavailable("guest-contact-input", "This connection has no contact identity input.")
            }
            try await input.send(contacts)
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
        if !pressed.contacts.isEmpty {
            let releases = pressed.contacts.sorted { $0.key < $1.key }
                .map { NativeTouchContact(id: $0.key, point: $0.value, isTouching: false) }
            do { try await send(.contacts(releases)) } catch { failures.append(error.localizedDescription) }
        }
        for button in pressed.buttons.sorted(by: { ($0.page, $0.usage) < ($1.page, $1.usage) }) {
            do { try await send(.button(button.page, button.usage, .up)) } catch { failures.append(error.localizedDescription) }
        }
        do {
            switch digitizer {
            case .indigo(let connection): try await connection.flush()
            case .contacts(let input): try await input.stop()
            }
        } catch { failures.append(error.localizedDescription) }
        do { try await buttons.flush() } catch { failures.append(error.localizedDescription) }
        if !failures.isEmpty { throw DeviceIOError.io("remote-input-release", failures.joined(separator: "\n")) }
    }
}

/// Keeps the built-in digitizer's contact identities, which Indigo's two-point facade cannot express.
@MainActor
private final class GuestContactInput {
    private let connection: GuestHIDConnection
    private let codec: GuestHIDCodec
    private let reports: CoreDeviceDigitizerReports
    private let digitizerID: NativeSwiftValue
    private let activationDescriptor: NativeSwiftValue
    private var activation: CoreDeviceHIDService?

    init(guest: SimulatorGuestHID) async throws {
        connection = try await guest.connection(to: CoreDeviceHIDService.universalHIDFeature)
        codec = guest.codec
        reports = try await CoreDeviceDigitizerReports(runtime: .shared)
        let idType = try await ABIRuntime.shared.resolve(.swift(.type("CoreDevice.HIDServiceID")))
        digitizerID = try await unsafe idType.resolve(.swift(.staticGetter("mainTouchscreen",
            as: (() -> NativeSwiftValue).self, valueABIs: [idType: try .opaque(named: idType.name)]))).unsafeInvoke()
        activationDescriptor = try await CoreDeviceHIDService.touchscreenGestureDescriptor(runtime: .shared)
    }

    func send(point: CGPoint, second: CGPoint?, phase: RemoteDeviceTouchPhase, edge: RemoteDeviceTouchEdge) async throws {
        try await post(reports.make(point: point, second: second, phase: phase, edge: edge))
    }

    func send(_ contacts: [NativeTouchContact]) async throws {
        try await post(reports.make(contacts: contacts))
    }

    private func post(_ report: NativeSwiftValue) async throws {
        // Creating a service activates the session's built-in digitizer. A newly created touchscreen service is
        // external input on iOS 26 iPhone, so the contact reports must target mainTouchscreen itself.
        if activation == nil { activation = try await connection.createService(activationDescriptor) }
        try connection.post(.request, codec.send(report, to: digitizerID))
    }

    func stop() async throws {
        try await connection.flush()
        try await activation?.stop()
        activation = nil
    }
}

/// Sends button usages as CoreDevice-compatible Indigo events while DeviceKit owns touches.
/// Connects on the first press using only the booted guest, without delaying the screen.
/// Reconnects after disconnection without replaying previous input.
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
