import AppKit
@_spi(NeoSimulator) import XcodeSimulatorHost

/// A device's CoreDevice pasteboard connection. Transfers run one at a time in the order they were requested or
/// observed, and report the events SimPasteboardPlus reports.
@MainActor
final class NativePasteboardConnection: SimulatorPasteboard {
    private let transport: any PasteboardTransport
    private let pasteboard: NSPasteboard
    private var events: ((SimulatorPasteboardEvent) -> Void)?
    /// The last transfer queued, which the next one waits for.
    private var transfers: Task<Void, Never>?
    /// The device's and the Mac's pasteboard observations while synchronizing automatically.
    private var observations: [Task<Void, Never>] = []
    /// Changes whenever the observations stop, so that the changes they reported no longer transfer.
    private var synchronization = 0

    init(transport: any PasteboardTransport, managing pasteboard: NSPasteboard,
         events: @escaping @MainActor (SimulatorPasteboardEvent) -> Void) {
        self.transport = transport
        self.pasteboard = pasteboard
        self.events = events
        // DeviceSession counts the first activation as the connection's own and each later one as a completed push.
        enqueue { .activated }
    }

    isolated deinit {
        for observation in observations { observation.cancel() }
    }

    func pull() {
        enqueue { [transport, pasteboard] in
            do { return .applied(generation: try await transport.read(into: pasteboard)) }
            catch { return .failedToApply(error) }
        }
    }

    func push() {
        enqueue { [transport, pasteboard] in
            do { try await transport.send(pasteboard); return .activated }
            catch { return .failedToSend(error) }
        }
    }

    func setAutomaticSync(_ enabled: Bool) {
        guard enabled == observations.isEmpty else { return }
        stopObserving()
        guard enabled else { return }
        let (transport, pasteboard, current) = (transport, pasteboard, synchronization)
        observations = [
            observe { [weak self] in
                try await transport.observeDeviceChanges(into: pasteboard) { write in
                    self?.enqueue(during: current) {
                        do { return .applied(generation: try await write()) }
                        catch { return .failedToApply(error) }
                    }
                }
            },
            observe { [weak self] in
                try await transport.observeChanges(of: pasteboard) { send in
                    self?.enqueue(during: current) {
                        do { try await send(); return nil }
                        catch { return .failedToSend(error) }
                    }
                }
            },
        ]
    }

    func disconnect() {
        events = nil
        stopObserving()
    }

    /// Ends both observations. The changes they reported that have not started transferring no longer transfer.
    private func stopObserving() {
        synchronization += 1
        for observation in observations { observation.cancel() }
        observations = []
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

    /// Queues an observed change, which no longer transfers once the observations that reported it stop.
    private func enqueue(during synchronization: Int, _ transfer: @escaping @MainActor () async -> SimulatorPasteboardEvent?) {
        enqueue { [weak self] in
            guard self?.synchronization == synchronization else { return nil }
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
