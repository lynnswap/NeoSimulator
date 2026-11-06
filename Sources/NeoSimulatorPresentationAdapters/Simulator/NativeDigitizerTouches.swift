import ABIBridge
import AppKit
import NeoSimulatorDeviceIO
import NeoSimulatorKit

/// A touch of a SimulatorKit digitizer, as its delegate receives it.
package struct NativeDigitizerTouch: Equatable {
    package var point: CGPoint
    package var secondPoint: CGPoint?
    package var phase: RemoteDeviceTouchPhase
    package var edge: RemoteDeviceTouchEdge
}

/// Gives a SimulatorKit digitizer a delegate whose methods are this host's callbacks, until `restore()`. The delegate
/// sends the touches the digitizer interprets, after its Option two-finger, pinned-finger, and edge handling, and passes
/// the digitizer's other callbacks, such as its first-responder requests, to the delegate it replaces.
@MainActor
package final class NativeDigitizerTouches {
    private weak var digitizer: NSView?
    private let interface: SimulatorTouchInterface
    private let send: (NativeDigitizerTouch) -> Void
    /// The digitizer's own delegate, which `restore()` gives back.
    private let original: NativeSwiftValue?
    private let forwarding: NativeDigitizerForwarding?
    /// The delegate that `install()` gives the digitizer.
    private var prepared: NativeSwiftValue?
    /// The digitizer keeps its delegate weakly, so this keeps the replacement for as long as the digitizer has it.
    private var replacement: NativeSwiftValue?

    /// Prepares the replacement. The digitizer keeps its own delegate until `install()`.
    package init(digitizer: NSView, interface: SimulatorTouchInterface, send: @escaping (NativeDigitizerTouch) -> Void) async throws {
        self.digitizer = digitizer
        self.interface = interface
        self.send = send
        original = try unsafe interface.delegate.unsafeInvoke(on: digitizer)
        if let original {
            forwarding = try await NativeDigitizerForwarding(delegate: original, interface: interface)
        } else {
            forwarding = nil
        }
        prepared = try await makeDelegate()
    }

    /// Takes the digitizer's touches, without suspending, so that its caller decides the moment they change over.
    package func install() throws {
        guard let digitizer, let replacement = prepared else { return }
        // The setter consumes its value, so it takes a copy of the delegate that this owner keeps.
        try unsafe interface.setDelegate.unsafeInvoke(on: digitizer, replacement.copy())
        self.replacement = replacement
        prepared = nil
        // A screen whose digitizer did not keep the delegate would have no touches while its other input is native.
        guard try unsafe interface.delegate.unsafeInvoke(on: digitizer).map(Self.object) === Self.object(replacement) else {
            let failure = SimulatorError.unavailable("SimulatorKit's digitizer did not keep NeoSimulator's touch delegate.")
            do { try restore() } catch {
                throw SimulatorError.operation([failure.localizedDescription, error.localizedDescription].joined(separator: "\n"))
            }
            throw failure
        }
    }

    /// Gives the digitizer its own delegate back. After a failure, the digitizer and this owner keep the replacement.
    package func restore() throws {
        guard replacement != nil else { return }
        if let digitizer { try unsafe interface.setDelegate.unsafeInvoke(on: digitizer, original?.copy()) }
        replacement = nil
    }

    private func makeDelegate() async throws -> NativeSwiftValue {
        // SimDigitizerInputView, an NSView, calls its delegate on the main thread while it handles AppKit events, and
        // each callback reads its borrowed arguments before it returns, so the touches keep the events' order.
        try await ABIRuntime.shared.makeSwiftProtocolValue(SimulatorTouchInterface.delegateProtocol, methods: [
            try NativeSwiftProtocolMethod("simDigitizerInputView(_:touchEvent:)") {
                [weak self] (_: NativeSwiftBorrowedValue, event: NativeSwiftBorrowedValue) in
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated { self?.receive(event) }
            },
            try NativeSwiftProtocolMethod("simDigitizerInputView(_:wantsMouseMovedEvents:)") {
                [weak self] (view: NativeSwiftBorrowedValue, wants: Bool) in
                nonisolated(unsafe) let view = view
                MainActor.assumeIsolated { self?.forward("mouse-moved") { try $0.wantsMouseMovedEvents(view, wants) } }
            },
            try NativeSwiftProtocolMethod("simDigitizerInputView(_:wantsFirstResponder:)") {
                [weak self] (view: NativeSwiftBorrowedValue, wants: Bool) in
                nonisolated(unsafe) let view = view
                MainActor.assumeIsolated { self?.forward("first-responder") { try $0.wantsFirstResponder(view, wants) } }
            },
            try NativeSwiftProtocolMethod("simDigitizerInputView(_:pressureEvent:)") {
                [weak self] (view: NativeSwiftBorrowedValue, event: NativeSwiftBorrowedValue) in
                nonisolated(unsafe) let view = view
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated { self?.forward("pressure") { try $0.pressureEvent(view, event) } }
            },
            try NativeSwiftProtocolMethod("simDigitizerInputView(_:scrollEvent:)") {
                [weak self] (view: NativeSwiftBorrowedValue, event: NativeSwiftBorrowedValue) in
                nonisolated(unsafe) let view = view
                nonisolated(unsafe) let event = event
                MainActor.assumeIsolated { self?.forward("scroll") { try $0.scrollEvent(view, event) } }
            },
        ], valueABIs: interface.eventABIs)
    }

    private func receive(_ event: NativeSwiftBorrowedValue) {
        do { if let touch = try interface.touch(event) { send(touch) } } catch {
            hostLog("Could not read a touch of the screen: \(error.localizedDescription)")
        }
    }

    private func forward(_ callback: String, _ body: (NativeDigitizerForwarding) throws -> Void) {
        guard let forwarding else { return }
        do { try body(forwarding) } catch {
            hostLog("Could not pass the digitizer's \(callback) callback to its delegate: \(error.localizedDescription)")
        }
    }

    /// The object of a class-bound protocol existential, which identifies the delegate whatever its concrete type.
    private static func object(_ value: NativeSwiftValue) throws -> AnyObject {
        try value.withCopy { $0 as AnyObject }
    }
}

/// Calls a digitizer delegate's requirements other than its touch events, through the protocol's requirements, which
/// select the witnesses of the delegate's own conformance.
@MainActor
package final class NativeDigitizerForwarding {
    private let delegate: NativeSwiftValue
    private let mouseMoved: NativeSwiftMethod<(NativeSwiftBorrowedValue, Bool) -> Void>
    private let firstResponder: NativeSwiftMethod<(NativeSwiftBorrowedValue, Bool) -> Void>
    private let pressure: NativeSwiftMethod<(NativeSwiftBorrowedValue, NativeSwiftBorrowedValue) -> Void>
    private let scroll: NativeSwiftMethod<(NativeSwiftBorrowedValue, NativeSwiftBorrowedValue) -> Void>

    package init(delegate existential: NativeSwiftValue, interface: SimulatorTouchInterface) async throws {
        let delegate = try existential.copyUnderlyingValue()
        let name = SimulatorTouchInterface.delegateProtocol + ".simDigitizerInputView"
        mouseMoved = try await delegate.type.resolve(.swift(.method(name + "(_:wantsMouseMovedEvents:)",
            as: ((NativeSwiftBorrowedValue, Bool) -> Void).self)))
        firstResponder = try await delegate.type.resolve(.swift(.method(name + "(_:wantsFirstResponder:)",
            as: ((NativeSwiftBorrowedValue, Bool) -> Void).self)))
        pressure = try await delegate.type.resolve(.swift(.method(name + "(_:pressureEvent:)",
            as: ((NativeSwiftBorrowedValue, NativeSwiftBorrowedValue) -> Void).self, valueABIs: interface.eventABIs)))
        scroll = try await delegate.type.resolve(.swift(.method(name + "(_:scrollEvent:)",
            as: ((NativeSwiftBorrowedValue, NativeSwiftBorrowedValue) -> Void).self, valueABIs: interface.eventABIs)))
        self.delegate = delegate
    }

    package func wantsMouseMovedEvents(_ view: NativeSwiftBorrowedValue, _ wants: Bool) throws {
        try unsafe mouseMoved.unsafeInvoke(on: delegate, view, wants)
    }

    package func wantsFirstResponder(_ view: NativeSwiftBorrowedValue, _ wants: Bool) throws {
        try unsafe firstResponder.unsafeInvoke(on: delegate, view, wants)
    }

    package func pressureEvent(_ view: NativeSwiftBorrowedValue, _ event: NativeSwiftBorrowedValue) throws {
        try unsafe pressure.unsafeInvoke(on: delegate, view, event)
    }

    package func scrollEvent(_ view: NativeSwiftBorrowedValue, _ event: NativeSwiftBorrowedValue) throws {
        try unsafe scroll.unsafeInvoke(on: delegate, view, event)
    }
}
