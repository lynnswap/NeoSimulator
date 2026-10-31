import AppKit
@_spi(NeoSimulator) import XcodeSimulatorHost

/// A device's CoreDevice pasteboard connection. Transfers run one at a time in the order they were requested or
/// observed. A queued automatic send yields to a change that the connection observes later, and a device copy's
/// write to a later copy from any device or a later Mac change. Requested transfers report the events
/// SimPasteboardPlus reports, and automatic ones their own, so that a requested transfer queued behind an automatic
/// one, as after synchronization turns off, keeps its own result.
@MainActor
final class NativePasteboardConnection: SimulatorPasteboard {
    private let transport: any PasteboardTransport
    private let pasteboard: NSPasteboard
    /// Orders the device copies that every device's connection observes. A session without it does not synchronize
    /// automatically, so no device copy waits for it.
    private weak var sync: PasteboardSync?
    private var events: ((SimulatorPasteboardEvent) -> Void)?
    /// The last transfer queued, which the next one waits for.
    private var transfers: Task<Void, Never>?
    /// The device's and the Mac's pasteboard observations while synchronizing automatically.
    private var observations: [Task<Void, Never>] = []
    /// Changes whenever synchronization turns off or fails, so that the automatic transfers queued before then no
    /// longer run.
    private var synchronization = 0
    /// Counts the changes that the observations reported, so that the automatic sends queued before a change no
    /// longer run. One would carry an older Mac pasteboard over the change, and as neither observation reports a
    /// transferred pasteboard, the two pasteboards would stay different.
    private var observedChanges = 0

    /// A device copy waiting to replace the Mac pasteboard.
    private struct DeviceCopy {
        /// The synchronization during which the copy was observed.
        let synchronization: Int
        /// The copy's place among the device copies that the app's connections observed.
        let number: Int
        /// The Mac pasteboard's change count when the copy was observed.
        let generation: Int
    }

    init(transport: any PasteboardTransport, managing pasteboard: NSPasteboard, sync: PasteboardSync?,
         events: @escaping @MainActor (SimulatorPasteboardEvent) -> Void) {
        self.transport = transport
        self.pasteboard = pasteboard
        self.sync = sync
        self.events = events
        // DeviceSession counts the first activation as the connection's own and each later one as a completed push.
        enqueue { .activated }
    }

    isolated deinit {
        for observation in observations { observation.cancel() }
    }

    func pull() {
        enqueue { [transport, pasteboard] in
            do {
                let generation = try await transport.read(into: pasteboard)
                return .applied(generation: generation)
            } catch { return .failedToApply(error) }
        }
    }

    func push() {
        enqueue { [transport, pasteboard] in
            do { try await transport.send(pasteboard); return .activated }
            catch { return .failedToSend(error) }
        }
    }

    func pushAutomatically() {
        // Sending the Mac pasteboard is no change of its own: a device copy observed before it already gives way to
        // the Mac change it sends, which changed the Mac pasteboard's count.
        enqueueSend(during: synchronization) { [transport, pasteboard] in
            do { try await transport.send(pasteboard); return nil }
            catch { return .automaticTransferFailed(.send, error) }
        }
    }

    func setAutomaticSync(_ enabled: Bool) {
        guard enabled else { return stopObserving() }
        guard observations.isEmpty else { return }
        let (transport, pasteboard, current) = (transport, pasteboard, synchronization)
        observations = [
            observe { [weak self] in
                try await transport.observeDeviceChanges(into: pasteboard) { write in
                    self?.deviceDidChange(write, during: current)
                }
            },
            observe { [weak self] in
                try await transport.observeChanges(of: pasteboard) { send in
                    self?.macDidChange(send, during: current)
                }
            },
        ]
    }

    func disconnect() {
        events = nil
        stopObserving()
    }

    /// Ends both observations. The automatic transfers queued so far that have not started no longer run.
    private func stopObserving() {
        synchronization += 1
        for observation in observations { observation.cancel() }
        observations = []
    }

    /// Queues the write of the device's copy, which replaces the Mac pasteboard only while the copy may replace it,
    /// and reports nothing otherwise.
    private func deviceDidChange(_ write: @escaping @MainActor (_ shouldReplace: @escaping @MainActor () -> Bool) async throws -> Int?,
                                 during synchronization: Int) {
        guard let sync, countChange(during: synchronization) else { return }
        let copy = DeviceCopy(synchronization: synchronization, number: sync.observeDeviceCopy(), generation: pasteboard.changeCount)
        enqueue { [weak self] in
            let mayReplace: @MainActor () -> Bool = { self?.mayReplaceMac(with: copy) == true }
            guard mayReplace() else { return nil }
            do {
                guard let generation = try await write(mayReplace) else { return nil }
                return .appliedAutomatically(generation: generation)
            } catch { return .automaticTransferFailed(.get, error) }
        }
    }

    private func macDidChange(_ send: @escaping @MainActor () async throws -> Void, during synchronization: Int) {
        guard countChange(during: synchronization) else { return }
        enqueueSend(during: synchronization) {
            do { try await send(); return nil }
            catch { return .automaticTransferFailed(.send, error) }
        }
    }

    /// Counts an observed change, unless observations that have since stopped reported it: such a change no longer
    /// transfers, nor stops the automatic sends queued before it.
    private func countChange(during synchronization: Int) -> Bool {
        guard self.synchronization == synchronization else { return false }
        observedChanges += 1
        return true
    }

    /// Whether a device copy may still replace the Mac pasteboard. Changes that this connection observed later do
    /// not decide it: a late report of a Mac copy that the Mac pasteboard held before the device copy leaves its count
    /// as it was, and replacing it keeps the device copy on both pasteboards.
    private func mayReplaceMac(with copy: DeviceCopy) -> Bool {
        // Synchronization stopped.
        guard synchronization == copy.synchronization else { return false }
        // A device copy was observed later, on this device or another.
        guard sync?.isLatestDeviceCopy(copy.number) == true else { return false }
        // The Mac pasteboard changed. A Mac copy changes the count at once, but its observation reports it only later.
        return pasteboard.changeCount == copy.generation
    }

    /// Runs `transfer` after the transfers queued before it, and reports its event while the connection is connected.
    private func enqueue(_ transfer: @escaping @MainActor () async -> SimulatorPasteboardEvent?) {
        let previous = transfers
        transfers = Task { [weak self] in
            await previous?.value
            guard self?.events != nil else { return }
            if let event = await transfer() { self?.events?(event) }
        }
    }

    /// Queues an automatic send, which does not run if synchronization turns off or fails, or an observation reports
    /// a change, before it starts.
    private func enqueueSend(during synchronization: Int, _ transfer: @escaping @MainActor () async -> SimulatorPasteboardEvent?) {
        let change = observedChanges
        enqueue { [weak self] in
            guard self?.synchronization == synchronization, self?.observedChanges == change else { return nil }
            return await transfer()
        }
    }

    /// Runs an observation until the observations stop. An observation that fails or ends first stops both, and
    /// they start again only when synchronization is turned on again, so that an observation that keeps failing does
    /// not restart in a loop.
    private func observe(_ observation: @escaping @MainActor () async throws -> Void) -> Task<Void, Never> {
        let current = synchronization
        return Task { [weak self] in
            let failure: any Error
            do {
                try await observation()
                failure = HostError.operation("The simulator stopped reporting pasteboard changes.")
            } catch is CancellationError {
                return
            } catch {
                failure = error
            }
            guard let self, self.synchronization == current else { return }
            self.stopObserving()
            self.events?(.synchronizationFailed(failure))
        }
    }
}
