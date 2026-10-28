import ABIBridge
import Foundation
import IOKit
import Observation

@MainActor
final class CoreDeviceScreenInput {
    private let remote: CoreDeviceRemoteScreenDevice
    private let displayUniqueID: String?
    private var displayInput: CoreDeviceDisplayInput?
    private var displayIdentifier: UInt32?
    private var displayInputNeedsReconnect = false
    private var implementations: [RemoteDeviceInputKind: NativeSwiftValue] = [:]
    private var pressed = RemoteScreenPressedInputs()
    private var generations: [RemoteDeviceInputKind: UInt] = [:]
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    static let features: [RemoteDeviceInputKind: String] = [
        .keyboard: "com.apple.coredevice.feature.remote.hid.keyboard",
        .pointer: "com.apple.coredevice.feature.remote.hid.pointer",
        .digitizer: "com.apple.coredevice.feature.remote.hid.digitizer",
        .button: "com.apple.coredevice.feature.remote.hid.button",
    ]
    static let universalHIDFeature = "com.apple.coredevice.feature.remote.universalhidservice"

    init(remote: CoreDeviceRemoteScreenDevice, displayUniqueID: String? = nil) {
        self.remote = remote
        self.displayUniqueID = displayUniqueID
    }

    func connectDisplay(identifier: UInt32) async throws {
        guard let displayUniqueID else { return }
        displayInput = try await CoreDeviceDisplayInput.connect(remote: remote, displayID: identifier, uniqueID: displayUniqueID)
        displayIdentifier = identifier
        displayInputNeedsReconnect = false
    }

    func capabilities() throws -> Set<RemoteDeviceInputKind> {
        var result = Set(try Self.features.compactMap { try remote.supports($0.value) ? $0.key : nil })
        if displayUniqueID != nil {
            result.remove(.pointer)
            if try remote.supports(Self.universalHIDFeature) { result.insert(.digitizer) }
            else { result.remove(.digitizer) }
        }
        return result
    }

    func send(_ input: RemoteScreenInput) async throws {
        let generation = generations[input.kind, default: 0]
        await beginOperation()
        defer { finishOperation() }
        try Task.checkCancellation()
        guard generations[input.kind, default: 0] == generation else {
            throw CLIError.unavailable("remote-input-capability", "The device's input service changed before the input could be sent.")
        }
        try await sendNative(input)
        guard generations[input.kind, default: 0] == generation else {
            throw CLIError.unavailable("remote-input-capability", "The device's input service changed while the input was being sent.")
        }
        pressed.record(input)
    }

    func discardInputs(for kinds: Set<RemoteDeviceInputKind>) {
        // DeviceKit invalidates HID services when their capabilities disappear. Retire
        // their local state and handles; this does not claim an up event was delivered.
        // Other services retain their pressed state and continue normally.
        pressed.discard(for: kinds)
        if displayUniqueID != nil, kinds.contains(.digitizer) { displayInputNeedsReconnect = true }
        for kind in kinds {
            generations[kind, default: 0] += 1
            implementations.removeValue(forKey: kind)
        }
    }

    func releaseInputs() async throws {
        await beginOperation()
        defer { finishOperation() }
        var failures: [String] = []
        if let (point, second, edge) = pressed.touch {
            let generation = generations[.digitizer, default: 0]
            do { try await sendNative(.touch(point, second, .ended, edge)); pressed.touch = nil }
            catch { if generations[.digitizer, default: 0] == generation { failures.append(error.localizedDescription) } }
        }
        for (button, point) in pressed.pointerButtons.sorted(by: { $0.key < $1.key }) {
            guard pressed.pointerButtons[button] != nil else { continue }
            let generation = generations[.pointer, default: 0]
            do { try await sendNative(.pointerButton(button, .up, 1, point)); pressed.pointerButtons.removeValue(forKey: button) }
            catch { if generations[.pointer, default: 0] == generation { failures.append(error.localizedDescription) } }
        }
        for key in pressed.keys.sorted() {
            guard pressed.keys.contains(key) else { continue }
            let generation = generations[.keyboard, default: 0]
            do { try await sendNative(.key(key, .up)); pressed.keys.remove(key) }
            catch { if generations[.keyboard, default: 0] == generation { failures.append(error.localizedDescription) } }
        }
        for button in pressed.buttons.sorted(by: { ($0.page, $0.usage) < ($1.page, $1.usage) }) {
            guard pressed.buttons.contains(button) else { continue }
            let generation = generations[.button, default: 0]
            do { try await sendNative(.button(button.page, button.usage, .up)); pressed.buttons.remove(button) }
            catch { if generations[.button, default: 0] == generation { failures.append(error.localizedDescription) } }
        }
        if !failures.isEmpty { throw CLIError.io("remote-input-release", failures.joined(separator: "\n")) }
        implementations.removeAll()
    }

    func stop() async throws {
        var failure: (any Error)?
        do { try await releaseInputs() } catch { failure = error }
        if let displayInput {
            do { try await displayInput.stop(); self.displayInput = nil }
            catch { failure = failure.map { RemoteDeviceScreenSession.combining($0, cleanup: error) } ?? error }
        }
        if let failure { throw failure }
    }

    private func beginOperation() async {
        if operationInProgress { await withCheckedContinuation { operationWaiters.append($0) } }
        else { operationInProgress = true }
    }

    private func finishOperation() {
        if operationWaiters.isEmpty { operationInProgress = false }
        else { operationWaiters.removeFirst().resume() }
    }

    private func implementation(_ kind: RemoteDeviceInputKind, named capability: String) async throws -> NativeSwiftValue {
        let feature = Self.features[kind]!
        guard try remote.supports(feature) else {
            throw CLIError.unavailable("remote-input-capability", "The device no longer exposes the requested input operation.")
        }
        if let implementation = implementations[kind] { return implementation }
        let generation = generations[kind, default: 0]
        let implementation = try await remote.implementation(capability: capability, feature: feature)
        guard generations[kind, default: 0] == generation, try remote.supports(feature) else {
            throw CLIError.unavailable("remote-input-capability", "The device's input service changed while preparing the input.")
        }
        implementations[kind] = implementation
        return implementation
    }

    private func sendNative(_ input: RemoteScreenInput) async throws {
        let runtime = remote.runtime
        switch input {
        case .key(let usage, let state):
            let implementation = try await implementation(.keyboard, named: "KeyboardHIDCapability")
            let code = try runtime.resolveAndWait(.swift(.type("CoreDevice.HIDKeyboardUsageCode")))
            let buttonState = try runtime.resolveAndWait(.swift(.type("CoreDevice.HIDButtonState")))
            let make = try code.resolveAndWait(.swift(.initializer("init(rawValue:)", as: ((UInt16) -> NativeSwiftValue).self)))
            let send = try implementation.type.resolveAndWait(.swift(.method("CoreDevice.HIDKeyboard.send(key:state:)",
                as: ((NativeSwiftValue, NativeSwiftValue) throws -> Void).self)))
            try unsafe send.unsafeInvoke(on: implementation, make.unsafeInvoke(usage), buttonState.makeEnumCase(named: state.rawValue))
        case .button(let page, let usage, let state):
            let implementation = try await implementation(.button, named: "ButtonHIDCapability")
            let buttonState = try runtime.resolveAndWait(.swift(.type("CoreDevice.HIDButtonState")))
            let send = try implementation.type.resolveAndWait(.swift(.method("CoreDevice.HIDButton.sendCustomButton(usagePage:usageCode:state:)",
                as: ((Int, Int, NativeSwiftValue) throws -> Void).self)))
            try unsafe send.unsafeInvoke(on: implementation, page, usage, buttonState.makeEnumCase(named: state.rawValue))
        case .pointer(let point):
            guard displayUniqueID == nil else { throw CLIError.unavailable("remote-display-input", "This display has no pointer connection.") }
            let implementation = try await implementation(.pointer, named: "PointerHIDCapability")
            let send = try implementation.type.resolveAndWait(.swift(.method("CoreDevice.HIDPointer.send(movedTo:)",
                as: ((CGPoint) async throws -> Void).self)))
            try await unsafe send.unsafeInvoke(on: implementation, point)
        case .pointerButton(let button, let phase, let clicks, let point):
            guard displayUniqueID == nil else { throw CLIError.unavailable("remote-display-input", "This display has no pointer connection.") }
            let implementation = try await implementation(.pointer, named: "PointerHIDCapability")
            let pointerPhase = try runtime.resolveAndWait(.swift(.type("CoreDevice.HIDPointerButtonPhase")))
            let send = try implementation.type.resolveAndWait(.swift(.method("CoreDevice.HIDPointer.send(button:phase:clicks:at:)",
                as: ((Int, NativeSwiftValue, Int, CGPoint) async throws -> Void).self)))
            try await unsafe send.unsafeInvoke(on: implementation, button, pointerPhase.makeEnumCase(named: phase.rawValue), clicks, point)
        case .touch(let point, let second, let phase, let edge):
            if displayUniqueID != nil {
                guard try remote.supports(Self.universalHIDFeature) else {
                    throw CLIError.unavailable("remote-input-capability", "The device no longer exposes the display touchscreen service.")
                }
                if displayInputNeedsReconnect, let identifier = displayIdentifier {
                    try await displayInput?.stop()
                    displayInput = nil
                    try await connectDisplay(identifier: identifier)
                }
                guard let displayInput else { throw CLIError.unavailable("remote-display-input", "The display touchscreen has not connected.") }
                try displayInput.send(point, second: second, phase: phase, edge: edge)
                return
            }
            let implementation = try await implementation(.digitizer, named: "DigitizerHIDCapability")
            let eventType = try runtime.resolveAndWait(.swift(.type("CoreDevice.DigitizerEventType")))
            let nativeEdge = try runtime.resolveAndWait(.swift(.type("CoreDevice.DigitizerEdge")))
            let target = try runtime.resolveAndWait(.swift(.type("CoreDevice.DigitizerTarget")))
            let send = try implementation.type.resolveAndWait(.swift(.method(
                "(extension in CoreDevice):CoreDevice.HIDDigitizer.send(pointOne:pointTwo:eventType:edge:target:)",
                as: ((CGPoint, CGPoint?, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue) throws -> Void).self)))
            let event = switch phase { case .began: "start"; case .moved: "position"; case .ended: "end" }
            try unsafe send.unsafeInvoke(on: implementation, point, second, eventType.makeEnumCase(named: event),
                                         nativeEdge.makeEnumCase(named: edge.rawValue), target.makeEnumCase(named: "mainScreen"))
        }
    }

}

struct RemoteScreenPressedInputs {
    struct Button: Hashable { let page: Int; let usage: Int }
    var keys: Set<UInt16> = []
    var buttons: Set<Button> = []
    var pointerButtons: [Int: CGPoint] = [:]
    var touch: (CGPoint, CGPoint?, RemoteDeviceTouchEdge)?

    mutating func record(_ input: RemoteScreenInput) {
        switch input {
        case .key(let usage, let state):
            if state == .down { keys.insert(usage) } else { keys.remove(usage) }
        case .button(let page, let usage, let state):
            let button = Button(page: page, usage: usage)
            if state == .down { buttons.insert(button) } else { buttons.remove(button) }
        case .pointerButton(let button, let phase, _, let point):
            if phase == .up { pointerButtons.removeValue(forKey: button) }
            else { pointerButtons[button] = point }
        case .touch(let point, let second, let phase, let edge):
            touch = phase == .ended ? nil : (point, second, edge)
        case .pointer: break
        }
    }

    mutating func discard(for kinds: Set<RemoteDeviceInputKind>) {
        if kinds.contains(.keyboard) { keys.removeAll() }
        if kinds.contains(.button) { buttons.removeAll() }
        if kinds.contains(.pointer) { pointerButtons.removeAll() }
        if kinds.contains(.digitizer) { touch = nil }
    }
}

private extension RemoteScreenInput {
    var kind: RemoteDeviceInputKind {
        switch self {
        case .key: .keyboard
        case .button: .button
        case .pointer, .pointerButton: .pointer
        case .touch: .digitizer
        }
    }
}

public enum DevicePosture: String, CaseIterable, Sendable {
    case closed, partiallyOpen, open

    public var title: String {
        switch self {
        case .closed: "Closed"
        case .partiallyOpen: "Partially Open"
        case .open: "Open"
        }
    }

    var degrees: Double {
        switch self {
        case .closed: 0
        case .partiallyOpen: 130
        case .open: 180
        }
    }

    static func confirmed(angle: Double?) -> Self? {
        guard let angle, angle.isFinite else { return nil }
        if angle < 15 { return .closed }
        if angle > 175 { return .open }
        return .partiallyOpen
    }
}

@MainActor
protocol DevicePostureTransport: AnyObject {
    func observe(_ update: @escaping @MainActor (Double?) -> Void) async throws
    func send(_ posture: DevicePosture) async throws
}

/// A button request never becomes the selected posture until hinge feedback confirms it.
@Observable @MainActor
public final class DevicePostureModel {
    public enum State: Equatable, Sendable { case idle, connecting, connected, unsupported, stopped, failed }

    public let deviceID: DeviceInventoryID
    public private(set) var state = State.idle
    public private(set) var angle: Double?
    public var confirmedPosture: DevicePosture? { DevicePosture.confirmed(angle: angle) }
    public private(set) var isSending = false
    public private(set) var isSupported = false
    public private(set) var lastError: (any Error)?
    public var canSelect: Bool { state == .connected && !isSending }

    public static func canInspect(capabilities: Set<String>) -> Bool { DevicePosturePayload.features.isSubset(of: capabilities) }
    @ObservationIgnored private let makeTransport: @MainActor (DeviceInventoryID) async throws -> (any DevicePostureTransport)?
    @ObservationIgnored private var transport: (any DevicePostureTransport)?
    @ObservationIgnored private var starting: Task<Void, any Error>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var command: Task<Void, any Error>?
    @ObservationIgnored private var stopping: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    public convenience init(deviceID: DeviceInventoryID) {
        self.init(deviceID: deviceID, makeTransport: NativeDevicePostureTransport.make)
    }

    init(deviceID: DeviceInventoryID,
         makeTransport: @escaping @MainActor (DeviceInventoryID) async throws -> (any DevicePostureTransport)?) {
        self.deviceID = deviceID
        self.makeTransport = makeTransport
    }

    isolated deinit { starting?.cancel(); observation?.cancel(); command?.cancel() }

    public func start() async throws {
        if let stopping { await stopping.value }
        if let starting { try await starting.value; return }
        guard state != .connected else { return }
        if transport != nil { await stop() }
        generation += 1
        let token = generation
        state = .connecting
        angle = nil
        lastError = nil
        let task = Task { [weak self, makeTransport, deviceID] in
            let transport = try await makeTransport(deviceID)
            try Task.checkCancellation()
            guard let self, self.generation == token else { throw CancellationError() }
            guard let transport else { self.state = .unsupported; return }
            self.transport = transport
            self.isSupported = true
            self.state = .connected
            self.observation = Task { [weak self, transport] in
                do {
                    try await transport.observe { [weak self] angle in
                        guard let self, self.generation == token, !Task.isCancelled else { return }
                        self.angle = angle
                    }
                    if !Task.isCancelled {
                        self?.observationFailed(CLIError.unavailable("device-posture-observation", "The device's hinge observation ended."), generation: token)
                    }
                } catch {
                    if !Task.isCancelled { self?.observationFailed(error, generation: token) }
                }
            }
        }
        starting = task
        defer { if generation == token { starting = nil } }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            if generation == token {
                state = error is CancellationError ? .stopped : .failed
                lastError = error is CancellationError ? nil : error
            }
            throw error
        }
    }

    public func select(_ posture: DevicePosture) async throws {
        guard canSelect, let transport else {
            throw CLIError.unavailable("device-posture-unavailable", "The device's posture controls are unavailable.")
        }
        let token = generation
        isSending = true
        lastError = nil
        let task = Task { try await transport.send(posture) }
        command = task
        defer {
            if generation == token { command = nil; isSending = false }
        }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
        } catch {
            if generation == token, !(error is CancellationError) { lastError = error }
            throw error
        }
    }

    public func stop() async {
        if let stopping { await stopping.value; return }
        generation += 1
        let starting = self.starting, observation = self.observation, command = self.command
        self.starting = nil
        self.observation = nil
        self.command = nil
        state = .stopped
        angle = nil
        starting?.cancel()
        observation?.cancel()
        command?.cancel()
        let task = Task {
            _ = await starting?.result
            await observation?.value
            _ = await command?.result
        }
        stopping = task
        await task.value
        transport = nil
        isSending = false
        stopping = nil
    }

    private func observationFailed(_ error: any Error, generation token: Int) {
        guard generation == token else { return }
        state = .failed
        angle = nil
        lastError = error
        command?.cancel()
    }
}

enum DevicePosturePayload {
    static let features: Set<String> = ["com.apple.coredevice.feature.remote.hid.vendordefined",
        "com.apple.coredevice.feature.monitormotion", "com.apple.coredevice.feature.remote.universalhidservice"]

    static func supports(hardwareModel: String?, features: Set<String>) -> Bool {
        ["v68", "v68ap", "v68dev"].contains(hardwareModel?.lowercased() ?? "") && Self.features.isSubset(of: features)
    }

    static func serialize(_ posture: DevicePosture) throws -> Data {
        let dictionary: [String: Any] = ["provider": "com.apple.Virtualization.VirtualMachines",
            "source": "hinge-slider-control", "type": "range", "value": posture.degrees]
        guard let data = IOCFSerialize(dictionary as CFDictionary, CFOptionFlags(kIOCFSerializeToBinary)) else {
            throw CLIError.io("device-posture-payload", "The hinge command could not be serialized.")
        }
        return data as Data
    }
}

@MainActor
private final class NativeDevicePostureTransport: DevicePostureTransport {
    private let remote: CoreDeviceRemoteScreenDevice
    private let config: NativeSwiftValue
    private let monitor: @MainActor (NativeSwiftValue) async throws -> NativeSwiftValue
    private let prepareVendorSend: @MainActor (NativeSwiftValue) async throws -> (@MainActor (Data) throws -> Void)
    private let isValid: NativeSwiftMethod<() -> Bool>
    private let readAngle: NativeSwiftMethod<() -> Measurement<UnitAngle>>

    static func make(_ identifier: DeviceInventoryID) async throws -> (any DevicePostureTransport)? {
        let commandID: String
        switch identifier {
        case .coreDevice(let id): commandID = id
        case .simulator(let udid, nil):
            guard let id = try await CoreDeviceRemoteScreenDevice.simulatorIdentifier(udid: udid) else { return nil }
            commandID = id
        case .simulator(_, .some):
            // DeviceInfo's UDID cannot distinguish duplicate UDIDs in different device sets.
            return nil
        }
        let remote = try await CoreDeviceRemoteScreenDevice(identifier: commandID)
        let deviceInfo = try await remote.type.resolve(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
        let info = try unsafe deviceInfo.unsafeInvoke(on: remote.object)
        let hardware = try await info.type.resolve(.swift(.getter("hardwareModel", as: (() -> String?).self)))
        let model = try unsafe hardware.unsafeInvoke(on: info)
        let features = try Set(DevicePosturePayload.features.filter { try remote.supports($0) })
        guard DevicePosturePayload.supports(hardwareModel: model, features: features) else { return nil }
        let implementation = try await remote.implementation(capability: "MonitorMotionCapability", feature: "com.apple.coredevice.feature.monitormotion")
        let errorType = try await remote.runtime.resolve(.swift(.type("CoreDevice.CoreDeviceError")))
        let sampleError = try await errorType.resolve(.swift(.staticGetter("ioError", as: (() -> NativeSwiftValue).self,
            valueABIs: [errorType: try .opaque(named: errorType.name)])))
        let owner = try unsafe sampleError.unsafeInvoke()
        // Open the framework's actual Error representation instead of mirroring its resilient layout.
        guard let failure = try owner.withCopy({ $0 as? any Error }) else {
            throw CLIError.unavailable("device-posture-error-type", "The native posture error type could not be resolved.")
        }
        return try await make(remote: remote, implementation: implementation, failure: failure)
    }

    private static func make<Failure: Error>(remote: CoreDeviceRemoteScreenDevice, implementation: NativeSwiftValue,
                                            failure: Failure) async throws -> (any DevicePostureTransport)? {
        let getMotion = try await implementation.type.resolve(.swift(.method("CoreDevice.MonitorMotionProtocol.motionManager()",
            as: (() async throws(Failure) -> NativeSwiftValue).self)))
        let motion = try await unsafe getMotion.unsafeInvoke(on: implementation)
        let supportsHinge = try await motion.type.resolve(.swift(.getter("supportsHingeAngle", as: (() -> Bool).self)))
        guard try unsafe supportsHinge.unsafeInvoke(on: motion) else { return nil }
        return try await NativeDevicePostureTransport(remote: remote, motion: motion, failure: failure)
    }

    private init<Failure: Error>(remote: CoreDeviceRemoteScreenDevice, motion: NativeSwiftValue, failure: Failure) async throws {
        self.remote = remote
        let runtime = remote.runtime
        let snapshot = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.DeviceHingeAngleSnapshot")))
        let configuration = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.HingeAngleStreamConfig")))
        let array = try await runtime.resolve(.swift(.type("Swift.Array", genericArguments: [.type(snapshot)])))
        let arguments: [NativeSwiftGenericArgument] = [.type(array), .type((any Error).self)]
        let sequence = try await runtime.resolve(.swift(.type("Swift.AsyncThrowingStream", genericArguments: arguments)))
        let measurement = try await runtime.resolve(.swift(.type("Foundation.Measurement", genericArguments: [.type(UnitAngle.self)])))
        let abis = try Dictionary(uniqueKeysWithValues: [snapshot, configuration, sequence, measurement]
            .map { ($0, try NativeType.opaque(named: $0.name)) })
        let makeConfig = try await configuration.resolve(.swift(.initializer("init(changeThreshold:updateInterval:)",
            as: ((Measurement<UnitAngle>, Duration) -> NativeSwiftValue).self, valueABIs: abis)))
        config = try unsafe makeConfig.unsafeInvoke(Measurement(value: 0.01, unit: .degrees), .milliseconds(50))
        let monitor = try await motion.type.resolve(.swift(.method("monitorHingeAngle(config:)",
            as: ((NativeSwiftValue) async throws(Failure) -> NativeSwiftValue).self, valueABIs: abis)))
        self.monitor = { config in try await unsafe monitor.unsafeInvoke(on: motion, config) }
        let data = try await runtime.resolve(.swift(.type("Foundation.Data")))
        // Data is @frozen; Device Hub passes its two words in integer registers.
        let dataABI = try NativeType.structure(named: data.name, fields: [.uint64, .uint64])
        prepareVendorSend = { implementation in
            let send = try await implementation.type.resolve(.swift(.method("CoreDevice.HIDVendorDefined.send(usagePage:usage:version:data:)",
                as: ((UInt16, UInt16, UInt32, Data) throws(Failure) -> Void).self, valueABIs: [data: dataABI])))
            return { data in try unsafe send.unsafeInvoke(on: implementation, 0xFF61, 0x5B, 0, data) }
        }
        isValid = try await snapshot.resolve(.swift(.getter("isAngleValid", as: (() -> Bool).self, valueABIs: abis)))
        readAngle = try await snapshot.resolve(.swift(.getter("angle", as: (() -> Measurement<UnitAngle>).self, valueABIs: abis)))
    }

    func observe(_ update: @escaping @MainActor (Double?) -> Void) async throws {
        let owner = try await monitor(config)
        defer { withExtendedLifetime(owner) {} }
        guard let sequence = try owner.withCopy({ $0 as? any AsyncSequence }) else {
            throw CLIError.unavailable("device-posture-observation", "The device's hinge-angle changes could not be observed.")
        }
        try await observe(sequence, update: update)
    }

    private func observe<S: AsyncSequence>(_ sequence: S, update: @MainActor (Double?) -> Void) async throws {
        var iterator = sequence.makeAsyncIterator()
        while let batch = try await iterator.next(isolation: #isolation) {
            try Task.checkCancellation()
            guard let snapshots = batch as? [Any] else {
                throw CLIError.io("device-posture-snapshot", "The device supplied an unexpected hinge-angle snapshot.")
            }
            guard let snapshot = snapshots.last, try unsafe isValid.unsafeInvoke(on: snapshot) else { update(nil); continue }
            let angle = try unsafe readAngle.unsafeInvoke(on: snapshot).converted(to: .degrees).value
            update(angle.isFinite ? angle : nil)
        }
    }

    func send(_ posture: DevicePosture) async throws {
        try validateCapabilities()
        let implementation = try await remote.implementation(capability: "VendorDefinedHIDCapability",
            feature: "com.apple.coredevice.feature.remote.hid.vendordefined")
        let send = try await prepareVendorSend(implementation)
        try Task.checkCancellation()
        try validateCapabilities()
        try send(DevicePosturePayload.serialize(posture))
    }

    private func validateCapabilities() throws {
        guard try DevicePosturePayload.features.allSatisfy({ try remote.supports($0) }) else {
            throw CLIError.unavailable("device-posture-capability", "The device no longer exposes posture controls.")
        }
    }
}
