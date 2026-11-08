import Foundation
import NeoSimulatorDeviceIO

/// Owns simulator connections and their resources independently of an application's menus or routing.
@MainActor
package final class SimulatorScreenHost {
    package let runtime: SimulatorIORuntime
    private var conflicts: any HostConflictChecking
    /// What draws this host's devices. Without one, it reads and manages them but attaches no display.
    package private(set) var presenter: (any DevicePresenter)?
    private let deviceSet: SimulatorDeviceSet
    private let recordings: RecordingStore
    /// How long stopping waits for capture file work, which defaults to TerminationTimeout.
    package var captureFinishLimit: Duration?
    private let isManaged: Bool
    package let isHeadless: Bool
    private let isInProcess: Bool
    private let suppliedPasteboardSync: PasteboardSync?
    private let offersLifetimeChoice: Bool
    package var onClose: ((SimulatorDeviceIdentifier, DeviceLifetimeChoice?, Task<Void, any Error>) -> Void)?
    package var onError: ((Error) -> Void)?
    package var onChange: (() -> Void)?
    package var onRestart: ((SimulatorDeviceIdentifier, Bool) -> Void)?
    package var onShutDown: ((SimulatorDeviceIdentifier) -> Void)?
    package var onOwnershipChange: ((Bool) throws -> Void)?
    package var onOpen: ((SimulatorDeviceIdentifier) -> Void)?
    package var onNoScreens: (() -> Void)?
    package var onConflict: ((String, (any Error)?) -> Void)?
    package var onConflictBegan: ((String) -> Void)?
    package var isStopped: Bool { stopped }
    package var openedDeviceIdentifiers: Set<SimulatorDeviceIdentifier> { Set(sessions.keys) }
    package private(set) var ownedDeviceIdentifiers: Set<SimulatorDeviceIdentifier> = []
    package var registrationDeviceIdentifiers: [SimulatorDeviceIdentifier] {
        ownedDeviceIdentifiers.union(closingShutdowns.keys).union(releasingDevices).sorted()
    }
    package var presentations: [any DevicePresentation] { Array(sessions.values) }
    package var hasPresentations: Bool { !sessions.isEmpty || !connections.isEmpty }
    private var releasingDevices: Set<SimulatorDeviceIdentifier> = []
    private var registrationErrorReported = false
    package private(set) var isTerminating = false
    private var recordingTerminationErrors: [Error] = []
    private var notificationToken: UInt64?
    private var observationRemovals: [Task<Void, Never>] = []
    private var healthFollowers: [DeviceSetAddress: Task<Void, Never>] = [:]
    private var isStarted = false
    private var rescanning: Task<Void, Never>?
    /// Whether another rescan was requested, and whether any request came from the testing devices' visibility changing.
    private var rescanRequest: Bool?
    private var testingSet: SimulatorDeviceSet?
    private var testingNotificationToken: UInt64?
    private var testingSetWatcher: DispatchSourceFileSystemObject?
    private var isOpeningTestingSet = false
    private var testingSetNeedsOpening = false
    private var sessions: [SimulatorDeviceIdentifier: any DevicePresentation] = [:]
    private var connections: [SimulatorDeviceIdentifier: Task<Void, Never>] = [:]
    private var stateWaits: [SimulatorDeviceIdentifier: [UUID: (task: Task<SimulatorDeviceRecord?, any Error>, cancelsOnRelease: Bool)]] = [:]
    private var bootOperations: [SimulatorDeviceIdentifier: DeviceTools] = [:]
    private var restarting: [SimulatorDeviceIdentifier: Task<Void, Never>] = [:]
    private var awaitingReconnect: [SimulatorDeviceIdentifier: any DevicePresentation] = [:]
    private var presentationRestarts: Set<SimulatorDeviceIdentifier> = []
    private var suppressed: Set<SimulatorDeviceIdentifier> = []
    private var closingShutdowns: [SimulatorDeviceIdentifier: Task<Void, Never>] = [:]
    private var disconnectedSessions: [DeviceSession] = []
    private var externalDisplayQueues: [SimulatorDeviceIdentifier: (name: String, changes: ExternalDisplayChanges)] = [:]
    private var yieldedToAnotherHost = false
    private var terminationShutdowns: [Task<String?, Never>] = []
    private var connectionFailures: [SimulatorDeviceIdentifier: Error] = [:]
    private var openingDevices: Set<SimulatorDeviceIdentifier> = []
    private var stopped = false
    private var stoppingTask: Task<Void, Error>?
    /// Where this host's sessions find their devices' state.
    package let deviceRegistry: DeviceRegistry
    private lazy var pasteboardSync: PasteboardSync = suppliedPasteboardSync ?? PasteboardSync { [weak self] in
        self?.sessions.values.map(\.session) ?? []
    }
    package var pasteboardSynchronization: PasteboardSync { pasteboardSync }
    private var touchIndicatorObservation: DefaultsObservation?
    private var testingDevicesObservation: DefaultsObservation?

    package init(runtime: SimulatorIORuntime, conflicts: any HostConflictChecking = NoHostConflicts(),
         presenter: (any DevicePresenter)? = nil, isManaged: Bool = false,
         headless: Bool = false, inProcess: Bool = false, pasteboardSync: PasteboardSync? = nil,
         offersLifetimeChoice: Bool = true, deviceRegistry: DeviceRegistry = DeviceRegistry(),
         recordings: RecordingStore = RecordingStore()) throws {
        try conflicts.check()
        self.deviceRegistry = deviceRegistry
        self.recordings = recordings
        self.runtime = runtime
        self.conflicts = conflicts
        self.presenter = presenter
        self.isManaged = isManaged
        isHeadless = headless
        isInProcess = inProcess
        suppliedPasteboardSync = pasteboardSync
        self.offersLifetimeChoice = offersLifetimeChoice
        deviceSet = runtime.openDeviceSet()
        HostPreferences.registerDefaults()
        recordings.onError = { [weak self] error in
            guard let self else { hostLog(error.localizedDescription); return }
            self.noteCaptureFailure(error)
        }
        conflicts.onConflict = { [weak self] in self?.handleHostConflict() }
    }

    /// Gives this host what draws its devices and checks for other displays. A conflict leaves it without either.
    package func install(presenter: any DevicePresenter, conflicts: any HostConflictChecking) throws {
        try conflicts.check()
        self.presenter = presenter
        self.conflicts.onConflict = nil
        self.conflicts = conflicts
        conflicts.onConflict = { [weak self] in self?.handleHostConflict() }
    }

    package func presentation(for identifier: SimulatorDeviceIdentifier) -> (any DevicePresentation)? { sessions[identifier] }
    package func hasUnfinishedCleanup(for identifier: SimulatorDeviceIdentifier) -> Bool {
        disconnectedSessions.contains { $0.device.identity == identifier }
            || (sessions[identifier] == nil && externalDisplayQueues[identifier] != nil)
    }
    package func adopt(_ identifier: SimulatorDeviceIdentifier) { ownedDeviceIdentifiers.insert(identifier) }
    package func creationCatalog() async throws -> SimulatorCatalog { try await deviceSet.readCatalog().catalog() }
    package func refreshLocationSelection(for identifier: SimulatorDeviceIdentifier) throws {
        try sessions[identifier]?.session.refreshLocationSelection()
    }

    package func start(attachingBootedDevices: Bool = true) async throws {
        do {
            try conflicts.check()
            touchIndicatorObservation = DefaultsObservation(
                HostPreferences.defaults, keys: TouchIndicator.allCases.map(\.preferenceKey)) {
                NotificationCenter.default.post(name: TouchIndicator.didChangeNotification, object: HostPreferences.defaults)
            }
            testingDevicesObservation = DefaultsObservation(HostPreferences.defaults, keys: [HostPreferences.showTestingDevices]) { [weak self] in
                self?.applyTestingDeviceVisibility()
            }
            rescanWhenAnsweringAgain(deviceSet)
            let token = try await deviceSet.observe { [weak self] in self?.rescan() }
            guard !stopped else {
                observationRemovals.append(deviceSet.stopObserving(token))
                return
            }
            notificationToken = token
            await openTestingSet()
            let devices = try await readDevices()
            guard !stopped else { return }
            if !attachingBootedDevices {
                suppressed.formUnion(devices.filter { $0.state == 3 }.map(\.identity))
            }
            // Until here a rescan could attach a device that this start leaves alone.
            isStarted = true
            // Until here asking for a rescan did nothing, also for a set that answered again meanwhile.
            if testingSetNeedsOpening { rescan() }
            if !isManaged && !isInProcess { try await scanDevices() }
        } catch {
            shutdown()
            throw error
        }
    }

    package func releaseDevice(_ identifier: SimulatorDeviceIdentifier) async throws {
        var holdsDevice = ownedDeviceIdentifiers.contains(identifier) || sessions[identifier] != nil
            || connections[identifier] != nil || closingShutdowns[identifier] != nil
            || disconnectedSessions.contains(where: { $0.device.identity == identifier })
        if !holdsDevice, externalDisplayQueues[identifier] != nil {
            holdsDevice = await isRunning(identifier.identifier, deviceSetPath: identifier.deviceSetPath)
        }
        guard holdsDevice else { return }
        guard !releasingDevices.contains(identifier) else {
            throw SimulatorError.operation("This simulator is already being handed over.")
        }
        releasingDevices.insert(identifier)
        defer { releasingDevices.remove(identifier) }
        suppressed.insert(identifier)
        let connection = connections[identifier]
        let restart = restarting[identifier]
        let closing = closingShutdowns[identifier]
        connection?.cancel()
        restart?.cancel()
        closing?.cancel()
        bootOperations[identifier]?.cancel()
        cancelStateWaits(for: identifier, openingsOnly: true)
        await connection?.value
        await restart?.value
        await closing?.value
        if let controller = sessions[identifier] {
            do {
                if let recording = try await controller.session.activeRecording() {
                    try await recording.finish()
                    try await recording.waitUntilFinished()
                }
            } catch { suppressed.remove(identifier); throw error }
            controller.invalidate()
            sessions.removeValue(forKey: identifier)
            disconnectedSessions.append(controller.session)
        }
        awaitingReconnect.removeValue(forKey: identifier)
        presentationRestarts.remove(identifier)
        // Like an unfinished external display, input that was not removed keeps the device for another release.
        let inputFailures = await finishDisconnectedInput(of: identifier)
        guard inputFailures.isEmpty else { throw SimulatorError.operation(inputFailures.joined(separator: "\n")) }
        if let changes = externalDisplayQueues[identifier]?.changes {
            let deadline = ContinuousClock.now + .seconds(HostPreferences.defaults.double(forKey: HostPreferences.terminationTimeout))
            guard await changes.idle(before: deadline) else {
                throw SimulatorError.operation("The simulator's external displays did not finish disconnecting.")
            }
            externalDisplayQueues.removeValue(forKey: identifier)
        }
        ownedDeviceIdentifiers.remove(identifier)
        releasingDevices.remove(identifier)
        do { if isManaged { try onOwnershipChange?(false) } }
        catch {
            ownedDeviceIdentifiers.insert(identifier)
            throw SimulatorError.operation("The simulator disconnected, but its ownership could not be updated: \(error.localizedDescription)")
        }
    }

    private func updateOwnership(testingVisibilityChanged: Bool = false) {
        guard !stopped else { return }
        do { try onOwnershipChange?(testingVisibilityChanged) }
        catch {
            if !registrationErrorReported {
                registrationErrorReported = true
                hostLog(error.localizedDescription)
            }
        }
    }

    /// What the shown device sets last reported. This waits for nothing, also while a set's call is held.
    package func availableSimulatorDevices() -> [AvailableDevice] {
        var devices = deviceSet.devices
        if showsTestingDevices, let testingSet { devices += testingSet.devices }
        return devices.filter(Self.isSupported).map(Self.describe)
    }

    /// What the shown device sets report now.
    package func readAvailableDevices() async throws -> [AvailableDevice] {
        try await readDevices().map(Self.describe)
    }

    package func hasVisibleWindow(forDevice identifier: SimulatorDeviceIdentifier) -> Bool {
        sessions[identifier]?.isVisible == true
    }

    private static func isSupported(_ device: SimulatorDeviceRecord) -> Bool {
        DeviceCapabilities.Family(rawValue: device.productFamily) != nil
    }

    /// Reads supported product families from the shown device sets. A testing set that cannot be read keeps what it last
    /// reported, since it should not stop the default set's devices from opening.
    private func readDevices() async throws -> [SimulatorDeviceRecord] {
        async let defaultDevices = deviceSet.refresh()
        var testingDevices: [SimulatorDeviceRecord] = []
        if showsTestingDevices, let testingSet {
            do { testingDevices = try await testingSet.refresh() }
            catch is CancellationError { throw CancellationError() }
            catch {
                hostLog("Could not read the parallel testing device set: \(error.localizedDescription)")
                testingDevices = testingSet.devices
            }
        }
        let devices = try await defaultDevices
        // Hiding the testing devices during these reads closed their windows, which what the reads found must not reopen.
        return (showsTestingDevices ? devices + testingDevices : devices).filter(Self.isSupported)
    }

    /// Reads a device from its own set, so that opening it depends on no other set. A testing device hidden meanwhile is
    /// not there to open.
    private func readDevice(_ identifier: SimulatorDeviceIdentifier) async throws -> SimulatorDeviceRecord? {
        var isShown: Bool { identifier.deviceSetPath == nil || showsTestingDevices }
        guard isShown else { return nil }
        let set = identifier.deviceSetPath == nil ? deviceSet : testingSet
        let device = try await set?.refresh().first { $0.identity == identifier && Self.isSupported($0) }
        return isShown ? device : nil
    }

    package func waitForDevice(_ identifier: SimulatorDeviceIdentifier, until predicate: @escaping (SimulatorDeviceRecord) -> Bool,
                               deadline: ContinuousClock.Instant) async throws -> SimulatorDeviceRecord? {
        try await waitForDevice(identifier, until: predicate, deadline: deadline, cancelsOnRelease: false)
    }

    private func waitForDevice(_ identifier: SimulatorDeviceIdentifier, until predicate: @escaping (SimulatorDeviceRecord) -> Bool,
                               deadline: ContinuousClock.Instant, cancelsOnRelease: Bool) async throws -> SimulatorDeviceRecord? {
        var isShown: Bool { identifier.deviceSetPath == nil || showsTestingDevices }
        guard isShown, let set = identifier.deviceSetPath == nil ? deviceSet : testingSet else { return nil }
        let id = UUID()
        let task = Task { try await set.waitForDevice(identifier.identifier, until: predicate, deadline: deadline) }
        stateWaits[identifier, default: [:]][id] = (task, cancelsOnRelease)
        defer {
            stateWaits[identifier]?[id] = nil
            if stateWaits[identifier]?.isEmpty == true { stateWaits[identifier] = nil }
        }
        do {
            let device = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            return isShown ? device : nil
        } catch {
            if !isShown { return nil }
            throw error
        }
    }

    private func waitForOpeningState(_ identifier: SimulatorDeviceIdentifier, deadline: ContinuousClock.Instant) async throws -> SimulatorDeviceRecord? {
        try await waitForDevice(identifier, until: { $0.state != 2 }, deadline: deadline, cancelsOnRelease: true)
    }

    private func cancelStateWaits(for identifier: SimulatorDeviceIdentifier? = nil, openingsOnly: Bool = false) {
        for (device, waits) in stateWaits where identifier == nil || identifier == device {
            for wait in waits.values where !openingsOnly || wait.cancelsOnRelease { wait.task.cancel() }
        }
    }

    /// Updates the preference and every open window, including restarting devices.
    package func toggleShowDeviceBezels() {
        let shows = !HostPreferences.defaults.showsDeviceBezels
        HostPreferences.defaults.set(shows, forKey: HostPreferences.showChrome)
        for controller in sessions.values { controller.setDeviceBezelVisible(shows) }
    }

    // MARK: Parallel testing devices

    package var showsTestingDevices: Bool { HostPreferences.defaults.bool(forKey: HostPreferences.showTestingDevices) }
    package var isObservingTestingSet: Bool { testingNotificationToken != nil }

    /// Debug ▸ Show Parallel Testing Devices. Hiding closes the testing
    /// devices' windows without shutting the devices down.
    package func toggleShowTestingDevices() {
        HostPreferences.defaults.set(!showsTestingDevices, forKey: HostPreferences.showTestingDevices)
    }

    private func applyTestingDeviceVisibility() {
        guard !stopped, !isTerminating else { return }
        if showsTestingDevices {
            // Reattach every booted testing device, including previously closed windows.
            if let testingSet { suppressed.subtract(testingSet.devices.map(\.identity)) }
        } else {
            for identifier in stateWaits.keys where identifier.deviceSetPath != nil { cancelStateWaits(for: identifier) }
            let hadDeviceWindows = !sessions.isEmpty
            if let testingSet { ownedDeviceIdentifiers.subtract(testingSet.devices.map(\.identity)) }
            // A restart keeps running without its window.
            for (identifier, controller) in sessions where controller.session.tools.deviceSetPath != nil {
                sessions.removeValue(forKey: identifier)
                awaitingReconnect.removeValue(forKey: identifier)
                ownedDeviceIdentifiers.remove(identifier)
                controller.invalidate()
            }
            // The rescan below stops these too, but only once its read returns, which can be after they open a window.
            for (identifier, connection) in connections where identifier.deviceSetPath != nil { connection.cancel() }
            if hadDeviceWindows && sessions.isEmpty { onNoScreens?() }
        }
        rescan(testingVisibilityChanged: true)
    }

    /// Opens TestingDeviceSetPath or ~/Library/Developer/XCTestDevices if it exists.
    /// Waits for Xcode to create a missing set.
    private func openTestingSet() async {
        guard !stopped, testingSet == nil, !isOpeningTestingSet else { return }
        isOpeningTestingSet = true
        testingSetNeedsOpening = false
        defer { isOpeningTestingSet = false }
        let path = HostPreferences.defaults.string(forKey: HostPreferences.testingDeviceSetPath)
            .map { NSString(string: $0).expandingTildeInPath }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Developer/XCTestDevices").path
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var asked = deviceSet
        do {
            guard url != URL(fileURLWithPath: try await deviceSet.resolvedPath()).standardizedFileURL else {
                hostLog("TestingDeviceSetPath names the default device set; parallel testing devices are not shown")
                return
            }
            guard !stopped else { return }
            guard FileManager.default.fileExists(atPath: url.path) else {
                watchForTestingSet(at: url)
                return
            }
            testingSetWatcher?.cancel()
            testingSetWatcher = nil
            let set = runtime.openDeviceSet(at: url.path)
            asked = set
            rescanWhenAnsweringAgain(set)
            let token = try await set.observe { [weak self] in self?.rescan() }
            guard !stopped else {
                observationRemovals.append(set.stopObserving(token))
                return
            }
            testingNotificationToken = token
            testingSet = set
        } catch is CancellationError {
        } catch {
            hostLog("Could not open the parallel testing device set: \(error.localizedDescription)")
            // A call that held its worker is no reason to give the set up. The rescan once it returns tries again.
            guard error is DeviceOperationFailure else { return }
            testingSetNeedsOpening = true
            // The call can return before its failure gets here, and then that rescan has already been and gone.
            if await asked.channel.currentHealth == .ready { rescan() }
        }
    }

    /// A set that answers again may have changed while its call was held, without a rescan being able to see that. A
    /// request that outlived its deadline has ended by then, so nothing else follows its call: this has to be in place first.
    private func rescanWhenAnsweringAgain(_ set: SimulatorDeviceSet) {
        guard healthFollowers[set.address] == nil else { return }
        healthFollowers[set.address] = Task { [weak self] in
            var wasHeld = false
            for await health in set.healthChanges() {
                if case .unresponsive = health { wasHeld = true }
                else if wasHeld {
                    wasHeld = false
                    self?.rescan()
                }
            }
        }
    }

    /// Watches the set's nearest existing ancestor, moving down as Xcode
    /// creates the directories, until the set exists.
    private func watchForTestingSet(at url: URL) {
        func nearestAncestor() -> URL {
            var ancestor = url.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
                ancestor.deleteLastPathComponent()
            }
            return ancestor
        }
        let ancestor = nearestAncestor()
        testingSetWatcher?.cancel()
        testingSetWatcher = nil
        let descriptor = open(ancestor.path, O_EVTONLY)
        guard descriptor >= 0 else {
            hostLog("Cannot watch \(ancestor.path) for the parallel testing device set")
            return
        }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write,
                                                                queue: .main)
        watcher.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.testingSetDirectoryChanged() }
        }
        watcher.setCancelHandler { close(descriptor) }
        testingSetWatcher = watcher
        watcher.resume()
        // A directory created before the watcher started sends no event.
        if FileManager.default.fileExists(atPath: url.path) || nearestAncestor() != ancestor {
            testingSetDirectoryChanged()
        }
    }

    private func testingSetDirectoryChanged() {
        guard testingSet == nil else { return }
        Task { [weak self] in
            await self?.openTestingSet()
            if self?.testingSet != nil { self?.rescan() }
        }
    }

    private static func describe(_ device: SimulatorDeviceRecord) -> AvailableDevice {
        AvailableDevice(identifier: device.identifier, name: device.name, descriptiveName: device.descriptiveName,
                        runtimeIdentifier: device.runtimeIdentifier, runtimeName: device.runtimeName,
                        productFamily: device.productFamily, deviceTypeName: device.deviceTypeName,
                        state: device.state, deviceSetPath: device.deviceSetPath, lastBootDate: device.lastBootDate)
    }

    package func didSelectDevice(_ identifier: SimulatorDeviceIdentifier) {
        onOpen?(identifier)
        sessions[identifier]?.session.updatePasteboardSync()
    }

    package func openSimulator(withIdentifier identifier: SimulatorDeviceIdentifier) async throws {
        try await openSimulatorLocally(withIdentifier: identifier)
    }

    package func openPresentation(for identifier: SimulatorDeviceIdentifier, bootIfNeeded: Bool = false) async throws -> any DevicePresentation {
        let preservesPresentation = sessions[identifier] != nil || openingDevices.contains(identifier)
        return try await withScreenOpenCleanup(preservingExisting: preservesPresentation, operation: {
            try await self.openSimulatorLocally(withIdentifier: identifier, bootIfNeeded: bootIfNeeded, presents: false)
            guard let controller = self.sessions[identifier] else { throw CancellationError() }
            return controller
        }, cleanup: { try await self.releaseDevice(identifier) })
    }

    package func cancelRestart(for identifier: SimulatorDeviceIdentifier) async {
        guard let restart = restarting[identifier] else { return }
        restart.cancel()
        bootOperations[identifier]?.cancel()
        await restart.value
    }

    package func cancelOpeningResources(_ identifier: SimulatorDeviceIdentifier) {
        connections[identifier]?.cancel()
        bootOperations[identifier]?.cancel()
        cancelStateWaits(for: identifier, openingsOnly: true)
    }

    package func releasePresentation(for identifier: SimulatorDeviceIdentifier) async throws {
        try await releaseDevice(identifier)
        onChange?()
    }

    package func preparePresentationForRestart(for identifier: SimulatorDeviceIdentifier) async throws {
        await connections[identifier]?.value
        try Task.checkCancellation()
        guard !stopped, !isTerminating else { throw CancellationError() }
        guard let controller = sessions[identifier] else { return }
        guard !presentationRestarts.contains(identifier),
              awaitingReconnect[identifier] != nil || controller.session.reserve() else {
            throw SimulatorError.operation("This simulator already has an operation in progress.")
        }
        presentationRestarts.insert(identifier)
        do {
            if let recording = try await controller.session.activeRecording() {
                try await recording.finish()
                try await recording.waitUntilFinished()
            }
            awaitingReconnect[identifier] = controller
            await controller.prepareForRestart()
        } catch {
            presentationRestarts.remove(identifier)
            controller.session.release()
            throw error
        }
    }

    package func finishPresentationRestart(for identifier: SimulatorDeviceIdentifier) async throws {
        guard presentationRestarts.contains(identifier) else { return }
        defer { presentationRestarts.remove(identifier) }
        let deadline = ContinuousClock.now + .seconds(120)
        do {
            let state = try await waitForOpeningState(identifier, deadline: deadline)?.state
            guard !stopped, !isTerminating else { throw CancellationError() }
            guard state == 3 else {
                throw SimulatorError.operation("The simulator is not running, so its display could not reconnect.")
            }
        } catch {
            presentationRestarts.remove(identifier)
            await performRescan(testingVisibilityChanged: false)
            throw error
        }
        presentationRestarts.remove(identifier)
        try await openSimulatorLocally(withIdentifier: identifier, bootIfNeeded: false, presents: false)
    }

    package func openSimulatorLocally(withIdentifier identifier: SimulatorDeviceIdentifier, bootIfNeeded: Bool = true,
                                     presents: Bool = true) async throws {
        guard !releasingDevices.contains(identifier) else { throw CancellationError() }
        guard isHeadless || presenter != nil else {
            throw SimulatorError.unavailable("A device's screen opens through NeoSimulatorUI's SimulatorScreens.")
        }
        let preservesConnection = sessions[identifier] != nil || openingDevices.contains(identifier)
        openingDevices.insert(identifier)
        defer { openingDevices.remove(identifier) }
        // A restart boots the device itself, and a closed window shuts it
        // down; opening waits for either instead of acting on the device meanwhile.
        while let pending = restarting[identifier] ?? closingShutdowns[identifier] { await pending.value }
        // A quitting host opens nothing; callers do not report the cancellation.
        guard !stopped, !isTerminating else { throw CancellationError() }
        try conflicts.check()
        guard let device = try await readDevice(identifier) else {
            throw SimulatorError.operation("The selected simulator is no longer available")
        }
        guard !stopped, !isTerminating else { throw CancellationError() }
        guard bootIfNeeded || device.state == 3 else {
            throw SimulatorError.operation("The simulator is no longer running, so its display was not attached.")
        }
        ownedDeviceIdentifiers.insert(identifier)
        if isManaged { try onOwnershipChange?(false) }
        suppressed.remove(identifier)
        connectionFailures.removeValue(forKey: identifier)
        onOpen?(identifier)
        // Attach an already booting device when it finishes; avoid a second boot.
        if bootIfNeeded, device.state != 2, device.state != 3, bootOperations[identifier] == nil {
            let tools = try DeviceTools(identifier: identifier.identifier, xcodeURL: runtime.xcodeURL,
                                        deviceSetPath: device.deviceSetPath)
            bootOperations[identifier] = tools
            defer { bootOperations.removeValue(forKey: identifier) }
            try await tools.boot()
        }
        let deadline = ContinuousClock.now + .seconds(120)
        if isHeadless {
            guard !stopped, !isTerminating, ownedDeviceIdentifiers.contains(identifier),
                  !suppressed.contains(identifier), !releasingDevices.contains(identifier) else { throw CancellationError() }
            let device = try await waitForOpeningState(identifier, deadline: deadline)
            guard !stopped, !isTerminating, ownedDeviceIdentifiers.contains(identifier),
                  !suppressed.contains(identifier), !releasingDevices.contains(identifier) else { throw CancellationError() }
            guard device?.state == 3 else {
                throw SimulatorError.operation("The simulator did not finish starting.")
            }
            return
        }
        while sessions[identifier] == nil || awaitingReconnect[identifier] != nil {
            try Task.checkCancellation()
            guard !stopped, !isTerminating, !releasingDevices.contains(identifier),
                  !(isManaged || isInProcess) || ownedDeviceIdentifiers.contains(identifier) else { throw CancellationError() }
            if !bootIfNeeded {
                guard try await readDevice(identifier)?.state == 3 else {
                    throw SimulatorError.operation("The simulator is no longer running, so its display was not attached.")
                }
            }
            try await scanDevices()
            if let pending = connections[identifier] {
                if preservesConnection { await pending.value }
                else {
                    await withTaskCancellationHandler { await pending.value } onCancel: { pending.cancel() }
                }
            }
            if let failure = connectionFailures[identifier] { throw failure }
            if sessions[identifier] != nil && awaitingReconnect[identifier] == nil { break }
            guard ContinuousClock.now < deadline else { throw SimulatorError.unavailable("The simulator did not finish opening.") }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let controller = sessions[identifier] else { throw CancellationError() }
        // Refresh synchronization when a connected device is selected again.
        controller.session.updatePasteboardSync()
        if presents, !isInProcess { controller.showAndActivate() }
    }

    /// Reads the sets again and applies what they report. However many ask, one rescan runs and one more waits.
    private func rescan(testingVisibilityChanged: Bool = false) {
        guard isStarted, !stopped, !isTerminating else { return }
        rescanRequest = rescanRequest == true || testingVisibilityChanged
        guard rescanning == nil else { return }
        rescanning = Task { [weak self] in
            while let self, let testingVisibilityChanged = self.rescanRequest {
                self.rescanRequest = nil
                await self.performRescan(testingVisibilityChanged: testingVisibilityChanged)
            }
            self?.rescanning = nil
        }
    }

    /// Rescans before what follows looks at the windows that the rescan may close.
    private func rescanAndWait() async {
        rescan()
        await rescanning?.value
    }

    private func performRescan(testingVisibilityChanged: Bool) async {
        if testingSetNeedsOpening { await openTestingSet() }
        do { try await scanDevices(testingVisibilityChanged: testingVisibilityChanged) }
        catch is CancellationError {}
        catch let failure as DeviceOperationFailure {
            // The call that holds the set was already reported when it outlived its limit.
            if case .notSent = failure { hostLog(failure.localizedDescription) } else { report(failure) }
        } catch let error as SimulatorError {
            if case .conflict = error { handleHostConflict() }
            else { report(error) }
        } catch { report(error) }
    }

    private func scanDevices(testingVisibilityChanged: Bool = false) async throws {
        guard !stopped, !isTerminating else { return }
        defer { updateOwnership(testingVisibilityChanged: testingVisibilityChanged) }
        try conflicts.check()
        // A restart that ends during this read may not be in it, and asks for another rescan. Until then, what this read
        // reports about its device says nothing about the device now.
        let restartsBeforeReading = Set(restarting.keys).union(presentationRestarts)
        let pendingBeforeReading = pendingDeviceIdentifiers
        let devices = try await readDevices()
        guard !stopped, !isTerminating else { return }
        try conflicts.check()
        let booted = devices.filter { $0.state == 3 && (!(isManaged || isInProcess) || ownedDeviceIdentifiers.contains($0.identity)) }
        let identifiers = Set(booted.map(\.identity))
        let hadDeviceWindows = !sessions.isEmpty
        for identifier in sessions.keys where !identifiers.contains(identifier) && restarting[identifier] == nil
            && !presentationRestarts.contains(identifier) && !restartsBeforeReading.contains(identifier) {
            sessions.removeValue(forKey: identifier)?.invalidate()
            awaitingReconnect.removeValue(forKey: identifier)
        }
        for identifier in connections.keys where !identifiers.contains(identifier) {
            connections[identifier]?.cancel()
        }
        // An accepted open still owns a booting guest even if display connection fails.
        // Only the catalog's stopped/missing devices without an in-flight operation release ownership.
        let running = Set(devices.filter { $0.state != 1 }.map(\.identity))
        ownedDeviceIdentifiers.formIntersection(running.union(pendingDeviceIdentifiers).union(pendingBeforeReading))
        // A restart's boot is not a new boot, so a window closed during the
        // restart stays closed.
        suppressed.formIntersection(identifiers.union(restarting.keys).union(restartsBeforeReading))
        connectionFailures = connectionFailures.filter { identifiers.contains($0.key) }
        if isHeadless { return }
        // A restarting device connects only after its restart ends, also when
        // its window was hidden meanwhile.
        for device in booted where restarting[device.identity] == nil
            && !presentationRestarts.contains(device.identity)
            && (sessions[device.identity] == nil || awaitingReconnect[device.identity] != nil)
            && connections[device.identity] == nil
            && !releasingDevices.contains(device.identity)
            && !suppressed.contains(device.identity)
            && connectionFailures[device.identity] == nil {
            connect(device)
        }
        if hadDeviceWindows && sessions.isEmpty && !isInProcess { onNoScreens?() }
        onChange?()
    }

    private var pendingDeviceIdentifiers: Set<SimulatorDeviceIdentifier> {
        openingDevices.union(bootOperations.keys).union(restarting.keys)
            .union(connections.keys).union(releasingDevices).union(presentationRestarts)
    }

    private func connect(_ record: SimulatorDeviceRecord) {
        let identifier = record.identity
        connections[identifier] = Task { [weak self] in
            guard let self else { return }
            defer {
                // Keep cancellation tracked until this task unwinds, so a new
                // boot cannot replace its entry before cleanup.
                connections.removeValue(forKey: identifier)
                rescan()
            }
            do {
                // Everything below reaches the guest through the device's own connection, which also serves later connections.
                let set = identifier.deviceSetPath == nil ? deviceSet : testingSet
                guard let device = try await set?.client(withIdentifier: identifier.identifier) else {
                    throw SimulatorError.operation("The selected simulator is no longer available")
                }
                try await attach(device, as: identifier)
            } catch is CancellationError {
            } catch SimulatorError.conflict(_) {
                handleHostConflict()
            } catch {
                connectionFailures[identifier] = error
                if !openingDevices.contains(identifier) { report(error) }
            }
        }
    }

    /// Connects `device`'s display, makes its session and presents it, opening before its optional services are ready.
    private func attach(_ device: SimulatorDevice, as identifier: SimulatorDeviceIdentifier) async throws {
        guard let presenter else { return }
        let connected = try await presenter.connectDisplay(DeviceConnectionRequest(device: device, runtime: runtime) { [weak self] in
            try Task.checkCancellation()
            guard let self, !stopped, !isTerminating, !suppressed.contains(identifier) else { throw CancellationError() }
            try conflicts.check()
        })
        try Task.checkCancellation()
        let available = Self.describe(device.record)
        let session = DeviceSession(
            device: available, capabilities: connected.capabilities,
            display: connected.display,
            tools: try DeviceTools(identifier: identifier.identifier, xcodeURL: runtime.xcodeURL,
                                   deviceSetPath: device.deviceSetPath, lookUp: device.lookUp),
            model: deviceRegistry.presentedModel(of: available, lastBootDate: device.lastBootDate,
                                                 ownerXcodeURL: runtime.xcodeURL, channel: device.channel),
            recordings: recordings, openLog: { [presenter] in try await presenter.openLog($0) },
            hostKeyboardLanguage: { [presenter] in presenter.hostKeyboardLanguage() },
            pasteboardSync: pasteboardSync, optionalServices: connected.optionalServices,
            externalDisplayChanges: externalDisplayChanges(of: device),
            appResizeTransport: { try await CoreDeviceAppResizeTransport.make(simulatorUDID: identifier.identifier) })
        try Task.checkCancellation()
        if let presentation = awaitingReconnect.removeValue(forKey: identifier) {
            try conflicts.check()
            presentation.reconnect(session, present: !isInProcess)
            finishConnecting(session)
            connected.startOptionalServices()
            return
        }
        let presentation = try presenter.makePresentation(of: session, offersLifetimeChoice: offersLifetimeChoice,
                                                          events: presentationEvents())
        try conflicts.check()
        sessions[identifier] = presentation
        if !isInProcess { presentation.showNew() }
        finishConnecting(session)
        connected.startOptionalServices()
    }

    private func presentationEvents() -> DevicePresentationEvents {
        var onShutDown: (@MainActor (any DevicePresentation) -> Void)?
        if isInProcess {
            onShutDown = { [weak self] presentation in self?.onShutDown?(presentation.session.device.identity) }
        }
        return DevicePresentationEvents(
            reportDetachedCapture: { [weak self] error in
                guard let self else { hostLog(error.localizedDescription); return }
                self.noteCaptureFailure(error)
            }, onClose: { [weak self] presentation, choice in
                self?.presentationClosed(presentation, choice: choice)
            }, onRestart: { [weak self] presentation, erasing in
                guard let self else { return }
                if self.isInProcess { self.onRestart?(presentation.session.device.identity, erasing) }
                else { self.restartDevice(presentation, erasing: erasing) }
            }, onShutDown: onShutDown)
    }

    /// Starts what a connected session does without holding its screen.
    private func finishConnecting(_ session: DeviceSession) {
        applyDebugSettings(of: session)
        session.refreshGuestState()
        applyKeyboardSettings(of: session)
        restoreLocation(of: session)
        connectAudioRoutes(of: session)
        session.startPasteboardSync()
        connectExternalDisplay(of: session)
    }

    /// Applies debug settings on each connection, which no screen waits for; logs failures.
    private func applyDebugSettings(of session: DeviceSession) {
        Task.immediate {
            do { try await session.applyDebugSettings() } catch {
                hostLog("Could not apply debug settings to \(session.device.name): \(error.localizedDescription)")
            }
        }
    }

    /// Applies keyboard settings asynchronously on each connection; logs failures.
    private func applyKeyboardSettings(of session: DeviceSession) {
        Task.immediate {
            await session.applyKeyboardSettings { error in
                hostLog("Could not apply keyboard settings to \(session.device.name): \(error.localizedDescription)")
            }
        }
    }

    /// Restores location asynchronously on each connection; logs failures.
    private func restoreLocation(of session: DeviceSession) {
        Task {
            do { try await session.restoreLocation() } catch {
                hostLog("Could not restore the simulated location of \(session.device.name): \(error.localizedDescription)")
            }
        }
    }

    /// Applies recent audio routes and observes the port; logs failures.
    private func connectAudioRoutes(of session: DeviceSession) {
        let name = session.device.name
        session.connectAudioRoutes { error in
            hostLog("Could not route the audio of \(name): \(error.localizedDescription)")
        }
    }

    /// The changes sent to `device`'s external display, which every session of
    /// the device shares.
    private func externalDisplayChanges(of device: SimulatorDevice) -> ExternalDisplayChanges {
        let changes = externalDisplayQueues[device.identity]?.changes ?? ExternalDisplayChanges()
        externalDisplayQueues[device.identity] = (device.name, changes)
        return changes
    }

    /// Connects the external display and restores its saved choice; logs failures.
    private func connectExternalDisplay(of session: DeviceSession) {
        session.connectExternalDisplay { error in hostLog(error.localizedDescription) }
    }

    // MARK: Closing and quitting

    /// Closes the device unless this close or DetachOnWindowClose requests keeping it booted.
    private func presentationClosed(_ presentation: any DevicePresentation, choice: DeviceLifetimeChoice?) {
        let session = presentation.session
        let identifier = session.device.identity
        sessions.removeValue(forKey: identifier)
        awaitingReconnect.removeValue(forKey: identifier)
        presentationRestarts.remove(identifier)
        ownedDeviceIdentifiers.remove(identifier)
        // A device left running keeps its window closed until it shuts down.
        suppressed.insert(identifier)
        disconnectedSessions.append(session)
        // A failed removal is logged, and the session stays for releasing the device or quitting to retry it.
        let removal = Task { try await finishInput(of: session) }
        let keepsRunning = choice.map { $0 == .keepRunning }
            ?? HostPreferences.defaults.bool(forKey: HostPreferences.detachOnWindowClose)
        if !isInProcess, !keepsRunning { shutDownClosedDevice(session, after: removal) }
        updateOwnership()
        if isInProcess {
            let finishing = Task {
                do { try await session.finishRecording() } catch { report(error) }
                try await removal.value
            }
            onClose?(identifier, choice, finishing)
            onChange?()
        }
        else if sessions.isEmpty { onNoScreens?() }
    }

    /// Shuts down a device whose window closed once its native input's removal ends and its recording is saved,
    /// abandoning a restart in progress.
    private func shutDownClosedDevice(_ session: DeviceSession, after removal: Task<Void, any Error>) {
        let identifier = session.device.identity
        // The restart stays tracked until it unwinds, so opening waits for it.
        let restart = restarting[identifier]
        restart?.cancel()
        bootOperations[identifier]?.cancel()
        guard closingShutdowns[identifier] == nil else { return }
        let tools: DeviceTools
        do {
            tools = try DeviceTools(identifier: identifier.identifier, xcodeURL: runtime.xcodeURL,
                                    deviceSetPath: session.tools.deviceSetPath)
        } catch {
            hostLog("Could not shut down \(identifier): \(error.localizedDescription)")
            return
        }
        closingShutdowns[identifier] = Task { [weak self] in
            _ = await removal.result
            await restart?.value
            do { try await session.finishRecording() } catch { hostLog(error.localizedDescription) }
            guard let self, !self.yieldedToAnotherHost,
                  !Task.isCancelled,
                  await self.isRunning(identifier.identifier, deviceSetPath: tools.deviceSetPath) else {
                self?.closingShutdowns.removeValue(forKey: identifier)
                self?.updateOwnership()
                return
            }
            // Reading the set can suspend until after another host takes ownership.
            guard !self.yieldedToAnotherHost, !Task.isCancelled else {
                self.closingShutdowns.removeValue(forKey: identifier)
                self.updateOwnership()
                return
            }
            do { try await tools.shutdown() } catch is CancellationError {
            } catch {
                hostLog("Could not shut down \(identifier): \(error.localizedDescription)")
            }
            self.closingShutdowns.removeValue(forKey: identifier)
            self.updateOwnership()
        }
    }

    /// Another host owns the devices now, so they keep running: no pending or
    /// later shutdown runs.
    package func yieldToAnotherHost() {
        yieldedToAnotherHost = true
        for shutdown in closingShutdowns.values { shutdown.cancel() }
        for shutdown in terminationShutdowns { shutdown.cancel() }
    }

    /// Whether shutdown is needed, now or, from a set that cannot answer, as the set last reported.
    private func isRunning(_ identifier: String, deviceSetPath: String?) async -> Bool {
        do { try await (deviceSetPath == nil ? deviceSet : testingSet)?.refresh() }
        catch { hostLog("Could not read the device set: \(error.localizedDescription)") }
        return wasLastRunning(identifier, deviceSetPath: deviceSetPath)
    }

    /// Stopped and already stopping devices need no action.
    private func wasLastRunning(_ identifier: String, deviceSetPath: String?) -> Bool {
        let set = deviceSetPath == nil ? deviceSet : testingSet
        guard let device = set?.devices.first(where: { $0.identifier == identifier }) else { return false }
        return device.state != 1 && device.state != 4
    }

    /// Waits up to TerminationTimeout for every external-display queue, including closed windows.
    /// Returns unfinished devices and logs power-off failures.
    private func finishExternalDisplayChanges() async -> [String] {
        let timeout = HostPreferences.defaults.double(forKey: HostPreferences.terminationTimeout)
        let deadline = ContinuousClock.now + .seconds(timeout)
        var failures: [String] = []
        for (name, changes) in externalDisplayQueues.values {
            guard await !changes.idle(before: deadline) else { continue }
            failures.append("The external display of \(name) did not turn off within \(Int(timeout)) seconds of quitting.")
        }
        return failures
    }

    /// Waits until a disconnected session has removed its native input, then lets it go. A session whose removal
    /// failed stays for the next release or quit.
    private func finishInput(of session: DeviceSession) async throws {
        try await session.stop()
        disconnectedSessions.removeAll { $0 === session }
    }

    /// Waits for the native input of the disconnected sessions, all or those of one device, retrying failed
    /// removals. Returns each session's failure.
    private func finishDisconnectedInput(of identifier: SimulatorDeviceIdentifier? = nil) async -> [String] {
        var failures: [String] = []
        let deadline = ContinuousClock.now + HostPreferences.terminationLimit
        for session in disconnectedSessions where identifier == nil || session.device.identity == identifier {
            let finishing = Task { try await finishInput(of: session) }
            // A quit does not wait on a device that stopped answering, which a retry could not get past either.
            if isTerminating, await !finishing.ends(before: deadline) {
                failures.append("\(session.device.name): its native input was not removed before the context stopped.")
                continue
            }
            do { try await finishing.value }
            catch { failures.append("\(session.device.name): \(error.localizedDescription)") }
        }
        return failures
    }

    /// Shuts down windowed devices and waits for closed-window shutdowns within TerminationTimeout.
    private func shutDownForTermination(_ devices: [(identifier: String, deviceSetPath: String?)]) async -> [String] {
        // Ownership is checked when the shutdowns start, after any wait.
        guard !yieldedToAnotherHost else { return [] }
        var failures: [String] = []
        var shutdowns = Array(closingShutdowns.values).map { shutdown in
            Task { () -> String? in await shutdown.value; return nil }
        }
        // A quit waits only briefly for a set that stopped answering: what it last reported decides then.
        for set in [deviceSet, testingSet].compactMap(\.self) {
            do { try await set.refresh(waitingAtMost: DeviceOperationLimit.terminationStopGrace) }
            catch { hostLog("Could not read the device set: \(error.localizedDescription)") }
        }
        guard !yieldedToAnotherHost else { return failures }
        for device in devices where wasLastRunning(device.identifier, deviceSetPath: device.deviceSetPath) {
            do {
                let tools = try DeviceTools(identifier: device.identifier, xcodeURL: runtime.xcodeURL,
                                            deviceSetPath: device.deviceSetPath)
                shutdowns.append(Task {
                    do { try await tools.shutdown() } catch is CancellationError {
                    } catch { return error.localizedDescription }
                    return nil
                })
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        let timeout = HostPreferences.defaults.double(forKey: HostPreferences.terminationTimeout)
        let started = shutdowns
        terminationShutdowns = started
        let deadline = Task { () -> Bool in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return false }
            for shutdown in started { shutdown.cancel() }
            for shutdown in self.closingShutdowns.values { shutdown.cancel() }
            return true
        }
        for shutdown in shutdowns { if let failure = await shutdown.value { failures.append(failure) } }
        deadline.cancel()
        if await deadline.value {
            failures.insert("Devices did not shut down within \(Int(timeout)) seconds of quitting.", at: 0)
        }
        return failures
    }

    // MARK: Restart

    package func restartHeadlessDevice(_ identifier: SimulatorDeviceIdentifier, erasing: Bool) async throws {
        guard restarting[identifier] == nil else {
            throw SimulatorError.operation("This simulator is already restarting.")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            restarting[identifier] = Task {
                defer { restarting.removeValue(forKey: identifier); rescan() }
                do {
                    let tools = try DeviceTools(identifier: identifier.identifier, xcodeURL: runtime.xcodeURL,
                                                deviceSetPath: identifier.deviceSetPath)
                    bootOperations[identifier] = tools
                    defer { bootOperations.removeValue(forKey: identifier) }
                    try await tools.restart(erasing: erasing)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Disconnects, shuts down, optionally erases, boots, and reconnects the existing window.
    package func restartDevice(_ controller: any DevicePresentation, erasing: Bool,
                               completion: ((Error?) -> Void)? = nil) {
        let identifier = controller.session.device.identity
        guard !stopped, sessions[identifier] === controller, restarting[identifier] == nil,
              bootOperations[identifier] == nil else {
            completion?(SimulatorError.operation("This simulator already has a device operation in progress."))
            return
        }
        let tools: DeviceTools
        do {
            tools = try DeviceTools(identifier: identifier.identifier, xcodeURL: runtime.xcodeURL,
                                    deviceSetPath: controller.session.tools.deviceSetPath)
        } catch {
            if let completion { completion(error) } else { controller.present(error) }
            return
        }
        // Holding the operation slot disables other device commands while
        // an active recording finishes.
        guard controller.session.reserve() else {
            completion?(SimulatorError.operation("This simulator already has a device operation in progress."))
            return
        }
        awaitingReconnect[identifier] = controller
        bootOperations[identifier] = tools
        restarting[identifier] = Task { [weak self] in
            await controller.prepareForRestart()
            var failure: Error?
            do {
                try Task.checkCancellation()
                try await tools.restart(erasing: erasing)
            } catch { failure = error }
            guard let self else { completion?(CancellationError()); return }
            self.bootOperations.removeValue(forKey: identifier)
            self.restarting.removeValue(forKey: identifier)
            // A window whose device is still down closes; a booted device reconnects.
            await self.rescanAndWait()
            if let completion { completion(failure); return }
            guard let failure, !(failure is CancellationError), !self.stopped else { return }
            // Cancelling a restart is part of closing its device, which reads the state next.
            if failure is DeviceRestartInterruption { hostLog(failure.localizedDescription); return }
            if self.sessions[identifier] === controller { controller.present(failure) } else { self.report(failure) }
        }
    }

    private func report(_ error: Error) {
        if let onError { onError(error) } else { hostLog(error.localizedDescription) }
    }

    /// A recording's or detached capture's failure. A stop in progress returns it. One that outlasted the stop that waited
    /// for it is reported now, since no other stop may come, and kept for the next, so that a retry cannot claim a clean finish.
    package func noteCaptureFailure(_ error: any Error) {
        guard isTerminating || stopped else { report(error); return }
        recordingTerminationErrors.append(error)
        if stopped, stoppingTask == nil { report(error) }
    }

    private func takeRecordingTerminationErrors() -> [any Error] {
        defer { recordingTerminationErrors.removeAll() }
        return recordingTerminationErrors
    }

    /// What a stop says of recordings and captures, once each: a capture's failure that outlasted a stop is also kept by the capture.
    private func distinctMessages(_ failures: [any Error]) -> [String] {
        var seen = Set<String>()
        return failures.map(\.localizedDescription).filter { seen.insert($0).inserted }
    }

    /// For a caller that has told the user what a stop threw: the next stop does not repeat those unsaved captures.
    package func acknowledgeCaptureFailures() { presenter?.acknowledgeCaptureFailures() }

    package func handleHostConflict() {
        guard !stopped, let name = conflicts.conflictingHostName else { return }
        yieldToAnotherHost()
        guard !isTerminating else { return }
        isTerminating = true
        cancelStateWaits()
        onConflictBegan?(name)
        Task {
            var failure: (any Error)?
            do { try await stop(keepingDevicesRunning: true) }
            catch { failure = error }
            if let onConflict {
                onConflict(name, failure)
            } else {
                let detail = failure.map { "\n\($0.localizedDescription)" } ?? ""
                report(SimulatorError.conflict("\(name) is now displaying the simulators.\(detail)"))
            }
        }
    }

    /// Finishes presentation resources without terminating the owning application. Stopping again retries the
    /// native input that an earlier stop could not remove.
    /// The headless backend remains responsible for guest lifetime in integrated mode.
    package func stop(keepingDevicesRunning: Bool? = nil) async throws {
        try await beginStopping(keepingDevicesRunning: keepingDevicesRunning).value
    }

    /// Freezes the shutdown targets before the shell cancels open requests and their ownership cleanup.
    package func beginStopping(keepingDevicesRunning: Bool? = nil) -> Task<Void, any Error> {
        if let stoppingTask { return stoppingTask }
        isTerminating = true
        cancelStateWaits()
        // Thumbnails end before this returns; what they hold is saved while the rest of stopping goes on.
        presenter?.beginFinishingCaptures()
        let retryingCleanup = stopped
        let keepsRunning = isInProcess || (keepingDevicesRunning
            ?? HostPreferences.defaults.bool(forKey: HostPreferences.detachOnAppQuit))
        let devices = keepsRunning ? [] : ownedDeviceIdentifiers.union(sessions.keys).sorted().map {
            (identifier: $0.identifier, deviceSetPath: $0.deviceSetPath)
        }
        let task = Task {
            defer { stoppingTask = nil }
            if retryingCleanup {
                let inputFailures = await finishDisconnectedInput()
                let recordingFailures = await recordings.finishAll()
                let captureFailures = await finishCaptures()
                let failures = inputFailures + (await finishExternalDisplayChanges()) + (await finishObservationRemovals())
                    + distinctMessages(recordingFailures + captureFailures + takeRecordingTerminationErrors())
                if !failures.isEmpty { throw SimulatorError.operation(failures.joined(separator: "\n")) }
            } else {
                try await finishStopping(devices: devices)
            }
        }
        stoppingTask = task
        return task
    }

    /// Ends the stop of captures that `beginStopping` began, along with any handed over since.
    private func finishCaptures() async -> [any Error] {
        await presenter?.finishCaptures(before: .now + (captureFinishLimit ?? HostPreferences.terminationLimit)) ?? []
    }

    private func finishStopping(devices: [(identifier: String, deviceSetPath: String?)]) async throws {
        var failures: [String] = []
        let pending = Array(connections.values) + Array(restarting.values)
        pending.forEach { $0.cancel() }
        bootOperations.values.forEach { $0.cancel() }
        let deadline = ContinuousClock.now + HostPreferences.terminationLimit
        for task in pending where await !task.ends(before: deadline) {
            failures.append("A device's connection or restart had not finished before the context stopped.")
        }
        for controller in sessions.values { controller.invalidate() }
        disconnectedSessions += sessions.values.map(\.session)
        let recordingFailures = await recordings.finishAll()
        sessions.removeAll()
        awaitingReconnect.removeAll()
        presentationRestarts.removeAll()
        let inputFailures = await finishDisconnectedInput()
        let displayFailures = await finishExternalDisplayChanges()
        failures += inputFailures + displayFailures + (await shutDownForTermination(devices))
        let captureFailures = recordingFailures + (await finishCaptures())
        shutdown()
        failures += await finishObservationRemovals()
        onChange?()
        // Taken last: what fails from here on has outlasted this stop.
        let allCaptureFailures = distinctMessages(captureFailures + takeRecordingTerminationErrors())
        if !failures.isEmpty || !allCaptureFailures.isEmpty {
            throw SimulatorError.operation((failures + allCaptureFailures).joined(separator: "\n"))
        }
    }

    private func finishObservationRemovals() async -> [String] {
        let deadline = ContinuousClock.now + DeviceOperationLimit.terminationStopGrace
        var unfinished: [Task<Void, Never>] = []
        for removal in observationRemovals where await !removal.ends(before: deadline) {
            unfinished.append(removal)
        }
        observationRemovals = unfinished
        return unfinished.isEmpty ? [] : ["A device-set observation had not been removed before the context stopped."]
    }

    package func shutdown() {
        guard !stopped else { return }
        stopped = true
        cancelStateWaits()
        conflicts.onConflict = nil
        touchIndicatorObservation = nil
        testingDevicesObservation = nil
        if let notificationToken { observationRemovals.append(deviceSet.stopObserving(notificationToken)) }
        notificationToken = nil
        if let testingSet, let testingNotificationToken {
            observationRemovals.append(testingSet.stopObserving(testingNotificationToken))
        }
        testingNotificationToken = nil
        for follower in healthFollowers.values { follower.cancel() }
        healthFollowers.removeAll()
        rescanRequest = nil
        rescanning?.cancel()
        testingSetWatcher?.cancel()
        testingSetWatcher = nil
        for task in connections.values { task.cancel() }
        connections.removeAll()
        for tools in bootOperations.values { tools.cancel() }
        bootOperations.removeAll()
        for task in restarting.values { task.cancel() }
        restarting.removeAll()
        awaitingReconnect.removeAll()
        presentationRestarts.removeAll()
        for session in sessions.values { session.invalidate() }
        disconnectedSessions += sessions.values.map(\.session)
        sessions.removeAll()
    }
}


/// Why a booted device's integrated screen did not appear in time: what reading its screens last failed with, and which
/// native requests had still not returned then. Another device's unanswered request can be the reason, since a device's own
/// connection does not separate it from what holds CoreSimulatorService itself or SimulatorKit.
package struct IntegratedScreenUnavailable: LocalizedError {
    package let deviceName: String
    package let lastFailure: (any Error)?
    package let unanswered: [UnresolvedDeviceOperation]

    package init(deviceName: String, lastFailure: (any Error)?, hub: DeviceIOHub = .shared) async {
        self.deviceName = deviceName
        self.lastFailure = lastFailure
        unanswered = await hub.unresolvedOperations().filter { $0.state == .running }
    }

    package var errorDescription: String? {
        (["No integrated screen became available for \(deviceName)."] + [lastFailure?.localizedDescription].compactMap(\.self)
            + unanswered.map(\.description)).joined(separator: "\n")
    }
}

/// An open may return after cancellation with a newly attached screen. Its cleanup must finish uncancelled.
@MainActor
package func withScreenOpenCleanup<Value>(preservingExisting: Bool,
                                 operation: () async throws -> Value,
                                 cleanup: @escaping @MainActor () async throws -> Void) async throws -> Value {
    do {
        let value = try await operation()
        try Task.checkCancellation()
        return value
    } catch {
        if Task.isCancelled, !preservingExisting {
            let openingError = error
            do { try await Task { try await cleanup() }.value }
            catch {
                throw SimulatorError.operation("\(openingError.localizedDescription)\nOpening cleanup failed: \(error.localizedDescription)")
            }
        }
        throw error
    }
}
