import Foundation

/// What may stop a command before it exits on its own.
package struct CommandPolicy: Equatable, Sendable {
    package enum Cancellation: Equatable, Sendable {
        /// The child keeps running and the caller keeps waiting, so the result reports what actually happened.
        case waitsForChild
        /// The child is stopped. See ``CommandFailure/Interruption`` for what the caller is told.
        case stopsChild
    }

    /// Nil lets the command run until it exits or its caller stops it.
    package let limit: Duration?
    package let cancellation: Cancellation
    /// How long a stopped child may handle SIGTERM before SIGKILL. Nil sends SIGKILL at once.
    package let stopGrace: Duration?

    package init(limit: Duration?, cancellation: Cancellation, stopGrace: Duration?) {
        self.limit = limit
        self.cancellation = cancellation
        self.stopGrace = stopGrace
    }
}

/// Every operation's limits, in one place. None of them is a universal limit: an operation that
/// lists no limit may legitimately run for a long time.
extension CommandPolicy {
    /// A preference transaction, management step or inspector command, which must finish so it can report or roll back what it did.
    package static let uninterrupted = CommandPolicy(limit: nil, cancellation: .waitsForChild, stopGrace: nil)
    /// A read, or another command its caller may abandon at any point; only the owned child is killed.
    package static let cancellable = CommandPolicy(limit: nil, cancellation: .stopsChild, stopGrace: nil)
    /// A device command from an open session.
    package static let deviceTool = CommandPolicy(limit: .seconds(30), cancellation: .stopsChild, stopGrace: .seconds(2))
    /// Booting can migrate data first, and erasing removes the whole device.
    package static let deviceLifecycleTool = CommandPolicy(limit: .seconds(300), cancellation: .stopsChild, stopGrace: .seconds(2))
    /// One launchctl call. launchd_sim can stop answering around a boot, and reads retry after this limit.
    package static let backgroundServiceCommand = CommandPolicy(limit: .seconds(120), cancellation: .stopsChild, stopGrace: nil)
}

/// Limits enforced outside ``CommandPolicy``: by devicectl itself, or by a recording that owns its process.
package enum DeviceOperationLimit {
    /// devicectl's `--timeout` for inventory and settings reads, in seconds.
    package static let devicectlQuery = 10
    /// devicectl's `--timeout` for inspector results, in seconds.
    package static let devicectlInspection = 30
    /// devicectl's `--timeout` for management operations, in seconds.
    package static let devicectlManagement = 300
    package static let recordingStart: Duration = .seconds(30)
    package static let recordingFinish: Duration = .seconds(30)
    package static let recordingStopGrace: Duration = .seconds(2)
}
