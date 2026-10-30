import ABIBridge
import AppKit
import IOKit
import Observation
import os

@MainActor
final class CoreDeviceScreenInput {
    private let remote: CoreDeviceRemoteScreenDevice
    private let displayUniqueID: String?
    private var displayInput: CoreDeviceHIDService?
    private var digitizerReports: CoreDeviceDigitizerReports?
    private var displayIdentifier: UInt32?
    private var displayInputNeedsReconnect = false
    private let gestures: NativeTrackpadGestures
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
        .gesture: universalHIDFeature,
    ]
    static let universalHIDFeature = "com.apple.coredevice.feature.remote.universalhidservice"

    init(remote: CoreDeviceRemoteScreenDevice, displayUniqueID: String? = nil) {
        self.remote = remote
        self.displayUniqueID = displayUniqueID
        gestures = NativeTrackpadGestures { try await CoreDeviceTrackpadTransport(remote: remote) }
    }

    func connectDisplay(identifier: UInt32) async throws {
        guard let displayUniqueID else { return }
        let reports = try digitizerReports ?? CoreDeviceDigitizerReports(runtime: remote.runtime)
        digitizerReports = reports
        let descriptor = try await CoreDeviceHIDService.touchscreenDescriptor(displayID: identifier, uniqueID: displayUniqueID,
                                                                             runtime: remote.runtime)
        displayInput = try await CoreDeviceHIDService.connect(remote: remote, descriptor: descriptor)
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
        if kinds.contains(.gesture) { gestures.discardServices() }
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
        if pressed.pinching {
            let generation = generations[.gesture, default: 0]
            do { try gestures.resetGestures(); pressed.pinching = false }
            catch { if generations[.gesture, default: 0] == generation { failures.append(error.localizedDescription) } }
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
            do { try await displayInput.stop() }
            catch { failure = failure.map { RemoteDeviceScreenSession.combining($0, cleanup: error) } ?? error }
            if displayInput.isRemoved {
                pressed.discard(for: [.digitizer])
                self.displayInput = nil
            }
        }
        do { try await gestures.stop() }
        catch { failure = failure.map { RemoteDeviceScreenSession.combining($0, cleanup: error) } ?? error }
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
                guard let displayInput, let digitizerReports else {
                    throw CLIError.unavailable("remote-display-input", "The display touchscreen has not connected.")
                }
                try displayInput.send(digitizerReports.make(point: point, second: second, phase: phase, edge: edge))
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
        case .pinch(let event):
            guard try remote.supports(Self.universalHIDFeature) else {
                throw CLIError.unavailable("remote-input-capability", "The device no longer exposes trackpad gestures.")
            }
            try await gestures.send(event)
        }
    }
}

/// Sends the Mac trackpads' gestures over a screen to guest services that carry each trackpad's own HID properties, as
/// Device Hub does while clicks on the screen become touches. A gesture reaches the service created for the Mac HID
/// service that sent it, so one that no Mac HID service sent, such as a synthesized gesture, reaches none.
@MainActor
final class NativeTrackpadGestures {
    /// A trackpad's guest service, with the observer that keeps that trackpad's gesture state.
    typealias Service = (service: CoreDeviceHIDService, translator: CoreDeviceEventReports.Translator)

    private let makeTransport: @MainActor () async throws -> any NativeTrackpadTransport
    private var transport: (any NativeTrackpadTransport)?
    /// Guest services by the registry ID of the Mac HID service they carry.
    private var services: [UInt64: Service] = [:]
    /// Senders that are not Mac HID services, such as other processes' event sources.
    private var unknownSenders: Set<UInt64> = []
    /// Changes when the device invalidates the services, so that one created meanwhile is not used.
    private var generation = 0
    private var isStopped = false

    /// `transport` is prepared with the first gesture.
    init(transport: @escaping @MainActor () async throws -> any NativeTrackpadTransport) {
        makeTransport = transport
    }

    /// Sends a gesture's reports to its trackpad's service, which the trackpad's first gesture creates.
    func send(_ event: NSEvent) async throws {
        guard !isStopped else { throw CLIError.unavailable("remote-gesture-input", "The device's gesture input has stopped.") }
        let transport = if let transport { transport } else { try await makeTransport() }
        self.transport = transport
        let sender = try transport.sender(of: event)
        // Device Hub drops a gesture that no Mac HID service sent rather than giving it a trackpad the Mac does not have.
        guard sender != 0, !unknownSenders.contains(sender) else { return }
        let service: Service
        if let existing = services[sender] { service = existing } else {
            let generation = self.generation
            guard let created = try await transport.connect(sender: sender) else {
                unknownSenders.insert(sender)
                return
            }
            if isStopped {
                // Stopping removed the services it found, so this one is removed here; the next stop retries a failure.
                do { try await created.service.stop() } catch { services[sender] = created; throw error }
                throw CLIError.unavailable("remote-gesture-input", "The device's gesture input stopped while preparing the input.")
            }
            // The device invalidated its services while this one was created.
            guard generation == self.generation else {
                throw CLIError.unavailable("remote-input-capability", "The device's input service changed while preparing the input.")
            }
            services[sender] = created
            service = created
        }
        let reports = try service.translator.reports(for: event)
        // Without a report, the device would not start the pinch or would keep one the trackpad already ended.
        guard !reports.isEmpty else {
            throw CLIError.unavailable("remote-gesture-report", "UniversalHIDKit did not translate the gesture.")
        }
        for report in reports { try service.service.send(report) }
    }

    /// Ends the gestures each service holds on the device, as Device Hub's HID reset does for each of its services.
    func resetGestures() throws {
        var failures: [String] = []
        for (_, service) in services.sorted(by: { $0.key < $1.key }) {
            do { try service.service.resetGestures() } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { throw CLIError.io("remote-gesture-reset", failures.joined(separator: "\n")) }
    }

    /// Retires the services, which the device invalidates with its gesture capability, without claiming they ended
    /// their gestures. A trackpad's next gesture creates its service again.
    func discardServices() {
        services.removeAll()
        generation += 1
    }

    /// Removes the services; later gestures create none. A service that could not be removed is retried by the next stop.
    func stop() async throws {
        isStopped = true
        let stopping = services
        services = [:]
        var failures: [String] = []
        for (sender, service) in stopping.sorted(by: { $0.key < $1.key }) {
            do { try await service.service.stop() } catch { failures.append(error.localizedDescription) }
            if !service.service.isRemoved { services[sender] = service }
        }
        if !failures.isEmpty { throw CLIError.io("remote-gesture-removal", failures.joined(separator: "\n")) }
    }
}

/// The Mac HID services that send trackpad gestures and the guest services that receive them.
@MainActor
protocol NativeTrackpadTransport: AnyObject {
    /// The registry ID of the Mac HID service that produced the event, or 0 for a synthesized event.
    func sender(of event: NSEvent) throws -> UInt64
    /// Creates a guest service described by the Mac HID service `sender`, or returns nil when no such service exists.
    func connect(sender: UInt64) async throws -> NativeTrackpadGestures.Service?
}

@MainActor
final class CoreDeviceTrackpadTransport: NativeTrackpadTransport {
    private static let logger = Logger(subsystem: "dev.lynnswap.NeoSimulator", category: "Trackpad")
    private let remote: CoreDeviceRemoteScreenDevice
    private let bindings: NativeTrackpadBindings

    init(remote: CoreDeviceRemoteScreenDevice) async throws {
        self.remote = remote
        bindings = try await NativeTrackpadBindings(runtime: remote.runtime)
    }

    func sender(of event: NSEvent) throws -> UInt64 { try bindings.lookup.sender(of: event) }

    func connect(sender: UInt64) async throws -> NativeTrackpadGestures.Service? {
        let source = "Mac HID service 0x\(String(sender, radix: 16))"
        guard let properties = try bindings.lookup.properties(ofHIDService: sender) else {
            Self.logger.error("The gestures of \(source, privacy: .public) reach no guest service: the Mac has no such HID service")
            return nil
        }
        let translator = try bindings.makeTranslator()
        let service = try await CoreDeviceHIDService.connect(remote: remote,
            descriptor: bindings.descriptor(serviceID: sender, properties: properties))
        Self.logger.log("Created the guest trackpad service for \(source, privacy: .public)")
        return (service, translator)
    }
}

/// Describes a Mac trackpad's guest service and translates the trackpad's gestures, as Device Hub does.
@MainActor
struct NativeTrackpadBindings {
    /// The Mac HID services that gestures come from.
    let lookup: MacHIDServiceLookup
    private let events: CoreDeviceEventReports
    private let adjust: (NativeSwiftValue) throws -> Void

    init(runtime: ABIRuntime) async throws {
        lookup = try await MacHIDServiceLookup(runtime: runtime)
        // UniversalHIDKit's magnify translator belongs to the digitizer event type.
        events = try await CoreDeviceEventReports(runtime: runtime, eventType: "digitizer")
        let descriptorType = try await runtime.resolve(.swift(.type("CoreDevice.HIDServiceDescriptor")))
        let abi = try NativeType.opaque(named: descriptorType.name)
        let abis = [descriptorType: abi]
        let isPointer = try await descriptorType.resolve(.swift(.getter("isBackBoardPointer", as: (() -> Bool).self,
            valueABIs: abis, receiverABI: abi)))
        let routeEvents = try await descriptorType.resolve(.swift(.setter("routeEventsIgnoringSystemShellPolicy",
            as: ((Bool?) -> Void).self, valueABIs: abis, receiverABI: abi)))
        let suppressPointer = try await descriptorType.resolve(.swift(.setter("suppressMousePointer",
            as: ((Bool?) -> Void).self, valueABIs: abis, receiverABI: abi)))
        // Device Hub adjusts each pointer service it creates. While clicks touch the screen, as they do here, it hides
        // the service's pointer; the service's events also bypass the guest's system shell policy.
        adjust = { descriptor in
            guard try unsafe isPointer.unsafeInvoke(on: descriptor) else { return }
            try unsafe routeEvents.unsafeInvoke(on: descriptor, true)
            try unsafe suppressPointer.unsafeInvoke(on: descriptor, true)
        }
    }

    /// An observer with one trackpad's gesture state.
    func makeTranslator() throws -> CoreDeviceEventReports.Translator { try events.makeTranslator() }

    /// The descriptor of a guest service that carries a Mac trackpad's `properties` under its registry ID `serviceID`.
    func descriptor(serviceID: UInt64, properties: [String: Any]) throws -> NativeSwiftValue {
        let descriptor = try lookup.descriptor(serviceID: serviceID, properties: properties)
        try adjust(descriptor)
        return descriptor
    }
}

struct RemoteScreenPressedInputs {
    struct Button: Hashable { let page: Int; let usage: Int }
    var keys: Set<UInt16> = []
    var buttons: Set<Button> = []
    var pointerButtons: [Int: CGPoint] = [:]
    var touch: (CGPoint, CGPoint?, RemoteDeviceTouchEdge)?
    /// Whether a pinch the screen sent has begun and has not ended or been cancelled.
    var pinching = false

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
        case .pinch(let event):
            pinching = event.phase.isDisjoint(with: [.ended, .cancelled])
        case .pointer: break
        }
    }

    mutating func discard(for kinds: Set<RemoteDeviceInputKind>) {
        if kinds.contains(.keyboard) { keys.removeAll() }
        if kinds.contains(.button) { buttons.removeAll() }
        if kinds.contains(.pointer) { pointerButtons.removeAll() }
        if kinds.contains(.digitizer) { touch = nil }
        if kinds.contains(.gesture) { pinching = false }
    }
}

private extension RemoteScreenInput {
    var kind: RemoteDeviceInputKind {
        switch self {
        case .key: .keyboard
        case .button: .button
        case .pointer, .pointerButton: .pointer
        case .touch: .digitizer
        case .pinch: .gesture
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
