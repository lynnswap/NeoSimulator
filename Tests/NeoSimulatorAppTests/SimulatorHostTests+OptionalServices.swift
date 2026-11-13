import ABIBridge
import AppKit
import Darwin
import IOKit.hidsystem
@testable import NeoSimulatorApp
@testable import NeoSimulatorDeviceIO
@testable import NeoSimulatorHostSupport
@testable import NeoSimulatorKit
@testable import NeoSimulatorPresentationAdapters
@testable import NeoSimulatorService
@testable import NeoSimulatorUI
import Observation
import Synchronization
import Testing
import SwiftUI
import Combine
import XCTest
import XPC
@testable import NeoSimulatorManager
@testable import NeoSimulatorInspector
@testable import NeoSimulatorDeviceDisplay
@testable import NeoSimulatorCompactWindow
@testable import NeoSimulatorDeviceScreens

extension SimulatorHostTests {
    @Test func inputRoutesFollowWhatTheDeviceIs() {
        let keyboard = DeviceCapabilities.keyboard
        // A phone or pad reaches the guest that owns its screen, in any device set.
        #expect(inputPlan(.iPhone, [keyboard]) == .guest(touchscreenGestures: false))
        #expect(inputPlan(.iPad, [keyboard], defaultSet: false) == .guest(touchscreenGestures: false))
        #expect(inputPlan(.iPhone, [keyboard], runtimeVersion: 0x1A_00_00) == .guest(touchscreenGestures: true))
        #expect(inputPlan(.iPad, [keyboard], runtimeVersion: 0x1A_00_00) == .guest(touchscreenGestures: false))
        // An independent canvas is the screen of a Duo in the default set; elsewhere CoreDevice cannot reach it.
        #expect(inputPlan(.iPhone, [keyboard], deviceType: NativeInputPlan.duoDeviceType) == .canvas)
        #expect(inputPlan(.iPhone, [keyboard], deviceType: NativeInputPlan.duoDeviceType, defaultSet: false) == .simulatorKit)
        // CoreDevice lists only the default set.
        #expect(inputPlan(.tv, [keyboard]) == .coreDevice(keyboard: true, trackpad: true, touches: false))
        #expect(inputPlan(.tv, [keyboard], defaultSet: false) == .simulatorKit)
        #expect(inputPlan(.iPad, []) == .coreDevice(keyboard: false, trackpad: true, touches: true))
        // A crown or dial, and a device UI plugin's overlay, keep the pointer with SimulatorKit.
        #expect(inputPlan(.watch, [keyboard, DeviceCapabilities.digitalCrown])
            == .coreDevice(keyboard: true, trackpad: false, touches: false))
        #expect(inputPlan(.watch, [DeviceCapabilities.digitalCrown]) == .simulatorKit)
        #expect(inputPlan(.vision, [keyboard], plugin: true) == .coreDevice(keyboard: true, trackpad: false, touches: false))
    }

    /// Native input would make the guest drop SimulatorKit's touches, the only ones that carry pressure, so a 3D Touch
    /// screen keeps SimulatorKit's input whatever else it supports.
    @Test func touchPressureKeepsSimulatorKitInput() {
        let pressure: Set<String> = [DeviceCapabilities.keyboard, DeviceCapabilities.touchPressure]
        #expect(inputPlan(.iPhone, pressure) == .simulatorKit)
        #expect(inputPlan(.iPhone, pressure, defaultSet: false) == .simulatorKit)
        #expect(inputPlan(.iPad, [DeviceCapabilities.touchPressure]) == .simulatorKit)
    }

    @Test(.timeLimit(.minutes(1)))
    func inputConnectsAfterTheDisplayAndActivatesInPlace() async throws {
        let services = DeviceOptionalServices()
        let connecting = HeldCalls<NativeInputServices?>()
        let activations = Counter()
        let activation = NativeInputActivation(services: services, connect: { try await connecting.call() },
                                               activate: { _ in activations.value += 1 })
        #expect(isPending(services.input))
        activation.start()
        try await wait { connecting.isHolding }
        // Nothing the display does waits on this, and starting again joins it.
        #expect(isPending(services.input) && activations.value == 0)
        activation.start()
        services.retryInput()
        #expect(connecting.calls == 1)
        connecting.finish(.success(NativeInputServices()))
        try await wait { isReady(services.input) }
        #expect(activations.value == 1)
        // A ready route has nothing to retry.
        services.retryInput()
        #expect(connecting.calls == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aDeviceWithoutTheRouteIsUnsupportedWithoutActivating() async throws {
        let services = DeviceOptionalServices()
        let connecting = HeldCalls<NativeInputServices?>()
        let activations = Counter()
        let activation = NativeInputActivation(services: services, connect: { try await connecting.call() },
                                               activate: { _ in activations.value += 1 })
        activation.start()
        try await wait { connecting.isHolding }
        connecting.finish(.success(nil))
        try await wait { isUnsupported(services.input) }
        services.retryInput()
        #expect(activations.value == 0 && connecting.calls == 1)
    }

    /// A transport that did not answer says nothing about the device: this is neither unsupported nor another route.
    @Test(.timeLimit(.minutes(1)))
    func aFailedRouteStaysFailedUntilItIsRetriedOnTheSameRoute() async throws {
        let services = DeviceOptionalServices()
        let connecting = HeldCalls<NativeInputServices?>()
        let activations = Counter()
        let activation = NativeInputActivation(services: services, connect: { try await connecting.call() },
                                               activate: { _ in activations.value += 1 })
        activation.start()
        try await wait { connecting.isHolding }
        connecting.finish(.failure(DeviceIOError.temporary("fixture-timeout", "The guest did not answer.")))
        try await wait { services.input.failure != nil }
        #expect((services.input.failure as? DeviceIOError)?.identifier == "fixture-timeout")
        #expect(activations.value == 0 && connecting.calls == 1)

        services.retryInput()
        #expect(isPending(services.input))
        try await wait { connecting.isHolding }
        #expect(connecting.calls == 2)
        connecting.finish(.success(NativeInputServices()))
        try await wait { isReady(services.input) }
        #expect(activations.value == 1)
    }

    /// A display that could not take the services over stays on SimulatorKit, says so, and can try again.
    @Test(.timeLimit(.minutes(1)))
    func aFailedActivationIsTheRoutesFailure() async throws {
        let services = DeviceOptionalServices()
        let refuses = Counter(1)
        let activations = Counter()
        let activation = NativeInputActivation(services: services, connect: { NativeInputServices() }, activate: { _ in
            activations.value += 1
            if refuses.value == 1 { throw DeviceIOError.unavailable("fixture-digitizer", "The digitizer has no delegate.") }
        })
        activation.start()
        try await wait { services.input.failure != nil }
        refuses.value = 0
        services.retryInput()
        try await wait { isReady(services.input) }
        #expect(activations.value == 2)
    }

    /// Connecting sends the guest nothing, so what answers after the display ended is let go without being activated.
    @Test(.timeLimit(.minutes(1)))
    func aCancelledConnectionActivatesNothing() async throws {
        let services = DeviceOptionalServices()
        let connecting = HeldCalls<NativeInputServices?>()
        let activations = Counter()
        let activation = NativeInputActivation(services: services, connect: { try await connecting.call() },
                                               activate: { _ in activations.value += 1 })
        activation.start()
        try await wait { connecting.isHolding }
        activation.cancel()
        // A native call that ignores its cancellation holds its owner's wait, which stop() reports.
        #expect(await !activation.ends(before: ContinuousClock.now))
        connecting.finish(.success(NativeInputServices()))
        #expect(await activation.ends(before: ContinuousClock.now + .seconds(30)))
        #expect(activations.value == 0 && isPending(services.input))
    }

    @Test(.timeLimit(.minutes(1)))
    func aPasteboardFailureFallsBackToNothingAndTheNextTransferAsksAgain() async throws {
        let services = DeviceOptionalServices()
        let connecting = HeldCalls<(any PasteboardTransport)?>()
        let route = SimulatorPasteboardRoute(services: services, make: { try await connecting.call() })
        #expect(isPending(services.pasteboard))

        let refused = Task.immediate { try await route.transport().map(ObjectIdentifier.init) }
        try await wait { connecting.isHolding }
        connecting.finish(.failure(DeviceIOError.temporary("fixture-timeout", "CoreDevice did not answer.")))
        await #expect(throws: DeviceIOError.self) { try await refused.value }
        #expect((services.pasteboard.failure as? DeviceIOError)?.identifier == "fixture-timeout")

        let transport = TestPasteboardTransport()
        let retried = Task.immediate { try await route.transport().map(ObjectIdentifier.init) }
        try await wait { connecting.isHolding }
        #expect(isPending(services.pasteboard) && connecting.calls == 2)
        connecting.finish(.success(transport))
        #expect(try await retried.value == ObjectIdentifier(transport))
        #expect(isReady(services.pasteboard))
        // The answer holds for the device's connection.
        #expect(try await route.transport() === transport)
        #expect(connecting.calls == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func simPasteboardPlusServesOnlyADeviceWithoutARoutedTransport() async throws {
        let services = DeviceOptionalServices()
        let route = SimulatorPasteboardRoute(services: services, make: { nil })
        #expect(try await route.transport() == nil)
        #expect(isUnsupported(services.pasteboard))

        let unrouted = DeviceOptionalServices()
        #expect(try await SimulatorPasteboardRoute(services: unrouted, make: nil).transport() == nil)
        #expect(isNotRouted(unrouted.pasteboard))
    }

    @Test(.timeLimit(.minutes(1)))
    func aCancelledPasteboardConnectionIsNotAFailure() async {
        let services = DeviceOptionalServices()
        let route = SimulatorPasteboardRoute(services: services, make: { throw CancellationError() })
        await #expect(throws: CancellationError.self) { _ = try await route.transport() }
        #expect(isPending(services.pasteboard))
    }

    /// The display is open before CoreDevice lists the device. Neither no record nor a record that is not connected says
    /// what the device has, and the input CoreDevice then offers arrives on that same display, with nothing left followed.
    @Test(.timeLimit(.minutes(1)))
    func delayedDiscoveryGivesTheChosenRouteOnTheOpenDisplay() async throws {
        let display = TestDisplay()
        let session = try makeSession(display)
        let services = session.optionalServices
        let source = RecordSourceFixture()
        let discovery = CoreDeviceRecordDiscovery(source: source)
        discovery.onAwaitingChange = { services.setAwaitingDeviceRecord($0) }
        let activations = Counter()
        let activation = NativeInputActivation(services: services, connect: {
            guard case .supported = try await discovery.answer(for: ["input"]) else { return nil }
            return NativeInputServices()
        }, activate: { _ in activations.value += 1 })
        activation.start()
        try await wait { source.followers == 1 }
        #expect(isPending(services.input) && services.isAwaitingDeviceRecord)

        let record = RecordFixture()
        source.current = record
        source.change()
        try await wait { source.followers == 2 }
        #expect(isPending(services.input) && activations.value == 0)

        record.connected = true
        record.features = ["input"]
        source.change()
        try await wait { isReady(services.input) && source.followers == 0 }
        #expect(activations.value == 1 && !services.isAwaitingDeviceRecord)
        #expect(session.display === display)
    }

    /// CoreDevice's list replaces the record that a wait follows, and only the new record's own notification says when it
    /// connects. A read returns a new value of an unchanged record too, which is no reason to follow again.
    @Test(.timeLimit(.minutes(1)))
    func aWaitFollowsTheRecordThatReplacedTheOneItFollowed() async throws {
        let source = RecordSourceFixture()
        let discovery = CoreDeviceRecordDiscovery(source: source)
        defer { discovery.stop() }
        let old = RecordFixture()
        source.current = old
        let waiting = Task.immediate { () -> ObjectIdentifier? in
            guard case .supported(let record) = try await discovery.answer(for: ["input"]) else { return nil }
            return ObjectIdentifier(record)
        }
        try await wait { source.recordFollows == 1 && source.followers(of: old) == 1 && source.followers(of: nil) == 1 }

        source.current = RecordFixture()
        let reads = source.reads
        source.change(of: old)
        try await wait { source.reads > reads }
        #expect(source.recordFollows == 1 && source.followers(of: old) == 1)

        let new = RecordFixture()
        source.current = new
        source.change(of: nil)
        try await wait { source.followers(of: old) == 0 && source.followers(of: new) == 1 }

        new.connected = true
        new.features = ["input"]
        source.change(of: new)
        #expect(try await waiting.value == ObjectIdentifier(new))
        try await wait { source.followers == 0 }
    }

    @Test(.timeLimit(.minutes(1)))
    func replacementDuringTheInitialDecisionUsesTheCurrentRecord() async throws {
        let source = RecordSourceFixture()
        let connection = HeldCalls<Bool>()
        let old = RecordFixture()
        old.heldConnection = connection
        source.current = old
        let discovery = CoreDeviceRecordDiscovery(source: source)
        defer { discovery.stop() }
        let answer = Task.immediate { () -> ObjectIdentifier? in
            guard case .supported(let record) = try await discovery.answer(for: ["input"]) else { return nil }
            return ObjectIdentifier(record)
        }
        try await wait { connection.isHolding }
        let current = RecordFixture()
        current.connected = true
        current.features = ["input"]
        try await source.changeList(to: current)
        connection.finish(.success(true))
        #expect(try await answer.value == ObjectIdentifier(current))
        try await wait { source.followers == 0 }
    }

    /// A decision on a record that the list has since replaced is no answer, even a connected record's lack of the feature,
    /// which a route would keep for the connection's lifetime. The list as it is now decides, also for an asker whose first
    /// read it was, which no notification wakes because it waits on none yet.
    @Test(.timeLimit(.minutes(1)))
    func aDecisionOnARecordThatTheListReplacedIsNoAnswer() async throws {
        for byAnotherAsker in [false, true] {
            let services = DeviceOptionalServices()
            let source = RecordSourceFixture()
            let discovery = CoreDeviceRecordDiscovery(source: source)
            defer { discovery.stop() }
            let route = SimulatorPasteboardRoute(services: services, make: {
                guard case .supported = try await discovery.answer(for: ["pasteboard"]) else { return nil }
                return TestPasteboardTransport()
            })
            let old = RecordFixture()
            source.current = old
            let transfer = Task.immediate { try await route.transport().map(ObjectIdentifier.init) }
            try await wait { source.recordFollows == 1 && source.followers(of: old) == 1 && source.followers(of: nil) == 1 }

            let connection = HeldCalls<Bool>()
            old.heldConnection = connection
            var asker: Task<ObjectIdentifier?, any Error>?
            if byAnotherAsker {
                asker = Task.immediate { () -> ObjectIdentifier? in
                    guard case .supported(let record) = try await discovery.answer(for: ["pasteboard"]) else { return nil }
                    return ObjectIdentifier(record)
                }
            } else {
                source.change(of: old)
            }
            try await wait { connection.isHolding }

            let new = RecordFixture()
            try await source.changeList(to: new)
            connection.finish(.success(true))
            try await wait { source.followers(of: new) == 1 || !isPending(services.pasteboard) }
            #expect(isPending(services.pasteboard))

            new.connected = true
            new.features = ["pasteboard"]
            source.change(of: new)
            #expect(try await transfer.value != nil)
            if let asker { #expect(try await asker.value == ObjectIdentifier(new)) }
            #expect(isReady(services.pasteboard))
            try await wait { source.followers == 0 }
        }
    }

    /// A read that fails after the list changed failed on what the list no longer holds, so the next read decides, and a
    /// failure of a read of the list as it is now is told.
    @Test(.timeLimit(.minutes(1)))
    func aFailedReadOfAListThatChangedLeavesTheNextReadToDecide() async throws {
        let services = DeviceOptionalServices()
        let source = RecordSourceFixture()
        let discovery = CoreDeviceRecordDiscovery(source: source)
        defer { discovery.stop() }
        let route = SimulatorPasteboardRoute(services: services, make: {
            guard case .supported = try await discovery.answer(for: ["pasteboard"]) else { return nil }
            return TestPasteboardTransport()
        })
        let old = RecordFixture()
        source.current = old
        let transfer = Task.immediate { _ = try await route.transport() }
        try await wait { source.recordFollows == 1 && source.followers(of: old) == 1 && source.followers(of: nil) == 1 }

        let reads = HeldCalls<RecordFixture?>()
        source.heldReads = reads
        source.change(of: old)
        try await wait { reads.isHolding }
        try await source.changeList(to: RecordFixture())
        reads.finish(.failure(DeviceIOError.temporary("fixture-old", "The list no longer holds it.")))
        try await wait { reads.calls == 2 && reads.isHolding || !isPending(services.pasteboard) }
        #expect(isPending(services.pasteboard))

        reads.finish(.failure(DeviceIOError.temporary("fixture-current", "CoreDevice did not answer.")))
        await #expect(throws: DeviceIOError.self) { try await transfer.value }
        #expect((services.pasteboard.failure as? DeviceIOError)?.identifier == "fixture-current")
        try await wait { source.followers == 0 }
    }

    /// A record that leaves CoreDevice's list is no answer and is no longer followed, and the owner's stop ends what followed its successor.
    @Test(.timeLimit(.minutes(1)))
    func aRemovedRecordIsNoLongerFollowedAndItsSuccessorEndsWithTheOwner() async throws {
        let source = RecordSourceFixture()
        let discovery = CoreDeviceRecordDiscovery(source: source)
        let old = RecordFixture()
        source.current = old
        let waiting = Task.immediate { _ = try await discovery.answer(for: ["input"]) }
        try await wait { source.followers(of: old) == 1 && source.followers(of: nil) == 1 }

        source.current = nil
        source.change(of: nil)
        try await wait { source.followers(of: old) == 0 && source.followers == 1 }

        let new = RecordFixture()
        source.current = new
        source.change(of: nil)
        try await wait { source.followers(of: new) == 1 && source.followers == 2 }

        discovery.stop()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        try await wait { source.followers == 0 }
    }

    /// Only a connected record without the feature is evidence, and it is what takes SimPasteboardPlus.
    @Test(.timeLimit(.minutes(1)))
    func onlyAConnectedRecordWithoutTheFeatureIsUnsupported() async throws {
        let services = DeviceOptionalServices()
        let source = RecordSourceFixture()
        let discovery = CoreDeviceRecordDiscovery(source: source)
        let record = RecordFixture()
        source.current = record
        let activations = Counter()
        let activation = NativeInputActivation(services: services, connect: {
            guard case .supported = try await discovery.answer(for: ["input"]) else { return nil }
            return NativeInputServices()
        }, activate: { _ in activations.value += 1 })
        let route = SimulatorPasteboardRoute(services: services, make: {
            guard case .supported = try await discovery.answer(for: ["pasteboard"]) else { return nil }
            return TestPasteboardTransport()
        })
        activation.start()
        let transfer = Task.immediate { try await route.transport().map(ObjectIdentifier.init) }
        try await wait { source.followers == 2 }
        #expect(isPending(services.input) && isPending(services.pasteboard))

        record.connected = true
        source.change()
        try await wait { isUnsupported(services.input) && isUnsupported(services.pasteboard) }
        #expect(try await transfer.value == nil)
        #expect(activations.value == 0)
    }

    /// A read that fails and notifications that end say nothing about the device, and asking again goes through the same owner.
    @Test(.timeLimit(.minutes(1)))
    func aFailureToReadTheRecordIsNotUnsupportedAndCanBeRetried() async throws {
        let services = DeviceOptionalServices()
        let source = RecordSourceFixture()
        let discovery = CoreDeviceRecordDiscovery(source: source)
        let activations = Counter()
        let activation = NativeInputActivation(services: services, connect: {
            guard case .supported = try await discovery.answer(for: ["input"]) else { return nil }
            return NativeInputServices()
        }, activate: { _ in activations.value += 1 })
        source.readFailure = DeviceIOError.temporary("fixture-read", "CoreDevice did not answer.")
        activation.start()
        try await wait { services.input.failure != nil }
        #expect((services.input.failure as? DeviceIOError)?.identifier == "fixture-read")
        #expect(source.followers == 0)

        source.readFailure = nil
        services.retryInput()
        try await wait { source.followers == 1 }
        #expect(isPending(services.input))
        source.endStreams(throwing: DeviceIOError.temporary("fixture-stream", "CoreDevice stopped reporting."))
        try await wait { services.input.failure != nil && source.followers == 0 }
        #expect((services.input.failure as? DeviceIOError)?.identifier == "fixture-stream")

        let record = RecordFixture()
        record.connected = true
        record.features = ["input"]
        source.current = record
        services.retryInput()
        try await wait { isReady(services.input) }
        #expect(activations.value == 1)
    }

    /// The owner ends with its connection: what waits is cancelled, which says nothing about the device, and nothing is followed.
    @Test(.timeLimit(.minutes(1)))
    func stoppingTheRecordsOwnerEndsWhatWaitsWithoutAnAnswer() async throws {
        let services = DeviceOptionalServices()
        let source = RecordSourceFixture()
        let discovery = CoreDeviceRecordDiscovery(source: source)
        let route = SimulatorPasteboardRoute(services: services, make: {
            guard case .supported = try await discovery.answer(for: ["pasteboard"]) else { return nil }
            return TestPasteboardTransport()
        })
        let transfer = Task.immediate { try await route.transport().map(ObjectIdentifier.init) }
        let cancelled = Task.immediate { _ = try await discovery.answer(for: ["input"]) }
        try await wait { source.followers == 1 }
        // One asker's cancellation leaves the other's wait.
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(source.followers == 1 && isPending(services.pasteboard))

        discovery.stop()
        await #expect(throws: CancellationError.self) { _ = try await transfer.value }
        try await wait { source.followers == 0 }
        #expect(isPending(services.pasteboard))
        await #expect(throws: CancellationError.self) { _ = try await discovery.answer(for: ["pasteboard"]) }
    }

    /// A stop is terminal while a read is out, before anything waits on notifications, and nothing but a transfer's own
    /// wait would end that transfer: whatever the read then finds, it ends as cancelled, says nothing and follows nothing.
    @Test(.timeLimit(.minutes(1)))
    func aStopDuringAReadEndsTheWaitWhateverTheReadThenFinds() async throws {
        func stopping(_ source: RecordSourceFixture, isHeld: () -> Bool, then finish: () -> Void) async throws {
            let services = DeviceOptionalServices()
            let discovery = CoreDeviceRecordDiscovery(source: source)
            let route = SimulatorPasteboardRoute(services: services, make: {
                guard case .supported = try await discovery.answer(for: ["pasteboard"]) else { return nil }
                return TestPasteboardTransport()
            })
            let transfer = Task.immediate { _ = try await route.transport() }
            try await wait(until: isHeld)
            discovery.stop()
            finish()
            #expect(await transfer.ends(before: .now + .seconds(5)))
            transfer.cancel()
            await #expect(throws: CancellationError.self) { try await transfer.value }
            #expect(isPending(services.pasteboard) && source.followers == 0)
        }
        let connected = RecordFixture()
        connected.connected = true
        connected.features = ["pasteboard"]
        let failure = DeviceIOError.temporary("fixture-read", "CoreDevice did not answer.")
        // While the source finds no record, one that is not connected, one that answers, or fails.
        for result in [.success(nil), .success(RecordFixture()), .success(connected), .failure(failure)] as [Result<RecordFixture?, any Error>] {
            let reads = HeldCalls<RecordFixture?>()
            let source = RecordSourceFixture()
            source.heldReads = reads
            try await stopping(source, isHeld: { reads.isHolding }, then: { reads.finish(result) })
        }
        // While the record says whether it is connected.
        for isConnected in [false, true] {
            let connection = HeldCalls<Bool>()
            let record = RecordFixture()
            record.features = ["pasteboard"]
            record.heldConnection = connection
            let source = RecordSourceFixture()
            source.current = record
            try await stopping(source, isHeld: { connection.isHolding }, then: { connection.finish(.success(isConnected)) })
        }
    }

    /// A screen that cannot exist without the record waits for it in any state, and a record that does not come is a failure.
    @Test(.timeLimit(.minutes(1)))
    func aScreenThatNeedsTheRecordWaitsForItUntilItsLimit() async throws {
        let source = RecordSourceFixture()
        let discovery = CoreDeviceRecordDiscovery(source: source)
        let waiting = Task.immediate { try await discovery.record(limit: .seconds(30)) }
        try await wait { source.followers == 1 }
        let record = RecordFixture()
        source.current = record
        source.change()
        #expect(try await waiting.value === record)
        try await wait { source.followers == 0 }

        source.current = nil
        await #expect(throws: DeviceIOError.self) { _ = try await discovery.record(limit: .milliseconds(20)) }
        try await wait { source.followers == 0 }
    }

    @Test func serviceStatusSaysWhatTheServicesSay() {
        let failure = DeviceIOError.temporary("fixture", "It did not answer.")
        #expect(DeviceServiceStatus(input: .notRouted, pasteboard: .notRouted) == nil)
        #expect(DeviceServiceStatus(input: .ready, pasteboard: .ready) == nil)
        #expect(DeviceServiceStatus(input: .unsupported, pasteboard: .unsupported) == nil)
        // Only a transfer waits for the pasteboard, so its connecting costs nothing yet.
        #expect(DeviceServiceStatus(input: .ready, pasteboard: .pending) == nil)
        // A wait for CoreDevice's word about the device can last, so it shows even when only a transfer waits.
        #expect(DeviceServiceStatus(input: .ready, pasteboard: .pending, isAwaitingDeviceRecord: true)?.message.contains("CoreDevice") == true)
        #expect(DeviceServiceStatus(input: .pending, pasteboard: .ready)?.action == nil)
        // Connecting again would wait for the same boot, so a wait for the boot, or its unfinished end, offers a restart.
        let starting = DeviceServiceStatus(input: .pending, pasteboard: .ready, startup: .starting("waiting for backboardd"))
        #expect(starting?.action == .restart && starting?.message.contains("waiting for backboardd") == true)
        #expect(DeviceServiceStatus(input: .failed(failure), pasteboard: .ready, startup: .unfinished)?.action == .restart)
        let input = DeviceServiceStatus(input: .failed(failure), pasteboard: .failed(failure))
        #expect(input?.action == .retry && input?.message.contains("It did not answer.") == true)
        let pasteboard = DeviceServiceStatus(input: .ready, pasteboard: .failed(failure))
        #expect(pasteboard?.action == nil && pasteboard?.message.contains("pasteboard") == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func serviceStatusChangesNothingOfTheScreensGeometry() async throws {
        let display = TestDisplay()
        let controller = try makeController(display)
        defer { controller.close() }
        controller.showCompactWindow()
        let window = try #require(controller.window)
        window.layoutIfNeeded()
        let (frame, windowFrame) = (display.view.frame, window.frame)
        let services = controller.session.optionalServices
        var retries = 0
        services.onRetryInput = { retries += 1 }

        services.setInput(.pending)
        try await wait { controller.serviceStatus != nil && controller.serviceStatus?.action == nil }
        window.layoutIfNeeded()
        #expect(display.view.frame == frame && window.frame == windowFrame)

        services.setInput(.failed(DeviceIOError.temporary("fixture", "It did not answer.")))
        try await wait { controller.serviceStatus?.action == .retry }
        window.layoutIfNeeded()
        #expect(display.view.frame == frame && window.frame == windowFrame)
        services.retryInput()
        #expect(retries == 1)

        services.setInput(.ready)
        try await wait { controller.serviceStatus == nil }
        window.layoutIfNeeded()
        #expect(display.view.frame == frame && window.frame == windowFrame)
    }

    /// The screen beneath keeps its input: only Retry takes events.
    @Test func serviceStatusPassesEventsThroughExceptRetry() throws {
        var retries = 0
        let view = DeviceServiceStatusView { _ in retries += 1 }
        view.show(try #require(DeviceServiceStatus(input: .failed(DeviceIOError.temporary("fixture", "Failed.")), pasteboard: .ready)))
        view.frame = NSRect(origin: .zero, size: view.size(fitting: 420))
        view.layoutSubtreeIfNeeded()
        let hitViews = stride(from: CGFloat(0.5), to: view.bounds.width, by: 4).compactMap {
            view.hitTest(NSPoint(x: $0, y: view.bounds.midY))
        }
        let button = try #require(hitViews.first as? NSButton)
        #expect(hitViews.allSatisfy { $0 === button })
        button.performClick(nil)
        #expect(retries == 1)
    }

    @Test func displaysAreFoundWithoutBeingKeptAlive() {
        let displays = SimulatorDisplaySet()
        var display: TestDisplay? = TestDisplay()
        weak let released = display
        displays.register(display!)
        #expect(displays.full(for: display!) === display)
        display = nil
        #expect(released == nil)
    }

    @Test func windowImportInvalidatesTheSharedApplicationsEvenWhenTheBatchFails() async throws {
        let source = ManagerModelSource(devices: [], inspectorResponse: "{}")
        let model = DeviceModel(inventory: .simulator(SimulatorHostDevice(identifier: "test-device", name: "Test iPhone", descriptiveName: "Test iPhone",
            runtimeIdentifier: "runtime", runtimeName: "iOS", productFamily: "iPhone", state: "Booted")), source: source)
        let session = try makeSession(TestDisplay(), simctl: URL(fileURLWithPath: "/usr/bin/true"), model: model)
        let interest = model.keepCurrent(.applications)
        defer { interest.release() }
        await model.finishReading()
        #expect(await source.inspectorCommands.count == 1)
        try await session.importFiles([URL(fileURLWithPath: "/tmp/Photo.png")])
        await model.finishReading()
        #expect(await source.inspectorCommands.count == 1)
        await #expect(throws: (any Error).self) {
            try await session.importFiles([URL(fileURLWithPath: "/tmp/App.app"), URL(fileURLWithPath: "/tmp/Unsupported.txt")])
        }
        await model.finishReading()
        #expect(await source.inspectorCommands.count == 2)
    }
}
