import ABIBridge
import Foundation

@MainActor
final class CoreDeviceScreenInput {
    private let remote: CoreDeviceRemoteScreenDevice
    private var implementations: [RemoteDeviceInputKind: NativeSwiftValue] = [:]
    private var keys: Set<UInt16> = []
    private struct Button: Hashable { let page: Int; let usage: Int }
    private var buttons: Set<Button> = []
    private var pointerButtons: [Int: CGPoint] = [:]
    private var touch: (CGPoint, CGPoint?, RemoteDeviceTouchEdge)?

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
        try Task.checkCancellation()
        try await sendNative(input)
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

    func releaseInputs() async throws {
        var failures: [String] = []
        if let (point, second, edge) = touch {
            do { try await sendNative(.touch(point, second, .ended, edge)); touch = nil }
            catch { failures.append(error.localizedDescription) }
        }
        for (button, point) in pointerButtons.sorted(by: { $0.key < $1.key }) {
            do { try await sendNative(.pointerButton(button, .up, 1, point)); pointerButtons.removeValue(forKey: button) }
            catch { failures.append(error.localizedDescription) }
        }
        for key in keys.sorted() {
            do { try await sendNative(.key(key, .up)); keys.remove(key) }
            catch { failures.append(error.localizedDescription) }
        }
        for button in buttons.sorted(by: { ($0.page, $0.usage) < ($1.page, $1.usage) }) {
            do { try await sendNative(.button(button.page, button.usage, .up)); buttons.remove(button) }
            catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { throw CLIError.io("remote-input-release", failures.joined(separator: "\n")) }
        implementations.removeAll()
    }

    private func implementation(_ kind: RemoteDeviceInputKind, named capability: String) async throws -> NativeSwiftValue {
        let feature = Self.features[kind]!
        guard try remote.supports(feature) else {
            throw CLIError.unavailable("remote-input-capability", "The device no longer exposes the requested input operation.")
        }
        if let implementation = implementations[kind] { return implementation }
        let implementation = try await remote.implementation(capability: capability, feature: feature)
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
