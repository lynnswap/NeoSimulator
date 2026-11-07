import ABIBridge
import AppKit
import IOKit
import NeoSimulatorDeviceIO
import NeoSimulatorKit
import Observation
import os

@MainActor
package final class CoreDeviceScreenInput {
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

    package static let features: [RemoteDeviceInputKind: String] = [
        .keyboard: "com.apple.coredevice.feature.remote.hid.keyboard",
        .pointer: "com.apple.coredevice.feature.remote.hid.pointer",
        .digitizer: "com.apple.coredevice.feature.remote.hid.digitizer",
        .button: "com.apple.coredevice.feature.remote.hid.button",
        .gesture: universalHIDFeature,
    ]
    package static let universalHIDFeature = CoreDeviceHIDService.universalHIDFeature
    private nonisolated static let buttonRequest = NativeRequest.swift(.method(
        "CoreDevice.HIDButton.sendCustomButton(usagePage:usageCode:state:)",
        as: ((Int, Int, NativeSwiftValue) throws -> Void).self))
    private nonisolated static let digitizerRequest = NativeRequest.swift(.method(
        "(extension in CoreDevice):CoreDevice.HIDDigitizer.send(pointOne:pointTwo:eventType:edge:target:)",
        as: ((CGPoint, CGPoint?, NativeSwiftValue, NativeSwiftValue, NativeSwiftValue) throws -> Void).self))

    package init(remote: CoreDeviceRemoteScreenDevice, displayUniqueID: String? = nil) {
        self.remote = remote
        self.displayUniqueID = displayUniqueID
        gestures = NativeTrackpadGestures { try await CoreDeviceTrackpadTransport(remote: remote) }
    }

    /// Prepares input types and calls before the screen becomes interactive. ABIBridge owns the cached results
    /// and revalidates them when the loaded images or captured implementations change.
    package func prepareSimulatorInput() async throws {
        let button = try await implementation(.button, named: "ButtonHIDCapability").type
        let digitizer = try await implementation(.digitizer, named: "DigitizerHIDCapability").type
        try await remote.runtime.prepare { runtime in
            _ = try runtime.resolveAndWait(.swift(.type("CoreDevice.HIDButtonState")))
            _ = try runtime.resolveAndWait(.swift(.type("CoreDevice.DigitizerEventType")))
            _ = try runtime.resolveAndWait(.swift(.type("CoreDevice.DigitizerEdge")))
            _ = try runtime.resolveAndWait(.swift(.type("CoreDevice.DigitizerTarget")))
            _ = try button.resolveAndWait(Self.buttonRequest)
            _ = try digitizer.resolveAndWait(Self.digitizerRequest)
        }
    }

    package func connectDisplay(identifier: UInt32) async throws {
        guard let displayUniqueID else { return }
        let reports: CoreDeviceDigitizerReports
        if let existing = digitizerReports { reports = existing }
        else { reports = try await CoreDeviceDigitizerReports(runtime: remote.runtime) }
        digitizerReports = reports
        let descriptor = try await CoreDeviceHIDService.touchscreenDescriptor(displayID: identifier, uniqueID: displayUniqueID,
                                                                             runtime: remote.runtime)
        displayInput = try await CoreDeviceHIDService.connect(remote: remote, descriptor: descriptor)
        displayIdentifier = identifier
        displayInputNeedsReconnect = false
    }

    package func capabilities() throws -> Set<RemoteDeviceInputKind> {
        var result = Set(try Self.features.compactMap { try remote.supports($0.value) ? $0.key : nil })
        if displayUniqueID != nil {
            result.remove(.pointer)
            if try remote.supports(Self.universalHIDFeature) { result.insert(.digitizer) }
            else { result.remove(.digitizer) }
        }
        return result
    }

    package func send(_ input: RemoteScreenInput) async throws {
        let generation = generations[input.kind, default: 0]
        await beginOperation()
        defer { finishOperation() }
        try Task.checkCancellation()
        guard generations[input.kind, default: 0] == generation else {
            throw RemoteScreenError.unavailable("remote-input-capability", "The device's input service changed before the input could be sent.")
        }
        try await sendNative(input)
        guard generations[input.kind, default: 0] == generation else {
            throw RemoteScreenError.unavailable("remote-input-capability", "The device's input service changed while the input was being sent.")
        }
        pressed.record(input)
    }

    package func discardInputs(for kinds: Set<RemoteDeviceInputKind>) {
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

    package func releaseInputs() async throws {
        await beginOperation()
        defer { finishOperation() }
        var failures: [String] = []
        if let (point, second, edge) = pressed.touch {
            let generation = generations[.digitizer, default: 0]
            do { try await sendNative(.touch(point, second, .ended, edge)); pressed.touch = nil }
            catch { if generations[.digitizer, default: 0] == generation { failures.append(error.localizedDescription) } }
        }
        // Each trackpad's service can hold its own gesture, so every service is reset.
        do { try gestures.resetGestures() } catch { failures.append(error.localizedDescription) }
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
        if !failures.isEmpty { throw RemoteScreenError.io("remote-input-release", failures.joined(separator: "\n")) }
        implementations.removeAll()
    }

    package func stop() async throws {
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
            throw RemoteScreenError.unavailable("remote-input-capability", "The device no longer exposes the requested input operation.")
        }
        if let implementation = implementations[kind] { return implementation }
        let generation = generations[kind, default: 0]
        let implementation = try await remote.implementation(capability: capability, feature: feature)
        guard generations[kind, default: 0] == generation, try remote.supports(feature) else {
            throw RemoteScreenError.unavailable("remote-input-capability", "The device's input service changed while preparing the input.")
        }
        implementations[kind] = implementation
        return implementation
    }

    private func sendNative(_ input: RemoteScreenInput) async throws {
        let runtime = remote.runtime
        let generation = generations[input.kind, default: 0]
        func validatePreparedInput() throws {
            guard generations[input.kind, default: 0] == generation else {
                throw RemoteScreenError.unavailable("remote-input-capability", "The device's input service changed while preparing the input.")
            }
        }
        switch input {
        case .contacts:
            throw RemoteScreenError.unavailable("remote-contact-input", "Contact identity input requires the simulator's guest connection.")
        case .key(let usage, let state):
            let implementation = try await implementation(.keyboard, named: "KeyboardHIDCapability")
            let code = try await runtime.resolve(.swift(.type("CoreDevice.HIDKeyboardUsageCode")))
            let buttonState = try await runtime.resolve(.swift(.type("CoreDevice.HIDButtonState")))
            let make = try await code.resolve(.swift(.initializer("init(rawValue:)", as: ((UInt16) -> NativeSwiftValue).self)))
            let send = try await implementation.type.resolve(.swift(.method("CoreDevice.HIDKeyboard.send(key:state:)",
                as: ((NativeSwiftValue, NativeSwiftValue) throws -> Void).self)))
            try validatePreparedInput()
            try unsafe send.unsafeInvoke(on: implementation, make.unsafeInvoke(usage), buttonState.makeEnumCase(named: state.rawValue))
        case .button(let page, let usage, let state):
            let implementation = try await implementation(.button, named: "ButtonHIDCapability")
            let buttonState = try await runtime.resolve(.swift(.type("CoreDevice.HIDButtonState")))
            let send = try await implementation.type.resolve(Self.buttonRequest)
            try validatePreparedInput()
            try unsafe send.unsafeInvoke(on: implementation, page, usage, buttonState.makeEnumCase(named: state.rawValue))
        case .pointer(let point):
            guard displayUniqueID == nil else { throw RemoteScreenError.unavailable("remote-display-input", "This display has no pointer connection.") }
            let implementation = try await implementation(.pointer, named: "PointerHIDCapability")
            let send = try await implementation.type.resolve(.swift(.method("CoreDevice.HIDPointer.send(movedTo:)",
                as: ((CGPoint) async throws -> Void).self)))
            try validatePreparedInput()
            try await unsafe send.unsafeInvoke(on: implementation, point)
        case .pointerButton(let button, let phase, let clicks, let point):
            guard displayUniqueID == nil else { throw RemoteScreenError.unavailable("remote-display-input", "This display has no pointer connection.") }
            let implementation = try await implementation(.pointer, named: "PointerHIDCapability")
            let pointerPhase = try await runtime.resolve(.swift(.type("CoreDevice.HIDPointerButtonPhase")))
            let send = try await implementation.type.resolve(.swift(.method("CoreDevice.HIDPointer.send(button:phase:clicks:at:)",
                as: ((Int, NativeSwiftValue, Int, CGPoint) async throws -> Void).self)))
            try validatePreparedInput()
            try await unsafe send.unsafeInvoke(on: implementation, button, pointerPhase.makeEnumCase(named: phase.rawValue), clicks, point)
        case .touch(let point, let second, let phase, let edge):
            if displayUniqueID != nil {
                guard try remote.supports(Self.universalHIDFeature) else {
                    throw RemoteScreenError.unavailable("remote-input-capability", "The device no longer exposes the display touchscreen service.")
                }
                if displayInputNeedsReconnect, let identifier = displayIdentifier {
                    try await displayInput?.stop()
                    displayInput = nil
                    try await connectDisplay(identifier: identifier)
                }
                guard let displayInput, let digitizerReports else {
                    throw RemoteScreenError.unavailable("remote-display-input", "The display touchscreen has not connected.")
                }
                try displayInput.send(digitizerReports.make(point: point, second: second, phase: phase, edge: edge))
                return
            }
            let implementation = try await implementation(.digitizer, named: "DigitizerHIDCapability")
            let eventType = try await runtime.resolve(.swift(.type("CoreDevice.DigitizerEventType")))
            let nativeEdge = try await runtime.resolve(.swift(.type("CoreDevice.DigitizerEdge")))
            let target = try await runtime.resolve(.swift(.type("CoreDevice.DigitizerTarget")))
            let send = try await implementation.type.resolve(Self.digitizerRequest)
            let event = switch phase { case .began: "start"; case .moved: "position"; case .ended: "end" }
            try validatePreparedInput()
            try unsafe send.unsafeInvoke(on: implementation, point, second, eventType.makeEnumCase(named: event),
                                         nativeEdge.makeEnumCase(named: edge.rawValue), target.makeEnumCase(named: "mainScreen"))
        case .trackpad(let event, let transform):
            guard try remote.supports(Self.universalHIDFeature) else {
                throw RemoteScreenError.unavailable("remote-input-capability", "The device no longer exposes trackpad gestures.")
            }
            try await gestures.send(event, coordinateTransform: transform)
        case .gesturePointer(let event, let transform):
            guard try remote.supports(Self.universalHIDFeature) else {
                throw RemoteScreenError.unavailable("remote-input-capability", "The device no longer exposes trackpad gestures.")
            }
            try await gestures.movePointer(event, coordinateTransform: transform)
        }
    }
}

/// Routes gestures to their Mac trackpad's guest service and senderless pointer movements to the
/// shared touchscreen gesture service. The guest needs both services to target a scroll.
@MainActor
package final class NativeTrackpadGestures {
    /// A trackpad's guest service, with the observer that keeps that trackpad's gesture state.
    package typealias Service = (service: CoreDeviceHIDService, translator: CoreDeviceEventReports.Translator)

    private let makeTransport: @MainActor () async throws -> any NativeTrackpadTransport
    private var transport: (any NativeTrackpadTransport)?
    /// Guest services by Mac sender ID; zero is the shared touchscreen gesture service.
    private var services: [UInt64: Service] = [:]
    /// Senders that are not Mac HID services, such as other processes' event sources.
    private var unknownSenders: Set<UInt64> = []
    /// Changes when the device invalidates the services, so that an event whose transport or service was prepared
    /// meanwhile is not sent.
    private var generation = 0
    private var isStopped = false

    /// `transport` is prepared with the first gesture.
    package init(transport: @escaping @MainActor () async throws -> any NativeTrackpadTransport) {
        makeTransport = transport
    }

    /// Sends a gesture's reports to its trackpad's service, which the trackpad's first event creates, as
    /// `send(_:coordinateTransform:to:)` does.
    package func send(_ event: NSEvent, coordinateTransform: CGAffineTransform? = nil) async throws {
        // Device Hub drops a gesture that no Mac HID service sent rather than giving it a trackpad the Mac does not have.
        guard let service = try await service(sending: event) else { return }
        try send(event, coordinateTransform: coordinateTransform, to: service)
    }

    /// Sends a scroll or pinch step to its originating trackpad's service.
    /// The first step positions the shared pointer using `coordinateTransform`, if supplied.
    package func send(_ event: NSEvent, coordinateTransform: CGAffineTransform?, to service: Service) throws {
        // Panning, zooming, or turning the canvas moves the screen under a still pointer without a mouse movement, so a
        // gesture first moves the shared pointer to what the screen now shows under it.
        if let coordinateTransform, let movement = try Self.pointerMovement(beginning: event) {
            try movePointer(movement, coordinateTransform: coordinateTransform, on: service)
        }
        let reports = try service.translator.reports(for: event)
        // Without a report, the device would not start the gesture or would keep one the trackpad already ended.
        guard !reports.isEmpty else {
            throw RemoteScreenError.unavailable("remote-gesture-report", "UniversalHIDKit did not translate the gesture.")
        }
        try send(reports)
    }

    /// Moves the hidden pointer to the displayed location, including senderless movements through the shared service.
    package func movePointer(_ event: NSEvent, coordinateTransform: CGAffineTransform) async throws {
        guard let service = try await service(sending: event) else { return }
        try movePointer(event, coordinateTransform: coordinateTransform, on: service)
    }

    /// Translates a movement with the originating observer and routes it to the report's service.
    package func movePointer(_ event: NSEvent, coordinateTransform: CGAffineTransform, on service: Service) throws {
        try send(service.translator.reports(for: event, coordinateTransform: coordinateTransform))
    }

    private func send(_ reports: [CoreDeviceEventReports.Report]) throws {
        for report in reports {
            guard let target = services[report.senderID] else {
                throw RemoteScreenError.unavailable("remote-gesture-service", "The event report has no guest HID service.")
            }
            try target.service.send(report.value)
        }
    }

    /// Prepares the event's service and its shared pointer before any report is sent.
    /// A senderless mouse movement uses only the shared service; a senderless gesture is ignored.
    package func service(sending event: NSEvent) async throws -> Service? {
        guard !isStopped else { throw RemoteScreenError.unavailable("remote-gesture-input", "The device's gesture input has stopped.") }
        let generation = self.generation
        let transport: any NativeTrackpadTransport
        if let prepared = self.transport { transport = prepared } else {
            transport = try await makeTransport()
            try checkPreparation(since: generation)
            self.transport = transport
        }
        let sender = try transport.sender(of: event)
        guard sender != 0 || event.type == .mouseMoved, !unknownSenders.contains(sender) else { return nil }
        guard let service = try await prepareService(sender: sender, transport: transport, generation: generation) else { return nil }
        if sender != 0 {
            _ = try await prepareService(sender: 0, transport: transport, generation: generation)
        }
        return service
    }

    private func prepareService(sender: UInt64, transport: any NativeTrackpadTransport, generation: Int) async throws -> Service? {
        if let existing = services[sender] { return existing }
        guard let created = try await transport.connect(sender: sender) else {
            unknownSenders.insert(sender)
            return nil
        }
        do { try checkPreparation(since: generation) } catch {
            // Stopping removed the services it found, so this one is removed here; the next stop retries a failure.
            if isStopped { do { try await created.service.stop() } catch { services[sender] = created; throw error } }
            throw error
        }
        services[sender] = created
        return created
    }

    /// A mouse movement to `event`'s location when `event` begins a scroll or pinch, which the observer of the trackpad's
    /// service translates as it does the trackpad's own movements; nil for a gesture's later step.
    private static func pointerMovement(beginning event: NSEvent) throws -> NSEvent? {
        // A trackpad's scroll begins with one of these phases; each of a mouse wheel's phaseless events stands alone.
        let begins = event.type == .scrollWheel
            ? !event.phase.isDisjoint(with: [.mayBegin, .began]) || (event.phase.isEmpty && event.momentumPhase.isEmpty)
            : event.phase.contains(.began)
        guard begins else { return nil }
        guard let movement = NSEvent.mouseEvent(with: .mouseMoved, location: event.locationInWindow,
            modifierFlags: event.modifierFlags, timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0) else {
            throw RemoteScreenError.software("native-trackpad-pointer", "AppKit could not create the pointer movement of a gesture.")
        }
        return movement
    }

    /// Throws when, after an event prepared its transport or service, the gesture input has stopped or the device has
    /// invalidated the services since `generation`.
    private func checkPreparation(since generation: Int) throws {
        guard !isStopped else {
            throw RemoteScreenError.unavailable("remote-gesture-input", "The device's gesture input stopped while preparing the input.")
        }
        guard generation == self.generation else {
            throw RemoteScreenError.unavailable("remote-input-capability", "The device's input service changed while preparing the input.")
        }
    }

    /// Ends the gestures each service holds on the device, as Device Hub's HID reset does for each of its services.
    package func resetGestures() throws {
        var failures: [String] = []
        for (_, service) in services.sorted(by: { $0.key < $1.key }) {
            do { try service.service.resetGestures() } catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty { throw RemoteScreenError.io("remote-gesture-reset", failures.joined(separator: "\n")) }
    }

    /// Retires the services, which the device invalidates with its gesture capability, without claiming they ended
    /// their gestures. A trackpad's next gesture creates its service again.
    package func discardServices() {
        services.removeAll()
        generation += 1
    }

    /// Removes the services; later gestures create none. A service that could not be removed is retried by the next stop.
    package func stop() async throws {
        isStopped = true
        let stopping = services
        services = [:]
        var failures: [String] = []
        for (sender, service) in stopping.sorted(by: { $0.key < $1.key }) {
            do { try await service.service.stop() } catch { failures.append(error.localizedDescription) }
            if !service.service.isRemoved { services[sender] = service }
        }
        if !failures.isEmpty { throw RemoteScreenError.io("remote-gesture-removal", failures.joined(separator: "\n")) }
    }
}

/// Converts trackpad gestures to touches for iPhone runtimes without indirect gesture delivery.
/// Coordinates are in the same normalized screen space as mouse touches.
package struct NativeTrackpadTouches {
    private enum Gesture {
        case scroll(anchor: CGPoint, point: CGPoint, id: UInt8, pending: CGVector, active: Bool)
        case pinch(center: CGPoint, offset: CGVector)
    }
    private var gesture: Gesture?

    package mutating func events(for event: NSEvent, transform: CGAffineTransform, renderScale: CGFloat = 1) -> [[NativeTouchContact]] {
        switch event.type {
        case .scrollWheel:
            guard event.momentumPhase.isEmpty else { return [] }
            if !event.phase.isDisjoint(with: [.ended, .cancelled]) { return end() }
            guard event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 else { return [] }
            var result: [[NativeTouchContact]] = []
            let anchor: CGPoint
            var point: CGPoint
            var id: UInt8
            var pending: CGVector
            var active: Bool
            if case let .scroll(oldAnchor, oldPoint, oldID, oldPending, oldActive) = gesture, !event.phase.contains(.began) {
                (anchor, point, id, pending, active) = (oldAnchor, oldPoint, oldID, oldPending, oldActive)
            } else {
                result += end()
                // Leave room to move even when the pointer is exactly on a screen boundary.
                anchor = Self.bounded(event.locationInWindow.applying(transform), inset: 0.01)
                point = anchor
                id = 1
                pending = .zero
                active = false
            }
            let motion = CGAffineTransform(a: transform.a * renderScale, b: transform.b * renderScale,
                                           c: transform.c * renderScale, d: transform.d * renderScale, tx: 0, ty: 0)
            let delta = CGPoint(x: event.scrollingDeltaX, y: -event.scrollingDeltaY).applying(motion)
            pending.dx += delta.x
            pending.dy += delta.y
            if !active {
                let movement = CGPoint(x: pending.dx, y: pending.dy).applying(motion.inverted())
                guard hypot(movement.x, movement.y) >= 12 else {
                    gesture = .scroll(anchor: anchor, point: point, id: id, pending: pending, active: false)
                    return result
                }
                result.append([Self.contact(id, point)])
                active = true
            }
            while abs(pending.dx) + abs(pending.dy) > 0.000000001 {
                var fraction: CGFloat = 1
                if pending.dx > 0 { fraction = min(fraction, (1 - point.x) / pending.dx) }
                if pending.dx < 0 { fraction = min(fraction, -point.x / pending.dx) }
                if pending.dy > 0 { fraction = min(fraction, (1 - point.y) / pending.dy) }
                if pending.dy < 0 { fraction = min(fraction, -point.y / pending.dy) }
                if fraction > 0 {
                    point = Self.bounded(CGPoint(x: point.x + pending.dx * fraction, y: point.y + pending.dy * fraction))
                    result.append([Self.contact(id, point)])
                }
                pending.dx *= 1 - fraction
                pending.dy *= 1 - fraction
                if fraction < 1, abs(pending.dx) + abs(pending.dy) > 0.000000001 {
                    // Add the replacement before lifting the old finger to preserve UIKit's pan translation.
                    // An anchor near an exhausted edge needs room for the next movement, otherwise one scroll
                    // step would produce a burst of nearly stationary contacts.
                    var next = anchor
                    if pending.dx > 0, point.x == 1 { next.x = min(next.x, 0.8) }
                    if pending.dx < 0, point.x == 0 { next.x = max(next.x, 0.2) }
                    if pending.dy > 0, point.y == 1 { next.y = min(next.y, 0.8) }
                    if pending.dy < 0, point.y == 0 { next.y = max(next.y, 0.2) }
                    let replacement: UInt8 = 3 - id
                    result.append([Self.contact(id, point), Self.contact(replacement, next)])
                    result.append([Self.contact(id, point, touching: false), Self.contact(replacement, next)])
                    point = next
                    id = replacement
                }
            }
            gesture = .scroll(anchor: anchor, point: point, id: id, pending: .zero, active: active)
            return result
        case .magnify:
            if !event.phase.isDisjoint(with: [.ended, .cancelled]) { return end() }
            var result: [[NativeTouchContact]] = []
            let center: CGPoint
            var offset: CGVector
            if case let .pinch(oldCenter, oldOffset) = gesture, !event.phase.contains(.began) {
                (center, offset) = (oldCenter, oldOffset)
            } else {
                result += end()
                let location = event.locationInWindow.applying(transform)
                let other = CGPoint(x: event.locationInWindow.x + 50, y: event.locationInWindow.y).applying(transform)
                let span = CGVector(dx: other.x - location.x, dy: other.y - location.y)
                let scale = min(1, 0.2 / max(abs(span.dx), abs(span.dy)))
                center = Self.bounded(location, inset: 0.01)
                let available = Self.bounded(CGVector(dx: span.dx * scale, dy: span.dy * scale), around: center)
                offset = CGVector(dx: available.dx / 2, dy: available.dy / 2)
                result.append(Self.pinch(center, offset: offset))
            }
            let factor = max(0.01, 1 + event.magnification)
            offset = Self.bounded(CGVector(dx: offset.dx * factor, dy: offset.dy * factor), around: center)
            result.append(Self.pinch(center, offset: offset))
            gesture = .pinch(center: center, offset: offset)
            return result
        default:
            return []
        }
    }

    package mutating func end() -> [[NativeTouchContact]] {
        defer { gesture = nil }
        switch gesture {
        case let .scroll(_, point, id, _, active): return active ? [[Self.contact(id, point, touching: false)]] : []
        case let .pinch(center, offset): return [Self.pinch(center, offset: offset, touching: false)]
        case nil: return []
        }
    }

    private static func bounded(_ point: CGPoint, inset: CGFloat = 0) -> CGPoint {
        CGPoint(x: min(1 - inset, max(inset, point.x)), y: min(1 - inset, max(inset, point.y)))
    }

    private static func bounded(_ offset: CGVector, around center: CGPoint) -> CGVector {
        let horizontal = offset.dx == 0 ? 1 : min(center.x, 1 - center.x) / abs(offset.dx)
        let vertical = offset.dy == 0 ? 1 : min(center.y, 1 - center.y) / abs(offset.dy)
        let scale = min(1, horizontal, vertical)
        return CGVector(dx: offset.dx * scale, dy: offset.dy * scale)
    }

    private static func contact(_ id: UInt8, _ point: CGPoint, touching: Bool = true) -> NativeTouchContact {
        NativeTouchContact(id: id, point: point, isTouching: touching)
    }

    private static func pinch(_ center: CGPoint, offset: CGVector, touching: Bool = true) -> [NativeTouchContact] {
        [contact(1, bounded(CGPoint(x: center.x - offset.dx, y: center.y - offset.dy)), touching: touching),
         contact(2, bounded(CGPoint(x: center.x + offset.dx, y: center.y + offset.dy)), touching: touching)]
    }
}

/// Routes simulator scrolling and pinches through guest HID services. The normal route carries the Mac trackpad's
/// properties; iPhone runtimes without indirect gesture delivery use the primary touchscreen instead.
@MainActor
package final class NativeDeviceTrackpad {
    /// Receives failures of events that were already accepted, such as a trackpad service that could not be created.
    package var onFailure: (any Error) -> Void = { _ in }
    private let gestures: NativeTrackpadGestures?
    private let touchscreen: NativeDeviceScreenInput?
    private var touchGestures = NativeTrackpadTouches()
    private var lastOperation: Task<Void, Never>?
    /// Changes when the screen's gestures end, so that an event queued or prepared before then is not sent.
    private var generation = 0
    private var isStopped = false

    /// Connects through a simulator's CoreDevice record, which has said it has HID services. A trackpad's guest service is
    /// created with its first event over the screen.
    package static func connect(remote: CoreDeviceRemoteScreenDevice) async throws -> NativeDeviceTrackpad {
        try Task.checkCancellation()
        let transport = try await CoreDeviceTrackpadTransport(remote: remote)
        return NativeDeviceTrackpad(gestures: NativeTrackpadGestures { transport })
    }

    /// Connects to the guest's UniversalHID service of a simulator in any device set. A trackpad's guest service is
    /// created with its first event over the screen; connecting sends the guest nothing.
    package static func connect(guest: SimulatorGuestHID, touchscreen: NativeDeviceScreenInput? = nil) async throws -> NativeDeviceTrackpad {
        let connection = try await guest.connection(to: CoreDeviceScreenInput.universalHIDFeature)
        let transport = try await CoreDeviceTrackpadTransport(runtime: .shared) { try await connection.createService($0) }
        return NativeDeviceTrackpad(gestures: NativeTrackpadGestures { transport }, touchscreen: touchscreen)
    }

    package init(gestures: NativeTrackpadGestures? = nil, touchscreen: NativeDeviceScreenInput? = nil) {
        self.gestures = gestures
        self.touchscreen = touchscreen
    }

    /// Maps window locations to the unit coordinates of `view`'s bounds from its top-left corner, the pointer coordinates
    /// of a screen that `view` shows upright, as Device Hub's HID view maps window locations to its display's pointer.
    package static func coordinateTransform(fromWindowTo view: NSView) -> CGAffineTransform {
        let bounds = view.bounds
        let toUnit = CGAffineTransform(translationX: 0, y: view.isFlipped ? 0 : 1)
            .scaledBy(x: 1 / bounds.width, y: view.isFlipped ? 1 / bounds.height : -1 / bounds.height)
            .translatedBy(x: -bounds.minX, y: -bounds.minY)
        return CGAffineTransform(sampling: { view.convert($0, from: nil) }).concatenating(toUnit)
    }

    /// Includes enclosing canvas magnification as well as SimulatorKit's framebuffer scale.
    package static func contentScale(of view: NSView, renderScale: CGFloat) -> CGFloat {
        let origin = view.convert(CGPoint.zero, to: nil)
        let unit = view.convert(CGPoint(x: 1, y: 0), to: nil)
        return renderScale * hypot(unit.x - origin.x, unit.y - origin.y)
    }

    /// Forwards a scroll, a pinch step, or a mouse movement, in the order of the calls. `coordinateTransform` maps the
    /// event's window location to the screen's pointer coordinates; a mouse movement, and a scroll or pinch that begins,
    /// move its trackpad's pointer there. The touchscreen route turns scrolling into a drag and pinching into two touches.
    package func handle(_ event: NSEvent, coordinateTransform: CGAffineTransform, renderScale: CGFloat = 1) {
        guard !isStopped, [.scrollWheel, .magnify, .mouseMoved].contains(event.type) else { return }
        if let touchscreen, event.type == .mouseMoved || touchscreen.hasPointerTouch { return }
        let token = generation
        enqueue { [weak self, gestures] in
            guard let self, generation == token else { return }
            do {
                // A trackpad's first event waits for its service; one whose gestures end meanwhile is not sent.
                if let touchscreen, event.type != .scrollWheel || !event.phase.isEmpty || !event.momentumPhase.isEmpty {
                    guard generation == token, !touchscreen.hasPointerTouch else { return }
                    send(touchGestures.events(for: event, transform: coordinateTransform, renderScale: renderScale), to: touchscreen)
                } else {
                    guard let gestures else { return }
                    guard let service = try await gestures.service(sending: event), generation == token else { return }
                    if event.type == .mouseMoved {
                        try gestures.movePointer(event, coordinateTransform: coordinateTransform, on: service)
                    } else {
                        try gestures.send(event, coordinateTransform: coordinateTransform, to: service)
                    }
                }
            } catch {
                guard generation == token else { return }
                // The guest would otherwise keep a gesture whose remaining steps it does not receive.
                endGestures()
                onFailure(error)
            }
        }
    }

    /// Ends the gestures that each trackpad's service holds, as when the screen loses focus or moves to another window.
    /// Events that have not been sent are dropped; the services remain for later gestures.
    package func endGestures() {
        generation += 1
        if let touchscreen { send(touchGestures.end(), to: touchscreen) }
        do { try gestures?.resetGestures() } catch { onFailure(error) }
    }

    /// Removes the services when the screen disconnects, after the events already accepted; later events are dropped.
    /// A service that could not be removed is retried by the next stop.
    package func stop() async throws {
        isStopped = true
        if let touchscreen {
            endGestures()
            await touchscreen.waitForPendingInput()
        }
        try await enqueue { [gestures] in try await gestures?.stop() }.value
    }

    private func send(_ frames: [[NativeTouchContact]], to touchscreen: NativeDeviceScreenInput) {
        for frame in frames { touchscreen.sendContacts(frame) }
    }

    @discardableResult
    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) -> Task<Void, any Error> {
        let previous = lastOperation
        let task = Task { @MainActor in
            await previous?.value
            try await operation()
        }
        lastOperation = Task { _ = await task.result }
        return task
    }
}

/// Sends integrated-screen touches and buttons through native guest services in call order.
/// Uses CoreDevice or equivalent guest messages for other device sets. Native keyboard and
/// trackpad services make the guest reject SimulatorKit touches, so these must switch too.
@MainActor
package final class NativeDeviceScreenInput {
    /// Receives failures of touches that were already accepted.
    package var onFailure: (any Error) -> Void = { _ in }
    private let input: any NativeScreenInputTransport
    private var lastOperation: Task<Void, Never>?
    private var isStopped = false
    package private(set) var hasPointerTouch = false

    /// Connects through a simulator's CoreDevice record, which has said it has touchscreen and button services.
    package static func connect(remote: CoreDeviceRemoteScreenDevice) async throws -> NativeDeviceScreenInput {
        let input = CoreDeviceScreenInput(remote: remote)
        try await input.prepareSimulatorInput()
        try Task.checkCancellation()
        return NativeDeviceScreenInput(input: input)
    }

    /// Connects to the guest's touchscreen and button services of a simulator in any device set. Connecting sends the
    /// guest nothing.
    package static func connect(guest: SimulatorGuestHID, contactIdentities: Bool = false) async throws -> NativeDeviceScreenInput {
        NativeDeviceScreenInput(input: try await GuestScreenInput(guest: guest, contactIdentities: contactIdentities))
    }

    package init(input: any NativeScreenInputTransport) {
        self.input = input
    }

    /// Sends a touch at `point`, and `secondPoint` for a second finger, in unit coordinates from the top-left corner
    /// of the screen in its own orientation. A touch whose input has stopped is dropped.
    package func sendTouch(at point: CGPoint, secondPoint: CGPoint?, phase: RemoteDeviceTouchPhase, edge: RemoteDeviceTouchEdge) {
        guard !isStopped else { return }
        if phase == .began { hasPointerTouch = true }
        if phase == .ended { hasPointerTouch = false }
        enqueue { [weak self, input] in
            do { try await input.send(.touch(point, secondPoint, phase, edge)) } catch { self?.onFailure(error) }
        }
    }

    /// Waits for accepted touches before their owner removes the guest HID services.
    package func waitForPendingInput() async { await lastOperation?.value }

    package func sendContacts(_ contacts: [NativeTouchContact]) {
        guard !isStopped, !hasPointerTouch else { return }
        enqueue { [weak self, input] in
            do { try await input.send(.contacts(contacts)) } catch { self?.onFailure(error) }
        }
    }

    /// Sends a button's HID usage after the input accepted before it. `completion` receives the result; a thrown
    /// error means the input has stopped and nothing was sent.
    package func sendButton(usagePage: Int, usage: Int, state: RemoteDeviceButtonState,
                           completion: @escaping @MainActor ((any Error)?) -> Void) throws {
        guard !isStopped else { throw RemoteScreenError.unavailable("native-screen-input", "The device's screen input has stopped.") }
        enqueue { [input] in
            do {
                try await input.send(.button(usagePage, usage, state))
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    /// Releases the touch and buttons that the device still holds, after the input already accepted; later input is
    /// dropped. What could not be released is released by the next stop.
    package func stop() async throws {
        isStopped = true
        try await enqueue { [input] in try await input.stop() }.value
    }

    @discardableResult
    private func enqueue(_ operation: @escaping @MainActor () async throws -> Void) -> Task<Void, any Error> {
        let previous = lastOperation
        let task = Task { @MainActor in
            await previous?.value
            try await operation()
        }
        lastOperation = Task { _ = await task.result }
        return task
    }
}

/// The device services that a screen's touches and buttons reach.
@MainActor
package protocol NativeScreenInputTransport: AnyObject {
    func send(_ input: RemoteScreenInput) async throws
    /// Releases what the services hold and removes them.
    func stop() async throws
}

extension CoreDeviceScreenInput: NativeScreenInputTransport {}

/// The Mac HID services that send trackpad gestures and the guest services that receive them.
@MainActor
package protocol NativeTrackpadTransport: AnyObject {
    /// The registry ID of the Mac HID service that produced the event, or 0 for a synthesized event.
    func sender(of event: NSEvent) throws -> UInt64
    /// Creates the shared touchscreen gesture service for zero, or the Mac HID service's guest service otherwise.
    /// Returns nil when a nonzero sender has no Mac HID service.
    func connect(sender: UInt64) async throws -> NativeTrackpadGestures.Service?
}

@MainActor
package final class CoreDeviceTrackpadTransport: NativeTrackpadTransport {
    private static let logger = Logger(subsystem: "dev.lynnswap.NeoSimulator", category: "Trackpad")
    private let bindings: NativeTrackpadBindings
    private let runtime: ABIRuntime
    /// Creates the guest service that a CoreDevice `HIDServiceDescriptor` describes.
    private let createService: @MainActor (NativeSwiftValue) async throws -> CoreDeviceHIDService

    package init(runtime: ABIRuntime, createService: @escaping @MainActor (NativeSwiftValue) async throws -> CoreDeviceHIDService) async throws {
        bindings = try await NativeTrackpadBindings(runtime: runtime)
        self.runtime = runtime
        self.createService = createService
    }

    package convenience init(remote: CoreDeviceRemoteScreenDevice) async throws {
        try await self.init(runtime: remote.runtime) { try await CoreDeviceHIDService.connect(remote: remote, descriptor: $0) }
    }

    package func sender(of event: NSEvent) throws -> UInt64 { try bindings.lookup.sender(of: event) }

    package func connect(sender: UInt64) async throws -> NativeTrackpadGestures.Service? {
        if sender == 0 {
            let descriptor = try await CoreDeviceHIDService.touchscreenGestureDescriptor(runtime: runtime)
            let translator = try bindings.makeTranslator()
            return (try await createService(descriptor), translator)
        }
        let source = "Mac HID service 0x\(String(sender, radix: 16))"
        guard let properties = try bindings.lookup.properties(ofHIDService: sender) else {
            Self.logger.error("The gestures of \(source, privacy: .public) reach no guest service: the Mac has no such HID service")
            return nil
        }
        let translator = try bindings.makeTranslator()
        let service = try await createService(bindings.descriptor(serviceID: sender, properties: properties))
        Self.logger.log("Created the guest trackpad service for \(source, privacy: .public)")
        return (service, translator)
    }
}

/// Describes a Mac trackpad's guest service and translates the trackpad's gestures, as Device Hub does.
@MainActor
package struct NativeTrackpadBindings {
    /// The Mac HID services that gestures come from.
    package let lookup: MacHIDServiceLookup
    private let events: CoreDeviceEventReports
    private let adjust: (NativeSwiftValue) throws -> Void

    package init(runtime: ABIRuntime) async throws {
        lookup = try await MacHIDServiceLookup(runtime: runtime)
        // Like Device Hub's, the observer translates both the trackpad's magnify events and its mouse movements.
        events = try await CoreDeviceEventReports(runtime: runtime, eventType: nil)
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
    package func makeTranslator() throws -> CoreDeviceEventReports.Translator { try events.makeTranslator() }

    /// The descriptor of a guest service that carries a Mac trackpad's `properties` under its registry ID `serviceID`.
    package func descriptor(serviceID: UInt64, properties: [String: Any]) throws -> NativeSwiftValue {
        let descriptor = try lookup.descriptor(serviceID: serviceID, properties: properties)
        try adjust(descriptor)
        return descriptor
    }
}

package struct RemoteScreenPressedInputs {
    package struct Button: Hashable { package let page: Int; package let usage: Int }
    package var keys: Set<UInt16> = []
    package var buttons: Set<Button> = []
    package var pointerButtons: [Int: CGPoint] = [:]
    package var touch: (CGPoint, CGPoint?, RemoteDeviceTouchEdge)?
    package var contacts: [UInt8: CGPoint] = [:]

    package mutating func record(_ input: RemoteScreenInput) {
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
        case .contacts(let updates):
            for contact in updates {
                if contact.isTouching { contacts[contact.id] = contact.point }
                else { contacts.removeValue(forKey: contact.id) }
            }
        case .pointer, .trackpad, .gesturePointer: break
        }
    }

    package mutating func discard(for kinds: Set<RemoteDeviceInputKind>) {
        if kinds.contains(.keyboard) { keys.removeAll() }
        if kinds.contains(.button) { buttons.removeAll() }
        if kinds.contains(.pointer) { pointerButtons.removeAll() }
        if kinds.contains(.digitizer) { touch = nil; contacts.removeAll() }
    }
}

private extension RemoteScreenInput {
    var kind: RemoteDeviceInputKind {
        switch self {
        case .key: .keyboard
        case .button: .button
        case .pointer, .pointerButton: .pointer
        case .touch, .contacts: .digitizer
        case .trackpad, .gesturePointer: .gesture
        }
    }
}
