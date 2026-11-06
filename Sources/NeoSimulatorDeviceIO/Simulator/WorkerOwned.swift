import Darwin
import Foundation
import Synchronization

/// Creates and releases a native object on its device worker because both operations can block.
/// Dropping the last reference from any queue schedules release on that worker.
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

/// An exclusively owned Mach send right. A request retains it until its body transfers
/// ownership or the unexecuted request is released.
package final class OwnedSendRight: Sendable {
    private let name: Mutex<UInt32?>

    package init(_ name: UInt32) { self.name = Mutex(name) }

    /// The right, which the caller then owns. There is one to take.
    package func take() -> UInt32 { name.withLock { $0.take()! } }

    deinit {
        if let name = name.withLock({ $0.take() }) { mach_port_deallocate(mach_task_self_, name) }
    }
}
