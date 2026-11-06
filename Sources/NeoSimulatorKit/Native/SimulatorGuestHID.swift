import ABIBridge
import AppKit
import Darwin
import NeoSimulatorDeviceIO
import os
import XPC

/// The guest HID services that CoreDevice reaches for a default-set simulator: its touchscreen, buttons, and UniversalHID
/// services. They are reached here through the Mach services that the simulator's own device looks up, so a simulator of
/// any device set has them.
@MainActor
package struct SimulatorGuestHID {
    package let codec: GuestHIDCodec
    private let connect: @MainActor (String) async throws -> xpc_connection_t

    /// Prepares the guest services' messages without connecting to the guest. `lookUp` returns a caller-owned send right
    /// to the guest's Mach service of a name, as the simulator's `SimDevice` looks it up.
    package init(lookUp: @escaping @MainActor (String) async throws -> UInt32) async throws {
        let runtime = ABIRuntime.shared
        codec = try await GuestHIDCodec(runtime: runtime)
        // SimulatorCoreDevicePlugin connects CoreDevice to a simulator's guest services with these.
        let makeEndpoint = try await runtime.resolve(.c(.function("xpc_endpoint_create_mach_port_4sim",
            as: ((UInt32) -> Unmanaged<AnyObject>?).self)))
        let enableGuestPeer = try await runtime.resolve(.c(.function("xpc_connection_enable_sim2host_4sim",
            as: ((Unmanaged<AnyObject>) -> Void).self)))
        connect = { name in
            let port = try await lookUp(name)
            // A created endpoint owns the send right, and releases it with its last reference; otherwise it remains ours.
            let created: Unmanaged<AnyObject>?
            do { created = try unsafe makeEndpoint.unsafeInvoke(port) } catch {
                mach_port_deallocate(mach_task_self_, port)
                throw error
            }
            guard let created else {
                mach_port_deallocate(mach_task_self_, port)
                throw CLIError.unavailable("guest-hid-endpoint", "libxpc could not create an endpoint for the guest's \(name) service.")
            }
            guard let endpoint = unsafe created.takeRetainedValue() as? xpc_endpoint_t else {
                throw CLIError.software("guest-hid-endpoint", "libxpc returned an endpoint for the guest's \(name) service that is not an XPC object.")
            }
            let connection = xpc_connection_create_from_endpoint(endpoint)
            // The plugin enables this on each connection before it activates the connection.
            do { try unsafe enableGuestPeer.unsafeInvoke(.passUnretained(connection as AnyObject)) } catch {
                Self.discard(connection)
                throw error
            }
            return connection
        }
    }

    /// Reaches each guest service through the connection that `connect` creates for its name and has not activated.
    package init(codec: GuestHIDCodec, connect: @escaping @MainActor (String) async throws -> xpc_connection_t) {
        self.codec = codec
        self.connect = connect
    }

    /// A new connection to the guest service of `feature`, the name of both its Mach service and its messages' feature.
    package func connection(to feature: String) async throws -> GuestHIDConnection {
        GuestHIDConnection(try await connect(feature), feature: feature, codec: codec)
    }

    /// Ends a connection that was never activated; libxpc requires a connection to be activated before its release.
    private static func discard(_ connection: xpc_connection_t) {
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_cancel(connection)
        xpc_connection_activate(connection)
    }
}

/// One connection to a guest HID service. The guest keeps the services that a connection creates until the connection
/// ends, so the owner of a stream's services owns its connection. Releasing the connection cancels it.
@MainActor
package final class GuestHIDConnection {
    private nonisolated static let logger = Logger(subsystem: "dev.lynnswap.NeoSimulator", category: "GuestHID")
    private let connection: xpc_connection_t
    private let feature: String
    private let codec: GuestHIDCodec
    /// Why the connection ended. An ended connection sends nothing.
    private var failure: (any Error)?
    package var hasFailed: Bool { failure != nil }

    /// Activates `connection`, which has not been activated.
    package init(_ connection: xpc_connection_t, feature: String, codec: GuestHIDCodec) {
        self.connection = connection
        self.feature = feature
        self.codec = codec
        xpc_connection_set_target_queue(connection, .main)
        xpc_connection_set_event_handler(connection) { [weak self] event in
            guard xpc_get_type(event) == XPC_TYPE_ERROR else {
                Self.logger.error("Ignored a message that the guest's \(feature, privacy: .public) service sent unrequested")
                return
            }
            let failure = Self.failure(event, feature: feature)
            // The connection delivers its events on the main queue.
            MainActor.assumeIsolated { if let self, self.failure == nil { self.failure = failure } }
        }
        xpc_connection_activate(connection)
    }

    isolated deinit { xpc_connection_cancel(connection) }

    /// Sends a message that has no reply. The service receives the messages of a connection in the order they are sent.
    package func post(_ type: GuestHIDCodec.MessageType, _ payload: NativeSwiftValue) throws {
        if let failure { throw failure }
        xpc_connection_send_message(connection, try codec.message(type, to: feature, payload: payload))
    }

    /// Sends a message and returns the service's reply, whose contents the message type defines. The reply is awaited even
    /// when the caller is cancelled, so that what the message creates in the guest gets an owner. A bounded request
    /// closes its connection on timeout, which also ends what the guest created for the connection.
    package func request(_ type: GuestHIDCodec.MessageType, _ payload: NativeSwiftValue,
                         timeout: Duration? = nil) async throws -> xpc_object_t {
        try await request(codec.message(type, to: feature, payload: payload), timeout: timeout)
    }

    /// Sends a CoreDevice action envelope to this guest service.
    package func request(_ message: xpc_object_t, timeout: Duration?, cancelsWithTask: Bool = false) async throws -> xpc_object_t {
        if let failure { throw failure }
        if cancelsWithTask { try Task.checkCancellation() }
        let deadline = timeout.map { timeout in
            Task { @MainActor in
                do { try await Task.sleep(for: timeout) } catch { return }
                self.failure = CLIError.unavailable("guest-service-timeout", "The guest's \(self.feature) service timed out.")
                xpc_connection_cancel(self.connection)
            }
        }
        defer { deadline?.cancel() }
        let reply: xpc_object_t = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                xpc_connection_send_message_with_reply(connection, message, .main) { reply in
                    // libxpc does not modify a reply it has delivered.
                    nonisolated(unsafe) let received = reply
                    continuation.resume(returning: received)
                }
            }
        } onCancel: {
            guard cancelsWithTask else { return }
            Task { @MainActor in
                self.failure = CancellationError()
                xpc_connection_cancel(self.connection)
            }
        }
        if let failure { throw failure }
        guard xpc_get_type(reply) != XPC_TYPE_ERROR else {
            let error = Self.failure(reply, feature: feature)
            failure = error
            throw error
        }
        return reply
    }

    /// Creates the guest service that `descriptor`, a CoreDevice `HIDServiceDescriptor`, describes, with the requests
    /// that CoreDevice's UniversalHID service sends. The service retains this connection. A guest that does not answer in
    /// time loses the connection, and with it any service this message creates.
    package func createService(_ descriptor: NativeSwiftValue) async throws -> CoreDeviceHIDService {
        let reply = try await request(.request, codec.createService(descriptor), timeout: DeviceOperationLimit.guestService)
        let serviceID = try codec.serviceID(createdBy: reply)
        // The returned service has an owner before cancellation can abandon it.
        return CoreDeviceHIDService(send: { [self] report in try post(.request, codec.send(report, to: serviceID)) },
            reset: { [self] in try post(.request, codec.resetGestureState(of: serviceID)) },
            remove: { [self] in
                // The guest removes the services of a connection when the connection ends.
                guard failure == nil else { return }
                let removal = try await codec.removeService(serviceID)
                try post(.request, removal)
            })
    }

    /// Waits until the messages sent before have left the connection; cancelling a connection discards those it has not
    /// sent. A guest that does not take them in time loses the connection, which this reports.
    package func flush() async throws {
        let barrier = Task.immediate {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                xpc_connection_send_barrier(connection) { continuation.resume() }
            }
        }
        guard await !barrier.ends(before: .now + DeviceOperationLimit.guestService) else { return }
        let error = CLIError.unavailable("guest-service-timeout", "The guest's \(feature) service did not take the messages sent to it.")
        if failure == nil { failure = error }
        xpc_connection_cancel(connection)
        throw error
    }

    private nonisolated static func failure(_ event: xpc_object_t, feature: String) -> CLIError {
        let reason = unsafe xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION).map { unsafe String(cString: $0) }
        return .unavailable("guest-hid-connection",
            "The connection to the guest's \(feature) service ended: \(reason ?? "libxpc gave no reason").")
    }
}

/// The messages of the guest's HID services and their replies. Messages carry the CoreDeviceUtilities values that
/// CoreDevice sends the services, encoded with Mercury's XPC encoder as CoreDevice encodes them, so the guest reads them
/// as it reads CoreDevice's; replies are decoded with Mercury's XPC decoder as CoreDevice decodes them.
@MainActor
package struct GuestHIDCodec {
    /// The message types that CoreDevice sends the guest's touchscreen, button, and UniversalHID services.
    package enum MessageType: String {
        case digitizerEvent = "IndigoDigitizerEvent", buttonEvent = "IndigoButtonEvent", request = "Request"
        case orientation = "OrientationRequest"
    }

    /// CoreDevice's binary, which loads the CoreDeviceUtilities values and Mercury encoder that CoreDevice's messages use.
    package static let coreDevicePath = "/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice"

    private let featureKey: String
    private let messageTypeKey: String
    private let payloadKey: String
    /// Encodes the payload of each message type with Mercury's encoder for the payload's type.
    private let encoders: [MessageType: (NativeSwiftValue) throws -> xpc_object_t]
    private let makeDigitizerEvent: (CGPoint, CGPoint?, RemoteDeviceTouchPhase, RemoteDeviceTouchEdge) throws -> NativeSwiftValue
    private let makeButtonEvent: (UInt16, UInt16, RemoteDeviceButtonState) throws -> NativeSwiftValue
    private let requestType: NativeSwiftType
    private let readReportData: NativeSwiftMethod<() -> Data>
    private let readCreatedService: (xpc_object_t) throws -> NativeSwiftValue
    private let orientationRequestType: NativeSwiftType
    private let orientationType: NativeSwiftType
    private let rotationDirectionType: NativeSwiftType
    private let readOrientation: (xpc_object_t) throws -> OrientationReading

    package init(runtime: ABIRuntime) async throws {
        try CoreDeviceRemoteScreenDevice.load(Self.coreDevicePath)
        let event = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.HIDXPCServiceEvent")))
        featureKey = try await unsafe event.resolve(.swift(.staticGetter("featureIdentifierFieldName", as: (() -> String).self))).unsafeInvoke()
        messageTypeKey = try await unsafe event.resolve(.swift(.staticGetter("messageTypeFieldName", as: (() -> String).self))).unsafeInvoke()
        payloadKey = try await unsafe event.resolve(.swift(.staticGetter("payloadFieldName", as: (() -> String).self))).unsafeInvoke()
        let errorKey = try await unsafe event.resolve(.swift(.staticGetter("errorFieldName", as: (() -> String).self))).unsafeInvoke()

        let point = try await runtime.resolve(.swift(.type("CoreDevice.DigitizerPoint")))
        let eventType = try await runtime.resolve(.swift(.type("CoreDevice.DigitizerEventType")))
        let edge = try await runtime.resolve(.swift(.type("CoreDevice.DigitizerEdge")))
        let target = try await runtime.resolve(.swift(.type("CoreDevice.DigitizerTarget")))
        let digitizer = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.IndigoDigitizerEvent")))
        let buttonState = try await runtime.resolve(.swift(.type("CoreDevice.HIDButtonState")))
        let button = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.IndigoButtonEvent")))
        let request = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.DDIUniversalHIDServicePayload.Request")))
        requestType = request
        orientationRequestType = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.OrientationRequest")))
        orientationType = try await runtime.resolve(.swift(.type("CoreDevice.DeviceOrientation")))
        rotationDirectionType = try await runtime.resolve(.swift(.type("CoreDevice.DeviceOrientationRotationDirection")))
        // CoreDevice passes these resilient values by address.
        let abis = try Dictionary(uniqueKeysWithValues: [point, eventType, edge, target, digitizer, buttonState, button]
            .map { ($0, try NativeType.opaque(named: $0.name)) })
        // CoreDevice's digitizer makes its points with the CGFloat overload, from the screen's unit coordinates unscaled.
        let makePoint = try await point.resolve(.swift(.initializer("init(x:y:)",
            as: ((CGFloat, CGFloat) -> NativeSwiftValue).self, valueABIs: abis)))
        let makeDigitizer = try await digitizer.resolve(.swift(.initializer("init(pointOne:pointTwo:eventType:edge:target:)",
            as: ((NativeSwiftValue, NativeSwiftValue?, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue) -> NativeSwiftValue).self,
            valueABIs: abis)))
        // An initializer consumes its arguments, so each event gets its own.
        makeDigitizerEvent = { first, second, phase, touchEdge in
            let name = switch phase { case .began: "start"; case .moved: "position"; case .ended: "end" }
            return try unsafe makeDigitizer.unsafeInvoke(makePoint.unsafeInvoke(first.x, first.y),
                second.map { try unsafe makePoint.unsafeInvoke($0.x, $0.y) }, eventType.makeEnumCase(named: name),
                edge.makeEnumCase(named: touchEdge.rawValue), target.makeEnumCase(named: "mainScreen"))
        }
        let makeButton = try await button.resolve(.swift(.initializer("init(usagePage:usageCode:state:)",
            as: ((UInt16, UInt16, NativeSwiftValue) -> NativeSwiftValue).self, valueABIs: abis)))
        makeButtonEvent = { page, usage, state in
            try unsafe makeButton.unsafeInvoke(page, usage, buttonState.makeEnumCase(named: state.rawValue))
        }

        let report = try await runtime.prepare { try CoreDeviceHIDService.reportABI(runtime: $0) }
        let data = try await runtime.resolve(.swift(.type("Foundation.Data")))
        readReportData = try await report.type.resolve(.swift(.getter("data", as: (() -> Data).self,
            valueABIs: [report.type: report.abi, data: try .structure(named: data.name, fields: [.uint64, .uint64])],
            receiverABI: report.abi)))

        let encoderType = try await runtime.resolve(.swift(.type("Mercury.XPCObjectEncoder")))
        let makeEncoder = try await encoderType.resolve(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self)))
        var encoders: [MessageType: (NativeSwiftValue) throws -> xpc_object_t] = [:]
        let payloadTypes: [(MessageType, NativeSwiftType)] = [(.digitizerEvent, digitizer), (.buttonEvent, button),
            (.request, request), (.orientation, orientationRequestType)]
        for (type, payloadType) in payloadTypes {
            let encode = try await encoderType.resolve(.swift(.method(
                "Mercury.XPCObjectEncoder.encode<A where A: Swift.Encodable>(A) throws -> __C.OS_xpc_object",
                as: ((NativeSwiftValue) throws -> xpc_object_t).self, genericArguments: [.type(payloadType)])))
            // CoreDevice encodes each payload with a new encoder.
            encoders[type] = { payload in try unsafe encode.unsafeInvoke(on: makeEncoder.unsafeInvoke(), payload) }
        }
        self.encoders = encoders

        let decoderType = try await runtime.resolve(.swift(.type("Mercury.XPCObjectDecoder")))
        let makeDecoder = try await decoderType.resolve(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self)))
        let created = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.DDIUniversalHIDServicePayload.CreatedServiceID")))
        let errorContainer = try await runtime.resolve(.swift(.type("Mercury.NSErrorContainer")))
        let serviceIDType = try await runtime.resolve(.swift(.type("CoreDevice.HIDServiceID")))
        let replyABIs = try Dictionary(uniqueKeysWithValues: [created, errorContainer, serviceIDType]
            .map { ($0, try NativeType.opaque(named: $0.name)) })
        let readServiceID = try await created.resolve(.swift(.getter("serviceID", as: (() -> NativeSwiftValue).self,
            valueABIs: replyABIs, receiverABI: replyABIs[created])))
        let readError = try await errorContainer.resolve(.swift(.getter("rawValue", as: (() -> NSError).self,
            valueABIs: replyABIs, receiverABI: replyABIs[errorContainer])))
        func decoder(of type: NativeSwiftType) async throws -> (xpc_object_t) throws -> NativeSwiftValue {
            let decode = try await decoderType.resolve(.swift(.method(
                "Mercury.XPCObjectDecoder.decode<A where A: Swift.Decodable>(_: A.Type, from: __C.OS_xpc_object) throws -> A",
                as: ((NativeSwiftValue, xpc_object_t) throws -> NativeSwiftValue).self, genericArguments: [.type(type)])))
            let metatype = try type.makeMetatypeValue()
            // CoreDevice decodes each reply with a new decoder.
            return { object in try unsafe decode.unsafeInvoke(on: makeDecoder.unsafeInvoke(), metatype, object) }
        }
        let decodeCreated = try await decoder(of: created)
        let decodeError = try await decoder(of: errorContainer)
        let infoType = try await runtime.resolve(.swift(.type("CoreDevice.OrientationInfo")))
        let decodeOrientation = try await decoder(of: infoType)
        let orientationABIs = try Dictionary(uniqueKeysWithValues: [infoType, orientationType]
            .map { ($0, try NativeType.opaque(named: $0.name)) })
        let physical = try await infoType.resolve(.swift(.getter("currentDeviceOrientation",
            as: (() -> NativeSwiftValue).self, valueABIs: orientationABIs, receiverABI: orientationABIs[infoType])))
        let upright = try await infoType.resolve(.swift(.getter("currentDeviceNonFlatOrientation",
            as: (() -> NativeSwiftValue).self, valueABIs: orientationABIs, receiverABI: orientationABIs[infoType])))
        let rawValue = try await orientationType.resolve(.swift(.getter("rawValue", as: (() -> String).self,
            valueABIs: orientationABIs, receiverABI: orientationABIs[orientationType])))
        readOrientation = { reply in
            if let error = xpc_dictionary_get_value(reply, errorKey) {
                throw try unsafe readError.unsafeInvoke(on: decodeError(error))
            }
            let info = try decodeOrientation(reply)
            return try unsafe OrientationReading(physical: rawValue.unsafeInvoke(on: physical.unsafeInvoke(on: info)),
                nonFlat: rawValue.unsafeInvoke(on: upright.unsafeInvoke(on: info)))
        }
        readCreatedService = { reply in
            // The guest's error, which CoreDevice throws as it is; otherwise the reply itself is the created service's ID.
            if let error = xpc_dictionary_get_value(reply, errorKey) {
                throw try unsafe readError.unsafeInvoke(on: decodeError(error))
            }
            return try unsafe readServiceID.unsafeInvoke(on: decodeCreated(reply))
        }
    }

    /// A message of `type` to the guest service of `feature`, carrying `payload`, a value of the type's payload type.
    package func message(_ type: MessageType, to feature: String, payload: NativeSwiftValue) throws -> xpc_object_t {
        let encoded = try encoders[type]!(payload)
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, featureKey, feature)
        xpc_dictionary_set_string(message, messageTypeKey, type.rawValue)
        xpc_dictionary_set_value(message, payloadKey, encoded)
        return message
    }

    /// The touchscreen event of a touch at `point`, and `second` for a second finger, in unit coordinates from the
    /// top-left corner of the integrated screen in its own orientation.
    package func digitizerEvent(at point: CGPoint, second: CGPoint?, phase: RemoteDeviceTouchPhase,
                        edge: RemoteDeviceTouchEdge) throws -> NativeSwiftValue {
        try makeDigitizerEvent(point, second, phase, edge)
    }

    package func buttonEvent(usagePage: UInt16, usage: UInt16, state: RemoteDeviceButtonState) throws -> NativeSwiftValue {
        try makeButtonEvent(usagePage, usage, state)
    }

    /// The request that creates the service `descriptor`, a CoreDevice `HIDServiceDescriptor`, describes. It is the only
    /// request that CoreDevice awaits a reply to.
    package func createService(_ descriptor: NativeSwiftValue) async throws -> NativeSwiftValue {
        try await requestType.makeEnumCase(named: "createService", payload: descriptor)
    }

    /// The `HIDServiceID` of the service that `reply`, the reply to a createService request, identifies. Throws the
    /// guest's error instead when the reply carries one.
    package func serviceID(createdBy reply: xpc_object_t) throws -> NativeSwiftValue {
        try readCreatedService(reply)
    }

    /// The request that sends `report`, a report of CoreDevice's UniversalHID module, to the service `serviceID`.
    package func send(_ report: NativeSwiftValue, to serviceID: NativeSwiftValue) throws -> NativeSwiftValue {
        let data = try unsafe readReportData.unsafeInvoke(on: report)
        return try requestType.makeEnumCaseAndWait(named: "send", associatedValues: data, serviceID)
    }

    package func resetGestureState(of serviceID: NativeSwiftValue) throws -> NativeSwiftValue {
        try requestType.makeEnumCaseAndWait(named: "resetGestureState", payload: serviceID)
    }

    package func removeService(_ serviceID: NativeSwiftValue) async throws -> NativeSwiftValue {
        try await requestType.makeEnumCase(named: "removeService", payload: serviceID)
    }

    package func currentOrientationRequest() throws -> NativeSwiftValue {
        return try orientationRequestType.makeEnumCase(named: "currentOrientation")
    }

    package func orientationRequest(_ orientation: DeviceOrientation) throws -> NativeSwiftValue {
        try orientationRequestType.makeEnumCaseAndWait(named: "changeOrientation",
            payload: orientationType.makeEnumCase(named: orientation.rawValue))
    }

    package func rotationRequest(left: Bool) throws -> NativeSwiftValue {
        try orientationRequestType.makeEnumCaseAndWait(named: "rotate",
            payload: rotationDirectionType.makeEnumCase(named: left ? "left" : "right"))
    }

    package func orientation(from reply: xpc_object_t) throws -> OrientationReading { try readOrientation(reply) }
}

/// Controls the guest that owns the screen, including when CoreDevice discovery does not list it.
@MainActor
package final class GuestDeviceOrientation {
    package static let feature = "com.apple.coredevice.feature.remote.devicecontrol.orientation"
    private var connection: GuestHIDConnection
    private let guest: SimulatorGuestHID
    private let codec: GuestHIDCodec
    private let timeout: Duration

    package init(guest: SimulatorGuestHID, timeout: Duration = .seconds(30)) async throws {
        self.guest = guest
        connection = try await guest.connection(to: Self.feature)
        codec = guest.codec
        self.timeout = timeout
    }

    package func read() async throws -> OrientationReading {
        try await send(codec.currentOrientationRequest())
    }

    package func rotate(left: Bool) async throws -> OrientationReading {
        try await send(codec.rotationRequest(left: left))
    }

    package func set(_ orientation: DeviceOrientation) async throws -> OrientationReading {
        try await send(codec.orientationRequest(orientation))
    }

    private func send(_ request: NativeSwiftValue) async throws -> OrientationReading {
        if connection.hasFailed { connection = try await guest.connection(to: Self.feature) }
        return try codec.orientation(from: await connection.request(.orientation, request, timeout: timeout))
    }
}

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
            throw CLIError.unavailable("remote-display-input", "The guest's screen input carries only touches and buttons.")
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
        if !failures.isEmpty { throw CLIError.io("remote-input-release", failures.joined(separator: "\n")) }
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
            throw CLIError.unavailable("remote-display-input", "The guest's button input carries only buttons.")
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
        if !failures.isEmpty { throw CLIError.io("remote-input-release", failures.joined(separator: "\n")) }
    }
}

private extension GuestHIDConnection {
    func postButton(usagePage page: Int, usage: Int, state: RemoteDeviceButtonState) throws {
        guard let usagePage = UInt16(exactly: page), let usageCode = UInt16(exactly: usage) else {
            throw CLIError.unavailable("guest-button-usage", "The guest's buttons take 16-bit usage pages and usages.")
        }
        try post(.buttonEvent, codec.buttonEvent(usagePage: usagePage, usage: usageCode, state: state))
    }
}
