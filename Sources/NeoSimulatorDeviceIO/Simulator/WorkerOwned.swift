import Foundation

/// A native object that its device's worker creates and releases, since CoreSimulator's own teardown of it can wait on
/// the device as its creation does. Whatever holds the last use of it releases it through ``release(on:)``.
package final class WorkerOwned<Value: AnyObject>: @unchecked Sendable {
    private var object: Value?

    package init(_ object: Value) { self.object = object }

    package var value: Value { object! }

    /// For a late result that the worker itself is finishing.
    package func releaseNow() { object = nil }

    /// Nothing else may use it after this call.
    package func release(on channel: SimulatorDeviceChannel) {
        channel.cleanUp("release a native connection") { self.releaseNow() }
    }
}
