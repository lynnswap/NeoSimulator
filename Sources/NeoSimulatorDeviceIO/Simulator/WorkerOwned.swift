import Darwin
import Foundation
import Synchronization

/// A native object that its device's worker creates and releases, since CoreSimulator's own teardown of it can wait on
/// the device as its creation does. Dropping the last reference, from anywhere, leaves its release to the worker, so a
/// result that nobody waits for any more or a connection that fails halfway needs nothing further.
package final class WorkerOwned<Value: AnyObject>: @unchecked Sendable {
    private var object: Value?
    private let channel: SimulatorDeviceChannel

    package init(_ object: Value, channel: SimulatorDeviceChannel) {
        self.object = object
        self.channel = channel
    }

    package var value: Value { object! }

    deinit {
        // Nothing else may keep it once the worker has been asked, or the worker's release would not be the last.
        nonisolated(unsafe) var last = object
        object = nil
        channel.cleanUp("release a native connection") { last = nil }
    }
}

/// A Mach send right with one owner at a time. A channel request that captures this owns the right from when it is
/// made: its body takes the right for what consumes it, and a request that never runs releases it along with itself.
package final class OwnedSendRight: Sendable {
    private let name: Mutex<UInt32?>

    package init(_ name: UInt32) { self.name = Mutex(name) }

    /// The right, which the caller then owns. There is one to take.
    package func take() -> UInt32 { name.withLock { $0.take()! } }

    deinit {
        if let name = name.withLock({ $0.take() }) { mach_port_deallocate(mach_task_self_, name) }
    }
}
