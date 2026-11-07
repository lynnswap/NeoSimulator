import AppKit
import NeoSimulatorHostSupport
import NeoSimulatorKit
import NeoSimulatorPresentationAdapters
import NeoSimulatorDeviceIO

/// Keeps only small frozen images for rows which are not receiving live frames.
@MainActor
final class DeviceThumbnailStore {
    typealias Connect = @MainActor (SimulatorHostDevice, @escaping (DeviceThumbnailFrame?) -> Void,
                         @escaping (any Error) -> Void) async throws -> any DeviceThumbnailSource

    private final class Entry {
        let device: SimulatorHostDevice
        var active = false
        var generation = 0
        var source: (any DeviceThumbnailSource)?
        var receiving: Task<Void, Never>?
        var freezing: Task<Void, Never>?
        var frame: DeviceThumbnailFrame?
        var image: CGImage?
        init(_ device: SimulatorHostDevice) { self.device = device }
    }

    private let connect: Connect
    private let waitToRetry: @MainActor (Duration) async throws -> Void
    private var entries: [DeviceInventoryID: Entry] = [:]
    var onChange: ((DeviceInventoryID) -> Void)?

    init(connect: @escaping Connect = SimulatorScreenThumbnail.connect,
         waitToRetry: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.connect = connect
        self.waitToRetry = waitToRetry
    }

    isolated deinit {
        for entry in entries.values {
            entry.receiving?.cancel()
            entry.freezing?.cancel()
            entry.source?.stop()
        }
    }

    func frame(for identifier: DeviceInventoryID) -> DeviceThumbnailFrame? { entries[identifier]?.frame }
    func image(for identifier: DeviceInventoryID) -> CGImage? { entries[identifier]?.image }

    func update(visible: [SimulatorHostDevice], booted: [SimulatorHostDevice]) {
        let running = Dictionary(booted.map { (InventoryDevice.simulator($0).id, $0) }, uniquingKeysWith: { first, _ in first })
        for (identifier, entry) in entries {
            guard let current = running[identifier], current.lastBootDate == entry.device.lastBootDate,
                  current.ownerXcodeURL == entry.device.ownerXcodeURL,
                  current.catalogXcodeURL == entry.device.catalogXcodeURL else {
                stop(entry, preservingFrame: false)
                entries.removeValue(forKey: identifier)
                onChange?(identifier)
                continue
            }
        }
        let wanted = Set(visible.map { InventoryDevice.simulator($0).id })
        for (identifier, entry) in entries where entry.active && !wanted.contains(identifier) {
            stop(entry, preservingFrame: true)
        }
        for device in visible {
            let identifier = InventoryDevice.simulator(device).id
            let entry = entries[identifier] ?? Entry(device)
            entries[identifier] = entry
            guard !entry.active else { continue }
            entry.active = true
            let connect = connect
            let waitToRetry = waitToRetry
            entry.receiving = Task(priority: .utility) { [weak self, weak entry] in
                var retrySeconds = 1
                var reportedFailure = false
                while !Task.isCancelled {
                    let generation: Int
                    if let self, let entry, self.entries[identifier] === entry, entry.active {
                        entry.generation += 1
                        generation = entry.generation
                    } else { return }
                    let (failures, continuation) = AsyncStream<any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
                    do {
                        let source = try await connect(device, { [weak self, weak entry] frame in
                            guard let self, let entry, self.entries[identifier] === entry,
                                  entry.active, entry.generation == generation else { return }
                            entry.freezing?.cancel()
                            entry.freezing = nil
                            entry.frame = frame
                            entry.image = nil
                            self.onChange?(identifier)
                        }, { error in continuation.yield(error); continuation.finish() })
                        if let self, let entry, self.entries[identifier] === entry,
                           entry.active, entry.generation == generation {
                            entry.source = source
                        } else { source.stop(); return }
                        var iterator = failures.makeAsyncIterator()
                        if let error = await iterator.next() { throw error }
                        return
                    } catch {
                        guard let self, let entry, self.entries[identifier] === entry,
                              entry.active, entry.generation == generation else { return }
                        entry.generation += 1
                        self.releaseSource(entry, preservingFrame: true)
                        if !reportedFailure, !error.isCancellation {
                            hostLog("Could not update the device thumbnail: \(error.localizedDescription)")
                            reportedFailure = true
                        }
                    }
                    // Failed optional previews retry while visible, without filling the log or a task queue.
                    do { try await waitToRetry(.seconds(retrySeconds)) } catch { return }
                    retrySeconds = min(30, retrySeconds * 2)
                }
            }
        }
    }

    private func stop(_ entry: Entry, preservingFrame: Bool) {
        entry.active = false
        entry.generation += 1
        entry.receiving?.cancel()
        entry.receiving = nil
        releaseSource(entry, preservingFrame: preservingFrame)
    }

    private func releaseSource(_ entry: Entry, preservingFrame: Bool) {
        let generation = entry.generation
        entry.source?.stop()
        entry.source = nil
        entry.freezing?.cancel()
        entry.freezing = nil
        let frame = entry.frame
        entry.frame = nil
        guard preservingFrame, let frame else { return }
        entry.freezing = Task(priority: .utility) { [weak self, weak entry] in
            let image = try? await frame.snapshot()
            guard !Task.isCancelled, let self, let entry, entry.generation == generation else { return }
            entry.image = image
            entry.freezing = nil
            self.onChange?(InventoryDevice.simulator(entry.device).id)
        }
    }
}
