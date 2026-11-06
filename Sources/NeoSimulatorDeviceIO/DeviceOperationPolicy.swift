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
    /// A preference transaction, management step or inspector change, which must finish so it can report or roll back
    /// what it did. Only quitting stops it, after waiting for it: see ``UninterruptedCommands``.
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
    /// How long a device's channel waits for one native call before it stops answering for the device.
    /// The call itself keeps running; see ``SimulatorDeviceChannel``.
    package static let bridge: Duration = .seconds(10)
    /// How long a device set's channel waits for one CoreSimulator call. Opening the first set of a process can start its
    /// service, and reading a set captures every device in it. The call itself keeps running.
    package static let deviceSet: Duration = .seconds(30)
    /// How long a caller waits for CoreDevice's full initialization, after which it is told so and the delay is shown.
    /// The one initialization keeps running, and whoever asks later waits on it again; see ``SharedTask``.
    package static let coreDeviceInitialization: Duration = .seconds(60)
    /// How long opening a screen that cannot exist without its simulator's CoreDevice record waits for the record.
    package static let coreDeviceRecord: Duration = .seconds(60)
    /// How long a guest service may take to create a HID service or send what a connection accepted.
    /// Closing the connection on the limit also ends what it created in the guest.
    package static let guestService: Duration = .seconds(10)
    /// How long a request for an iCloud sync waits for CoreSimulator's completion, as long as a management operation.
    package static let cloudSync: Duration = .seconds(300)
    /// How long a command stopped by quitting may handle SIGTERM, and how long what it was part of then has to finish.
    package static let terminationStopGrace: Duration = .seconds(2)
    package static let terminationGrace: Duration = .seconds(10)
}
