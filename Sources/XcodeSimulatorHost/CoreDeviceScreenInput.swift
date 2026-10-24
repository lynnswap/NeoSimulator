import ABIBridge
import Foundation

@MainActor
final class CoreDeviceScreenInput {
    private let remote: CoreDeviceRemoteScreenDevice
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

    init(remote: CoreDeviceRemoteScreenDevice) { self.remote = remote }

    func capabilities() throws -> Set<RemoteDeviceInputKind> {
        Set(try Self.features.compactMap { try remote.supports($0.value) ? $0.key : nil })
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
            let code = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice.HIDKeyboardUsageCode")
            let buttonState = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice.HIDButtonState")
            let make = try code.resolveAndWait(.initializer("init(rawValue:)", as: ((UInt16) -> NativeSwiftValue).self))
            let send = try implementation.type.resolveAndWait(.method("CoreDevice.HIDKeyboard.send(key:state:)",
                as: ((NativeSwiftValue, NativeSwiftValue) throws -> Void).self))
            try unsafe send.unsafeInvoke(on: implementation, make.unsafeInvoke(usage), buttonState.makeEnumCase(named: state.rawValue))
        case .button(let page, let usage, let state):
            let implementation = try await implementation(.button, named: "ButtonHIDCapability")
            let buttonState = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice.HIDButtonState")
            let send = try implementation.type.resolveAndWait(.method("CoreDevice.HIDButton.sendCustomButton(usagePage:usageCode:state:)",
                as: ((Int, Int, NativeSwiftValue) throws -> Void).self))
            try unsafe send.unsafeInvoke(on: implementation, page, usage, buttonState.makeEnumCase(named: state.rawValue))
        case .pointer(let point):
            let implementation = try await implementation(.pointer, named: "PointerHIDCapability")
            let send = try implementation.type.resolveAndWait(.method("CoreDevice.HIDPointer.send(movedTo:)",
                as: ((CGPoint) async throws -> Void).self))
            try await unsafe send.unsafeInvoke(on: implementation, point)
        case .pointerButton(let button, let phase, let clicks, let point):
            let implementation = try await implementation(.pointer, named: "PointerHIDCapability")
            let pointerPhase = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice.HIDPointerButtonPhase")
            let send = try implementation.type.resolveAndWait(.method("CoreDevice.HIDPointer.send(button:phase:clicks:at:)",
                as: ((Int, NativeSwiftValue, Int, CGPoint) async throws -> Void).self))
            try await unsafe send.unsafeInvoke(on: implementation, button, pointerPhase.makeEnumCase(named: phase.rawValue), clicks, point)
        case .touch(let point, let second, let phase, let edge):
            let implementation = try await implementation(.digitizer, named: "DigitizerHIDCapability")
            let eventType = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice.DigitizerEventType")
            let nativeEdge = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice.DigitizerEdge")
            let target = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice.DigitizerTarget")
            let send = try implementation.type.resolveAndWait(.method(
                "(extension in CoreDevice):CoreDevice.HIDDigitizer.send(pointOne:pointTwo:eventType:edge:target:)",
                as: ((CGPoint, CGPoint?, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue) throws -> Void).self))
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
