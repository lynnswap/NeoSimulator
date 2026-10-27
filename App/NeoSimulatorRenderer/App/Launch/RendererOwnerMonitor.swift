import AppKit
import Darwin
import Synchronization
@_spi(NeoSimulator) import XcodeSimulatorHost

/// The deadline runs independently of AppKit, including while native display code blocks its run loop.
final class RendererOwnerMonitor: Sendable {
    typealias Cancellation = @Sendable () -> Void
    typealias ObserveExit = @Sendable (Int32, @escaping @Sendable () -> Void) -> Cancellation
    typealias ScheduleDeadline = @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Cancellation
    private struct State {
        var ownerExited = false
        var stopped = false
        var cancelObservation: Cancellation?
        var cancelDeadline: Cancellation?
    }
    private let state = Mutex(State())
    private let schedule: ScheduleDeadline
    private let forceExit: @Sendable () -> Void
    private let cleanup: @Sendable () -> Void

    init(processIdentifier: Int32, cleanup: @escaping @Sendable () -> Void,
         observeExit: ObserveExit = RendererOwnerMonitor.observeProcess,
         scheduleDeadline: @escaping ScheduleDeadline = RendererOwnerMonitor.scheduleDeadline,
         forceExit: @escaping @Sendable () -> Void = { _exit(EX_TEMPFAIL) }) {
        self.schedule = scheduleDeadline
        self.forceExit = forceExit
        self.cleanup = cleanup
        let cancel = observeExit(processIdentifier) { [weak self] in self?.ownerDidExit() }
        let stopped = state.withLock { value in
            if value.stopped { return true }
            value.cancelObservation = cancel
            return false
        }
        if stopped { cancel() }
    }

    private func ownerDidExit() {
        let beginsCleanup = state.withLock { value in
            guard !value.stopped, !value.ownerExited else { return false }
            value.ownerExited = true
            return true
        }
        guard beginsCleanup else { return }
        let cancel = schedule(60) { [weak self] in
            guard let self, self.state.withLock({ !$0.stopped && $0.ownerExited }) else { return }
            self.forceExit()
        }
        let stopped = state.withLock { value in
            if value.stopped { return true }
            value.cancelDeadline = cancel
            return false
        }
        if stopped { cancel(); return }
        cleanup()
    }

    func stop() {
        let cancellations = state.withLock { value -> [Cancellation] in
            value.stopped = true
            let result = [value.cancelObservation, value.cancelDeadline].compactMap { $0 }
            value.cancelObservation = nil
            value.cancelDeadline = nil
            return result
        }
        for cancel in cancellations { cancel() }
    }

    deinit { stop() }

    private static func observeProcess(_ pid: Int32, exited: @escaping @Sendable () -> Void) -> Cancellation {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler(handler: exited)
        source.activate()
        return { source.cancel() }
    }

    private static func scheduleDeadline(_ seconds: TimeInterval, expired: @escaping @Sendable () -> Void) -> Cancellation {
        let source = DispatchSource.makeTimerSource(queue: .global())
        source.schedule(deadline: .now() + seconds)
        source.setEventHandler(handler: expired)
        source.activate()
        return { source.cancel() }
    }
}
