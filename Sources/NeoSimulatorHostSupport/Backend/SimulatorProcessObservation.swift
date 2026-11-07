import Darwin
import Foundation
import NeoSimulatorDeviceIO
import NeoSimulatorKit

/// Watches simulator launchers and their children. Guest apps are not NSRunningApplications.
@MainActor
package final class SimulatorProcessObservation {
    package var onChange: (() -> Void)?
    package var onReady: (() -> Void)?
    package var onError: ((any Error) -> Void)?

    private struct Identity: Equatable, Sendable {
        let seconds: UInt64
        let microseconds: UInt64
    }
    private struct Watch {
        let identity: Identity
        let source: any DispatchSourceProcess
    }
    private struct Snapshot: Sendable {
        let roots: Set<pid_t>
        let processes: [pid_t: Identity]
        let connections: [XcodeSimulatorConnection]
    }
    private let roots: @Sendable () throws -> [pid_t]
    private let observesDeviceSets: Bool
    private var deviceObservations: [String: (SimulatorDeviceSet, UInt64)] = [:]
    private var observingDevices: Task<Void, Never>?
    private var testingDirectoryWatch: (any DispatchSourceFileSystemObject)?
    private var watchedDirectory: String?
    private var watchedTestingPath: String?
    private var generation = 0
    private var watches: [pid_t: Watch] = [:]
    private var rootIdentifiers: Set<pid_t> = []
    private var reading: Task<Void, Never>?
    private var requested = false
    private var pendingEvents: [pid_t: DispatchSource.ProcessEvent] = [:]
    private var deviceChangePending = false
    private var observedConnections: [XcodeSimulatorConnection]?
    private var active = false
    private var deviceObservationFailed = false
    private var processObservationFailed = false
    private var retry: Task<Void, Never>?
    private var retryDelay: Duration = .seconds(1)

    package convenience init() {
        self.init(rootProcessIdentifiers: Self.simulatorLaunchers, observesDeviceSets: true)
    }

    package convenience init(rootProcessIdentifiers: @escaping @Sendable () throws -> [pid_t]) {
        self.init(rootProcessIdentifiers: rootProcessIdentifiers, observesDeviceSets: false)
    }

    private init(
        rootProcessIdentifiers: @escaping @Sendable () throws -> [pid_t], observesDeviceSets: Bool
    ) {
        roots = rootProcessIdentifiers
        self.observesDeviceSets = observesDeviceSets
    }

    isolated deinit {
        reading?.cancel()
        retry?.cancel()
        observingDevices?.cancel()
        testingDirectoryWatch?.cancel()
        for (set, token) in deviceObservations.values { _ = set.stopObserving(token) }
        for watch in watches.values { watch.source.cancel() }
    }

    package func start() {
        active = true
        observeDeviceSets()
        refresh()
    }

    package func stop() {
        active = false
        retry?.cancel()
        retry = nil
        generation += 1
        observingDevices?.cancel()
        observingDevices = nil
        testingDirectoryWatch?.cancel()
        testingDirectoryWatch = nil
        watchedDirectory = nil
        watchedTestingPath = nil
        for (set, token) in deviceObservations.values { _ = set.stopObserving(token) }
        deviceObservations.removeAll()
        requested = false
        processObservationFailed = false
        pendingEvents.removeAll()
        deviceChangePending = false
        observedConnections = nil
        reading?.cancel()
        for watch in watches.values { watch.source.cancel() }
        watches.removeAll()
        rootIdentifiers.removeAll()
    }

    /// Device boot notifications discover new launchers; process notifications discover new children.
    package func refresh() {
        requestRefresh(deviceChanged: true)
    }

    private func requestRefresh(deviceChanged: Bool) {
        guard active else { return }
        if deviceChanged { observeDeviceSets() }
        requested = true
        deviceChangePending = deviceChangePending || deviceChanged
        readPendingChanges()
    }

    private func processChanged(
        _ pid: pid_t, identity: Identity, events: DispatchSource.ProcessEvent
    ) {
        guard active, watches[pid]?.identity == identity else { return }
        if events.contains(.exit) {
            watches.removeValue(forKey: pid)?.source.cancel()
            // Fork and exit may arrive separately. Surviving children have been adopted
            // by launchd_sim, so enumerate its direct children to discover them.
            for root in rootIdentifiers where root != pid {
                pendingEvents[root, default: []].insert(.fork)
            }
        }
        pendingEvents[pid, default: []].formUnion(events)
        readPendingChanges()
    }

    private func readPendingChanges() {
        guard reading == nil else { return }
        reading = Task { [weak self, roots] in
            while let self, self.active, self.requested || !self.pendingEvents.isEmpty,
                !Task.isCancelled
            {
                let fullRefresh = self.requested
                self.requested = false
                let events = self.pendingEvents.mapValues(\.rawValue)
                self.pendingEvents.removeAll(keepingCapacity: true)
                let processes = self.watches.mapValues(\.identity)
                let rootIdentifiers = self.rootIdentifiers
                let connections = self.observedConnections ?? []
                do {
                    let snapshot = try await Task.detached(priority: .utility) {
                        if fullRefresh { return try Self.snapshot(roots: roots()) }
                        return try Self.snapshot(
                            updating: processes, roots: rootIdentifiers,
                            connections: connections, events: events)
                    }.value
                    guard self.active, !Task.isCancelled else { break }
                    if fullRefresh { self.processObservationFailed = false }
                    self.rootIdentifiers = snapshot.roots
                    self.apply(snapshot.processes)
                    let changed = self.observedConnections != snapshot.connections
                    self.observedConnections = snapshot.connections
                    if changed || self.deviceChangePending {
                        self.deviceChangePending = false
                        self.onChange?()
                    }
                    if !self.deviceObservationFailed, !self.processObservationFailed {
                        self.retry?.cancel()
                        self.retry = nil
                        self.retryDelay = .seconds(1)
                        self.onReady?()
                    }
                } catch {
                    if self.active, !Task.isCancelled {
                        self.processObservationFailed = true
                        self.retryAfterFailure(error)
                    }
                }
            }
            self?.reading = nil
            if let self, self.active, self.requested || !self.pendingEvents.isEmpty {
                self.readPendingChanges()
            }
        }
    }

    /// CoreDevice does not list XCTest's device set. Observe CoreSimulator directly so its
    /// boots discover new launchd_sim processes too, including a set first created by Xcode.
    private func observeDeviceSets() {
        guard observesDeviceSets, active, observingDevices == nil else { return }
        let paths: [String?] = [nil] + (SimulatorDeviceSets.testingPath().map { [$0] } ?? [])
        let keys = Set(paths.map { $0 ?? "" })
        for key in deviceObservations.keys where !keys.contains(key) {
            if let (set, token) = deviceObservations.removeValue(forKey: key) {
                _ = set.stopObserving(token)
            }
        }
        if let watchedTestingPath, !keys.contains(watchedTestingPath) {
            testingDirectoryWatch?.cancel()
            testingDirectoryWatch = nil
            watchedDirectory = nil
            self.watchedTestingPath = nil
        }
        let missing = paths.filter { path in
            guard deviceObservations[path ?? ""] == nil else { return false }
            guard let path else { return true }
            return path != watchedTestingPath || testingDirectoryWatch == nil
                || FileManager.default.fileExists(atPath: path)
        }
        guard !missing.isEmpty else {
            deviceObservationFailed = false
            return
        }
        let generation = generation
        observingDevices = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { self.observingDevices = nil } }
            do {
                let xcode = try await CoreDeviceRuntime.uiXcodeURL()
                for path in missing {
                    guard self.active, self.generation == generation, !Task.isCancelled else {
                        return
                    }
                    if let path, !FileManager.default.fileExists(atPath: path) {
                        try self.watchForTestingDirectory(path)
                        continue
                    }
                    if path != nil {
                        self.testingDirectoryWatch?.cancel()
                        self.testingDirectoryWatch = nil
                        self.watchedDirectory = nil
                        self.watchedTestingPath = nil
                    }
                    let set = try await SimulatorDeviceSet.load(xcodeURL: xcode, path: path)
                    let token = try await set.observe { [weak self] in self?.refresh() }
                    guard self.active, self.generation == generation, !Task.isCancelled else {
                        _ = set.stopObserving(token)
                        return
                    }
                    self.deviceObservations[path ?? ""] = (set, token)
                    self.refresh()
                }
                self.deviceObservationFailed = false
                self.refresh()
            } catch {
                if self.active, self.generation == generation, !Task.isCancelled {
                    self.deviceObservationFailed = true
                    self.retryAfterFailure(error)
                }
            }
        }
    }

    private func retryAfterFailure(_ error: any Error) {
        onError?(error)
        if let failure = error as? any IdentifiedFailure,
            failure.category == .configuration || failure.category == .software
                || failure.identifier == "unsupported-xcode"
        {
            return
        }
        guard retry == nil else { return }
        let delay = retryDelay
        retryDelay = min(delay * 2, .seconds(30))
        retry = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self else { return }
            self.retry = nil
            self.refresh()
        }
    }

    private func watchForTestingDirectory(_ path: String) throws {
        var ancestor = URL(fileURLWithPath: path)
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            ancestor.deleteLastPathComponent()
        }
        guard watchedDirectory != ancestor.path || watchedTestingPath != path else { return }
        testingDirectoryWatch?.cancel()
        testingDirectoryWatch = nil
        watchedDirectory = nil
        watchedTestingPath = nil
        let descriptor = open(ancestor.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw HostOperationError.io(
                "device-set-observation",
                "Could not observe \(ancestor.path): \(String(cString: strerror(errno)))")
        }
        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete], queue: .main)
        watcher.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.testingDirectoryChanged(path) }
        }
        watcher.setRegistrationHandler { [weak self] in
            MainActor.assumeIsolated { self?.testingDirectoryChanged(path) }
        }
        watcher.setCancelHandler { close(descriptor) }
        testingDirectoryWatch = watcher
        watchedDirectory = ancestor.path
        watchedTestingPath = path
        watcher.activate()
    }

    private func testingDirectoryChanged(_ path: String) {
        guard active, watchedTestingPath == path else { return }
        if FileManager.default.fileExists(atPath: path) {
            observeDeviceSets()
        } else {
            do { try watchForTestingDirectory(path) } catch {
                deviceObservationFailed = true
                retryAfterFailure(error)
            }
        }
    }

    private func apply(_ snapshot: [pid_t: Identity]) {
        for (pid, watch) in watches where snapshot[pid] != watch.identity {
            watch.source.cancel()
            watches[pid] = nil
        }
        for (pid, identity) in snapshot where watches[pid] == nil {
            let source = DispatchSource.makeProcessSource(
                identifier: pid, eventMask: [.fork, .exec, .exit], queue: .main)
            source.setEventHandler { [weak self, weak source] in
                MainActor.assumeIsolated {
                    guard let self, let source, self.active, self.watches[pid]?.identity == identity
                    else { return }
                    self.processChanged(pid, identity: identity, events: source.data)
                }
            }
            // Cover launches/execs between the snapshot and registration in the kernel.
            source.setRegistrationHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.active, self.watches[pid]?.identity == identity else {
                        return
                    }
                    self.processChanged(pid, identity: identity, events: [.fork, .exec])
                }
            }
            watches[pid] = Watch(identity: identity, source: source)
            source.activate()
        }
    }

    private nonisolated static func simulatorLaunchers() throws -> [pid_t] {
        let user = getuid()
        let capacity =
            Int(proc_listpids(UInt32(PROC_UID_ONLY), user, nil, 0)) / MemoryLayout<pid_t>.stride
            + 128
        var pids = [pid_t](repeating: 0, count: capacity)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), user, $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else {
            throw HostOperationError.io("process-list", "Could not enumerate simulator launchers.")
        }
        var name = [CChar](repeating: 0, count: 256)
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride).filter { pid in
            pid > 0 && proc_name(pid, &name, UInt32(name.count)) > 0
                && name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                    == "launchd_sim"
        }
    }

    private nonisolated static func snapshot(roots: [pid_t]) throws -> Snapshot {
        var processes: [pid_t: Identity] = [:]
        var pending = roots
        let user = getuid()
        while let pid = pending.popLast() {
            guard processes[pid] == nil, let identity = identity(of: pid, user: user) else {
                continue
            }
            processes[pid] = identity
            pending.append(contentsOf: children(of: pid))
        }
        return Snapshot(
            roots: Set(roots).intersection(processes.keys),
            processes: processes,
            connections:
                try SimulatorProcessConnections
                .read(processIdentifiers: Array(processes.keys)).sorted { $0.event < $1.event })
    }

    private nonisolated static func snapshot(
        updating known: [pid_t: Identity],
        roots: Set<pid_t>,
        connections: [XcodeSimulatorConnection],
        events rawEvents: [pid_t: UInt]
    ) throws -> Snapshot {
        let events = rawEvents.mapValues { DispatchSource.ProcessEvent(rawValue: $0) }
        var processes = known
        var connectionsByPID = Dictionary(
            uniqueKeysWithValues: connections.map { ($0.event.processIdentifier, $0) })
        var pending: [pid_t] = []
        var visited: Set<pid_t> = []
        var changedExecutables: Set<pid_t> = []
        let user = getuid()
        for (pid, event) in events {
            if event.contains(.exit) {
                processes[pid] = nil
                connectionsByPID[pid] = nil
            } else {
                pending.append(pid)
                if event.contains(.exec) { changedExecutables.insert(pid) }
            }
        }
        while let pid = pending.popLast() {
            guard visited.insert(pid).inserted else { continue }
            guard let identity = identity(of: pid, user: user) else {
                processes[pid] = nil
                connectionsByPID[pid] = nil
                continue
            }
            let isNew = processes[pid] != identity
            processes[pid] = identity
            if isNew {
                changedExecutables.insert(pid)
                connectionsByPID[pid] = nil
            }
            // Existing children report their own forks. Only traverse a new process
            // or the process whose notification says its children changed.
            if isNew || events[pid]?.contains(.fork) == true {
                pending.append(contentsOf: children(of: pid))
            }
        }
        for pid in changedExecutables { connectionsByPID[pid] = nil }
        if !changedExecutables.isEmpty {
            for connection in try SimulatorProcessConnections.read(
                processIdentifiers: Array(changedExecutables))
            {
                let event = connection.event
                guard
                    processes[event.processIdentifier]
                        == Identity(
                            seconds: event.startSeconds, microseconds: event.startMicroseconds)
                else { continue }
                connectionsByPID[event.processIdentifier] = connection
            }
        }
        return Snapshot(
            roots: roots.intersection(processes.keys),
            processes: processes,
            connections: connectionsByPID.values.sorted { $0.event < $1.event })
    }

    private nonisolated static func identity(of pid: pid_t, user: uid_t) -> Identity? {
        var info = proc_bsdinfo()
        guard
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
                == MemoryLayout<proc_bsdinfo>.size,
            info.pbi_uid == user
        else { return nil }
        return Identity(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    private nonisolated static func children(of pid: pid_t) -> [pid_t] {
        let capacity = Int(proc_listchildpids(pid, nil, 0)) + 32
        var children = [pid_t](repeating: 0, count: capacity)
        let count = children.withUnsafeMutableBytes {
            proc_listchildpids(pid, $0.baseAddress, Int32($0.count))
        }
        return count > 0 ? children.prefix(Int(count)).filter { $0 > 0 } : []
    }
}
