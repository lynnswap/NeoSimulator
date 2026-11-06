import ABIBridge
import AppKit
import Dispatch
import Foundation
import NeoSimulatorDeviceIO
import NeoSimulatorKit
import Synchronization
import Testing

/// Who owns what a native connection is made from and made into, on a real channel, with real Mach rights and through
/// real Objective-C dispatch. The worker blocks where a native call would.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct NativeConnectionOwnershipTests {
    private let identifier = UUID().uuidString
    private var workerLabel: String { "dev.lynnswap.NeoSimulator.device-worker.\(identifier)" }

    private func makeChannel() -> SimulatorDeviceChannel {
        SimulatorDeviceChannel(scope: .device(DeviceAddress(identifier: identifier, deviceSetPath: nil)))
    }

    private func makeInterface() async throws -> SimulatorPasteboardInterface {
        try await SimulatorPasteboardInterface(runtime: ABIRuntime.shared, interfaceClass: FakePasteboardInterface.self,
                                               listenerClass: FakePasteboardListener.self)
    }

    private func connect(_ right: TestRight, _ interface: SimulatorPasteboardInterface,
                         on channel: SimulatorDeviceChannel) async throws -> SimulatorPasteboardConnection {
        try await interface.connect(OwnedSendRight(right.name), on: channel, managing: .general, events: { _ in })
    }

    private func state(of channel: SimulatorDeviceChannel) async -> [UnresolvedDeviceOperation.State] {
        await channel.unresolvedOperations().map(\.state)
    }

    @Test func aConnectionStoppedBeforeTheWorkerReachesItLeavesTheRightToItsInitializer() async throws {
        let channel = makeChannel()
        let interface = try await makeInterface()
        let right = try TestRight()
        let call = Hold(), itemEnd = Hold()
        defer { call.release(); itemEnd.release() }
        let holding = Task {
            try await channel.read("hold") {
                // Goes when the worker's work item ends, by when the channel has been told that this returned.
                _ = Unmanaged.passRetained(BlocksWhenReleased(itemEnd)).autorelease()
                call.pass()
            }
        }
        try await waitUntil { call.isEntered }
        let connecting = Task.immediate { try await connect(right, interface, on: channel) }
        try await waitUntil { await state(of: channel) == [.running, .waiting] }

        // The channel has started the connection, whose work item cannot begin until the worker's current one ends.
        call.release()
        try await holding.value
        try await waitUntil { await state(of: channel) == [.running] }
        try await waitUntil { itemEnd.isEntered }
        #expect(right.connection == nil)
        connecting.cancel()
        await #expect(throws: CancellationError.self) { try await connecting.value }
        #expect(right.sendReferences == 1)

        itemEnd.release()
        try await waitUntil { right.connection?.releasedOn != nil }
        #expect(right.connection?.sendReferencesOnArrival == 1)
        #expect(right.connection?.deallocation == KERN_SUCCESS)
        #expect(right.sendReferences == 0)
    }

    @Test func aConnectionThatWasRefusedReleasesItsRightAndMakesNothing() async throws {
        let channel = makeChannel()
        let interface = try await makeInterface()
        let right = try TestRight()
        let call = Hold()
        defer { call.release() }
        await #expect(throws: DeviceOperationFailure.noAnswer(operation: "hold", limit: .milliseconds(20))) {
            try await channel.read("hold", limit: .milliseconds(20)) { call.pass() }
        }
        await #expect(throws: DeviceOperationFailure.notSent(operation: "connect the device's pasteboard", heldBy: "hold")) {
            try await connect(right, interface, on: channel)
        }
        try await waitUntil { right.sendReferences == 0 }
        call.release()
        try await waitUntil { await channel.currentHealth == .ready }
        #expect(right.connection == nil)
        #expect(right.deallocateAgain() == KERN_INVALID_RIGHT)
        #expect(FakePasteboardInterface.connections.withLock { $0.uninitializedReleases } == 0)
    }

    @Test func aConnectionCancelledInTheQueueReleasesItsRightAndMakesNothing() async throws {
        let channel = makeChannel()
        let interface = try await makeInterface()
        let right = try TestRight()
        let call = Hold()
        defer { call.release() }
        let holding = Task { try await channel.read("hold") { call.pass() } }
        try await waitUntil { call.isEntered }
        let connecting = Task.immediate { try await connect(right, interface, on: channel) }
        try await waitUntil { await state(of: channel) == [.running, .waiting] }
        connecting.cancel()
        await #expect(throws: CancellationError.self) { try await connecting.value }
        try await waitUntil { right.sendReferences == 0 }
        call.release()
        try await holding.value
        try await waitUntil { await state(of: channel).isEmpty }
        #expect(right.connection == nil)
        #expect(right.deallocateAgain() == KERN_INVALID_RIGHT)
        #expect(FakePasteboardInterface.connections.withLock { $0.uninitializedReleases } == 0)
    }

    @Test func aConnectionThatReturnsAfterItsCallerStoppedWaitingIsReleasedOnTheWorker() async throws {
        let channel = makeChannel()
        let interface = try await makeInterface()
        let right = try TestRight()
        let initializer = Hold()
        defer { initializer.release() }
        right.holdInitializer(initializer)
        let connecting = Task.immediate { try await connect(right, interface, on: channel) }
        try await waitUntil { initializer.isEntered }
        connecting.cancel()
        await #expect(throws: CancellationError.self) { try await connecting.value }
        #expect(right.sendReferences == 1)

        initializer.release()
        try await waitUntil { right.connection?.releasedOn != nil }
        #expect(right.connection?.releasedOn == workerLabel)
        #expect(right.connection?.deallocation == KERN_SUCCESS)
        #expect(right.sendReferences == 0)
        try await waitUntil { await state(of: channel).isEmpty }
    }

    @Test func aConnectionSendsThroughItsInterfaceAndIsReleasedOnTheWorkerWhenDropped() async throws {
        let channel = makeChannel()
        let interface = try await makeInterface()
        let right = try TestRight()
        var connection: SimulatorPasteboardConnection? = try await connect(right, interface, on: channel)
        try await connection?.push()
        try await connection?.pull()
        #expect(right.connection?.transfers == ["push", "pull"])
        #expect(right.connection?.releasedOn == nil)
        connection = nil
        try await waitUntil { right.connection?.releasedOn != nil }
        #expect(right.connection?.releasedOn == workerLabel)
    }

    @Test func droppingAWorkerOwnedObjectWaitsForNothingAndReleasesItOnTheWorker() async throws {
        let channel = makeChannel()
        let call = Hold()
        defer { call.release() }
        await #expect(throws: DeviceOperationFailure.noAnswer(operation: "hold", limit: .milliseconds(20))) {
            try await channel.read("hold", limit: .milliseconds(20)) { call.pass() }
        }
        let released = Mutex<String?>(nil)
        var owned: WorkerOwned<RecordsItsRelease>? = WorkerOwned(RecordsItsRelease { label in
            released.withLock { $0 = label }
        }, channel: channel)
        #expect(owned?.value != nil)

        // This goes on while the worker is held, and the release is on record for a quit to report.
        owned = nil
        try await waitUntil {
            await channel.unresolvedOperations().map(\.operation) == ["hold", "release a native connection"]
        }
        #expect(released.withLock { $0 } == nil)
        call.release()
        try await waitUntil { released.withLock { $0 } != nil }
        #expect(released.withLock { $0 } == workerLabel)
    }
}

private func waitUntil(sourceLocation: SourceLocation = #_sourceLocation,
                       _ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while await !condition() {
        try #require(ContinuousClock.now < deadline, "The expected state did not arrive.", sourceLocation: sourceLocation)
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func currentQueueLabel() -> String { String(cString: __dispatch_queue_get_label(nil)) }

/// Blocks whoever passes it until `release()`, as a native call blocks.
private final class Hold: Sendable {
    private let released = DispatchSemaphore(value: 0)
    private let entered = Mutex(false)

    var isEntered: Bool { entered.withLock { $0 } }

    func pass() {
        entered.withLock { $0 = true }
        released.wait()
        released.signal()
    }

    func release() { released.signal() }
}

private final class BlocksWhenReleased: NSObject {
    private let hold: Hold

    init(_ hold: Hold) { self.hold = hold }

    deinit { hold.pass() }
}

private final class RecordsItsRelease {
    private let record: @Sendable (String) -> Void

    init(_ record: @escaping @Sendable (String) -> Void) { self.record = record }

    deinit { record(currentQueueLabel()) }
}

/// A real send right. It keeps the port's receive right as well, so that the name stays this port's after the send right
/// goes, where a right that was freed too soon then fails rather than meaning something else.
private final class TestRight: Sendable {
    let name: UInt32

    init() throws {
        var name: mach_port_t = 0
        try #require(mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &name) == KERN_SUCCESS)
        try #require(mach_port_insert_right(mach_task_self_, name, name, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS)
        self.name = name
    }

    deinit {
        FakePasteboardInterface.connections.withLock { $0.byName[name] = nil; $0.holds[name] = nil }
        mach_port_mod_refs(mach_task_self_, name, MACH_PORT_RIGHT_RECEIVE, -1)
    }

    var sendReferences: mach_port_urefs_t { FakePasteboardInterface.sendReferences(of: name) }

    var connection: FakePasteboardInterface.Connection? { FakePasteboardInterface.connections.withLock { $0.byName[name] } }

    func holdInitializer(_ hold: Hold) { FakePasteboardInterface.connections.withLock { $0.holds[name] = hold } }

    func deallocateAgain() -> kern_return_t { mach_port_deallocate(mach_task_self_, name) }
}

/// What SimPasteboardPlus's interface does with what it connects to: its initializer consumes the right, on whichever
/// thread sends it, and its teardown is what the worker has to be the one to run.
private final class FakePasteboardInterface: NSObject {
    struct Connection {
        let sendReferencesOnArrival: mach_port_urefs_t
        let deallocation: kern_return_t
        var transfers: [String] = []
        var releasedOn: String?
    }

    struct Connections {
        var byName: [UInt32: Connection] = [:]
        var holds: [UInt32: Hold] = [:]
        /// Instances that were allocated and disposed of without being initialized.
        var uninitializedReleases = 0
    }

    static let connections = Mutex(Connections())
    private let port: UInt32

    static func sendReferences(of name: UInt32) -> mach_port_urefs_t {
        var references: mach_port_urefs_t = 0
        guard mach_port_get_refs(mach_task_self_, name, MACH_PORT_RIGHT_SEND, &references) == KERN_SUCCESS else { return 0 }
        return references
    }

    @objc(initWithConnectingToPort:managingPasteboard:delegate:delegateQueue:)
    init(port: UInt32, pasteboard: NSPasteboard, delegate: AnyObject?, queue: DispatchQueue?) {
        self.port = port
        super.init()
        Self.connections.withLock { $0.holds[port] }?.pass()
        let references = Self.sendReferences(of: port)
        let deallocation = mach_port_deallocate(mach_task_self_, port)
        Self.connections.withLock {
            $0.byName[port] = Connection(sendReferencesOnArrival: references, deallocation: deallocation)
        }
    }

    deinit {
        let label = currentQueueLabel()
        Self.connections.withLock {
            if port == 0 { $0.uninitializedReleases += 1 } else { $0.byName[port]?.releasedOn = label }
        }
    }

    private func record(_ transfer: String) {
        Self.connections.withLock { $0.byName[port]?.transfers.append(transfer) }
    }

    @objc func push() { record("push") }
    @objc func pull() { record("pull") }
    @objc func enableRemoteAutosync() {}
    @objc func disableRemoteAutosync() {}
}

private final class FakePasteboardListener: NSObject {
    @objc class var machServiceName: String { "dev.lynnswap.NeoSimulatorTests.pasteboard" }
}
