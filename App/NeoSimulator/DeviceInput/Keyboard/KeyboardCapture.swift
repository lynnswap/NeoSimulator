import AppKit
import Carbon
import Observation

/// Captures shortcuts only while its displayed device owns focus. Escape remains a way out.
@Observable @MainActor
final class KeyboardCapture {
    private(set) var isCapturing = false
    @ObservationIgnored var failure: (any Error) -> Void = { _ in }
    @ObservationIgnored var didStop: () -> Void = {}
    private let tap: any KeyboardEventTap
    private let isEligible: () -> Bool
    private let forward: (NSEvent) -> Void
    private let releaseModifiers: ([NSEvent]) -> Void
    private let waitForEscapeHold: () async throws -> Void
    private let initialModifierFlags: () -> NSEvent.ModifierFlags
    @ObservationIgnored private var pressed: [UInt16: NSEvent] = [:]
    @ObservationIgnored private var modifiers: [UInt16: NSEvent] = [:]
    @ObservationIgnored private var escapeHold: Task<Void, Never>?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    private static let modifierKeys: [(Int, NSEvent.ModifierFlags)] = [
        (kVK_Command, .command), (kVK_RightCommand, .command),
        (kVK_Shift, .shift), (kVK_RightShift, .shift),
        (kVK_Option, .option), (kVK_RightOption, .option),
        (kVK_Control, .control), (kVK_RightControl, .control), (kVK_Function, .function),
    ]

    init(tap: any KeyboardEventTap = SystemKeyboardEventTap(), isEligible: @escaping () -> Bool,
         forward: @escaping (NSEvent) -> Void, releaseModifiers: @escaping ([NSEvent]) -> Void,
         initialModifierFlags: @escaping () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags },
         waitForEscapeHold: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(1)) }) {
        self.tap = tap
        self.isEligible = isEligible
        self.forward = forward
        self.releaseModifiers = releaseModifiers
        self.waitForEscapeHold = waitForEscapeHold
        self.initialModifierFlags = initialModifierFlags
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willResignActiveNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { _ = self?.stop() } })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isCapturing, !self.isEligible() else { return }
                    self.stop()
                }
            })
    }

    func start() throws {
        guard !isCapturing else { return }
        guard isEligible() else { throw HostError.operation("Focus the device screen before capturing its keyboard.") }
        try tap.start { [weak self] type, event in self?.receive(type, event) ?? false }
        isCapturing = true
        // Focus may already have sent modifiers held before the tap started.
        let flags = initialModifierFlags()
        for (code, flag) in Self.modifierKeys where flags.contains(flag) {
            if let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(code)) {
                modifiers[UInt16(code)] = event
            }
        }
    }

    @discardableResult
    func stop() -> Bool {
        guard isCapturing else { return false }
        isCapturing = false
        tap.stop()
        escapeHold?.cancel()
        escapeHold = nil
        let keys = pressed.values
        pressed.removeAll()
        for event in keys {
            if let up = NSEvent.keyEvent(with: .keyUp, location: event.locationInWindow, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: event.windowNumber, context: nil,
                characters: event.characters ?? "", charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: false, keyCode: event.keyCode) { forward(up) }
        }
        let releases = modifiers.values.compactMap { event in
            NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: event.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: event.keyCode)
        }
        modifiers.removeAll()
        releaseModifiers(releases)
        didStop()
        return true
    }

    private func receive(_ type: CGEventType, _ cgEvent: CGEvent) -> Bool {
        guard isCapturing else { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stop()
            failure(HostError.operation("Keyboard capture stopped because macOS disabled its event tap. Try Capture Keyboard again."))
            return false
        }
        guard isEligible() else { stop(); return false }
        guard let event = NSEvent(cgEvent: cgEvent) else { return false }
        switch event.type {
        case .keyDown:
            pressed[event.keyCode] = event
            if event.keyCode == UInt16(kVK_Escape), !event.isARepeat, escapeHold == nil {
                escapeHold = Task { [weak self, waitForEscapeHold] in
                    do {
                        try await waitForEscapeHold()
                        try Task.checkCancellation()
                        self?.stop()
                    } catch is CancellationError {} catch { self?.stop(); self?.failure(error) }
                }
            }
        case .keyUp:
            pressed.removeValue(forKey: event.keyCode)
            if event.keyCode == UInt16(kVK_Escape) { escapeHold?.cancel(); escapeHold = nil }
        case .flagsChanged:
            let flag = Self.modifierKeys.first { $0.0 == Int(event.keyCode) }?.1
            if let flag, event.modifierFlags.contains(flag) { modifiers[event.keyCode] = event }
            else { modifiers.removeValue(forKey: event.keyCode) }
        default: return false
        }
        forward(event)
        return true
    }

    isolated deinit {
        stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
