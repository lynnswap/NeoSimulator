import AppKit
import Observation

@MainActor @Observable
final class NewSimulatorModel {
    struct ExistingDevice {
        let identifier: String
        let name: String
        let productFamily: String
        let deviceType: String
        let runtime: String
    }

    typealias Create = @MainActor (_ name: String, _ deviceType: String, _ runtime: String) async throws -> String
    typealias Pair = @MainActor (_ watch: String, _ phone: String) async throws -> Void

    let catalog: SimulatorCatalog
    let existingDevice: ExistingDevice?
    private let preferences: SimulatorPreferences?
    private let create: Create
    private let pair: Pair
    var name = ""
    var watchName = ""
    private(set) var family: Int?
    private(set) var deviceType: String?
    private(set) var runtime: String?
    private(set) var watchType: String?
    private(set) var watchRuntime: String?
    private(set) var availableWatchRuntimes: [SimulatorCatalog.Runtime] = []
    private(set) var addsWatch = false
    private(set) var showsWatchPage = false
    private(set) var isCreating = false
    private(set) var message: String?
    var error: String?
    @ObservationIgnored var onCreated: (() -> Void)?
    @ObservationIgnored var onFailure: ((Error) -> Void)?
    var onCancel: (() -> Void)?
    @ObservationIgnored private var creation: Task<Void, Never>?

    init(catalog: SimulatorCatalog, pairingWith existingDevice: ExistingDevice? = nil,
         create: @escaping Create, pair: @escaping Pair, preferences: SimulatorPreferences? = nil) {
        self.catalog = catalog
        self.existingDevice = existingDevice
        self.create = create
        self.pair = pair
        self.preferences = preferences
        let saved = preferences?.newSimulatorFamily
        family = families.contains(where: { $0.id == saved }) ? saved : families.first?.id
        resetSimulatorSelection()
        watchType = watchTypes.first?.identifier
        availableWatchRuntimes = catalog.runtimes.filter { runtime in
            watchTypes.contains { watchRuntimeSupports(runtime.identifier, type: $0.identifier) }
        }
        watchRuntime = availableWatchRuntimes.first?.identifier
        selectWatchRuntime(watchRuntime)
        showsWatchPage = existingDevice != nil && !createsPhone
    }

    var createsPhone: Bool { existingDevice?.productFamily == "Apple Watch" }
    var title: String {
        existingDevice.map { $0.productFamily == "Apple Watch" ? "New iPhone Simulator" : "New Watch Simulator" }
            ?? "New Simulator"
    }
    var heading: String {
        existingDevice.map { "Create \(createsPhone ? "an iPhone" : "an Apple Watch") for \($0.name)" }
            ?? "Create a new simulator"
    }
    var families: [(id: Int, name: String)] {
        var seen: Set<Int> = []
        return catalog.deviceTypes.compactMap { type in
            guard seen.insert(type.productFamily).inserted else { return nil }
            let name: String = switch type.productFamily {
            case 1: "iPhone"
            case 2: "iPad"
            case 3: "Apple TV"
            case 4: "Apple Watch"
            case 7: "Apple Vision Pro"
            default: type.name
            }
            return (type.productFamily, name)
        }
    }
    var deviceTypes: [SimulatorCatalog.DeviceType] {
        catalog.deviceTypes.filter { type in
            if existingDevice == nil { return type.productFamily == family }
            return !createsPhone || (type.productFamily == 1 && catalog.runtimes.contains {
                simulatorRuntimeSupports($0.identifier, type: type.identifier)
            })
        }
    }
    var runtimes: [SimulatorCatalog.Runtime] {
        catalog.runtimes.filter { runtime in
            if existingDevice == nil {
                return deviceTypes.contains { catalog.runtime(runtime.identifier, supports: $0.identifier) }
            }
            return !createsPhone || deviceTypes.contains { simulatorRuntimeSupports(runtime.identifier, type: $0.identifier) }
        }
    }
    var watchTypes: [SimulatorCatalog.DeviceType] {
        catalog.deviceTypes.filter { type in
            type.productFamily == 4 && (existingDevice == nil || catalog.runtimes.contains {
                watchRuntimeSupports($0.identifier, type: type.identifier)
            })
        }
    }
    var deviceNamePlaceholder: String { deviceType.flatMap(catalog.deviceType)?.name ?? "" }
    var watchNamePlaceholder: String { watchType.flatMap(catalog.deviceType)?.name ?? "" }
    var canAddWatch: Bool { existingDevice == nil && deviceType.flatMap(catalog.deviceType)?.productFamily == 1 }
    var pairsWatch: Bool { (existingDevice != nil && !createsPhone) || (canAddWatch && addsWatch) }
    var forwardTitle: String { pairsWatch && !showsWatchPage ? "Next" : "Create" }
    var canProceed: Bool {
        guard !isCreating else { return false }
        if existingDevice != nil || showsWatchPage { return canPair }
        return deviceType.flatMap { type in runtime.map { simulatorRuntimeSupports($0, type: type) } } == true
    }
    private var canPair: Bool {
        guard let phone = createsPhone ? deviceType : existingDevice?.deviceType ?? deviceType,
              let phoneRuntime = createsPhone ? runtime : existingDevice?.runtime ?? runtime,
              let watch = createsPhone ? existingDevice?.deviceType : watchType,
              let watchRuntime = createsPhone ? existingDevice?.runtime : watchRuntime,
              catalog.runtime(watchRuntime, supports: watch) else { return false }
        return catalog.canPair(watch, watchRuntime, phone, phoneRuntime)
    }

    func selectFamily(_ value: Int?) {
        family = value
        preferences?.newSimulatorFamily = value
        resetSimulatorSelection()
    }
    private func resetSimulatorSelection() {
        deviceType = deviceTypes.first?.identifier
        runtime = runtimes.first?.identifier
        selectRuntime(runtime)
        if !canAddWatch { addsWatch = false }
    }
    func selectDeviceType(_ value: String?) {
        deviceType = value
        if let value, runtime.map({ simulatorRuntimeSupports($0, type: value) }) != true {
            runtime = runtimes.first(where: { simulatorRuntimeSupports($0.identifier, type: value) })?.identifier
        }
        if !canAddWatch { addsWatch = false }
    }
    func selectRuntime(_ value: String?) {
        runtime = value
        if let value, deviceType.map({ simulatorRuntimeSupports(value, type: $0) }) != true {
            deviceType = deviceTypes.first(where: { simulatorRuntimeSupports(value, type: $0.identifier) })?.identifier
        }
        if !canAddWatch { addsWatch = false }
    }
    func setAddsWatch(_ value: Bool) { addsWatch = canAddWatch && value }
    func selectWatchType(_ value: String?) {
        watchType = value
        if let value, watchRuntime.map({ watchRuntimeSupports($0, type: value) }) != true {
            availableWatchRuntimes = catalog.runtimes.filter { watchRuntimeSupports($0.identifier, type: value) }
            watchRuntime = availableWatchRuntimes.first?.identifier
        }
    }
    func selectWatchRuntime(_ value: String?) {
        watchRuntime = value
        if let value, watchType.map({ watchRuntimeSupports(value, type: $0) }) != true {
            watchType = watchTypes.first(where: { watchRuntimeSupports(value, type: $0.identifier) })?.identifier
        }
    }
    private func simulatorRuntimeSupports(_ runtime: String, type: String) -> Bool {
        guard catalog.runtime(runtime, supports: type) else { return false }
        guard let existingDevice, createsPhone else { return true }
        return catalog.canPair(existingDevice.deviceType, existingDevice.runtime, type, runtime)
    }
    private func watchRuntimeSupports(_ runtime: String, type: String) -> Bool {
        guard catalog.runtime(runtime, supports: type) else { return false }
        guard let existingDevice, !createsPhone else { return true }
        return catalog.canPair(type, runtime, existingDevice.deviceType, existingDevice.runtime)
    }

    func restoreInput(from previous: NewSimulatorModel) {
        name = previous.name
        watchName = previous.watchName
        if families.contains(where: { $0.id == previous.family }) {
            family = previous.family
            resetSimulatorSelection()
        }
        if deviceTypes.contains(where: { $0.identifier == previous.deviceType }) { selectDeviceType(previous.deviceType) }
        if let value = previous.runtime, let type = deviceType, simulatorRuntimeSupports(value, type: type) {
            selectRuntime(value)
        }
        if watchTypes.contains(where: { $0.identifier == previous.watchType }) { selectWatchType(previous.watchType) }
        if let value = previous.watchRuntime, let type = watchType, watchRuntimeSupports(value, type: type) {
            selectWatchRuntime(value)
        }
        setAddsWatch(previous.addsWatch)
        showsWatchPage = previous.showsWatchPage && pairsWatch
    }
    func previous() { showsWatchPage = false }
    func forward() {
        guard canProceed else { return }
        if pairsWatch && !showsWatchPage { showsWatchPage = true }
        else { createSimulator() }
    }
    func waitForCreation() async { await creation?.value }

    private func createSimulator() {
        let newDevice: (name: String, type: String, runtime: String)
        if existingDevice != nil, !createsPhone {
            guard let watchType, let watchRuntime else { return }
            newDevice = (watchName.isEmpty ? watchNamePlaceholder : watchName, watchType, watchRuntime)
        } else {
            guard let deviceType, let runtime else { return }
            newDevice = (name.isEmpty ? deviceNamePlaceholder : name, deviceType, runtime)
        }
        let watch: (name: String, type: String, runtime: String)?
        if existingDevice == nil, pairsWatch, let watchType, let watchRuntime {
            watch = (watchName.isEmpty ? watchNamePlaceholder : watchName, watchType, watchRuntime)
        } else { watch = nil }
        isCreating = true
        message = nil
        error = nil
        creation = Task {
            defer { isCreating = false; creation = nil }
            do {
                let identifier = try await create(newDevice.name, newDevice.type, newDevice.runtime)
                if let existingDevice {
                    do {
                        if createsPhone { try await pair(existingDevice.identifier, identifier) }
                        else { try await pair(identifier, existingDevice.identifier) }
                    } catch {
                        throw HostError.operation("Created “\(newDevice.name)” (\(identifier)), but could not pair it with “\(existingDevice.name)”: \(error.localizedDescription)")
                    }
                } else if let watch {
                    let watchIdentifier: String
                    do { watchIdentifier = try await create(watch.name, watch.type, watch.runtime) }
                    catch { throw HostError.operation("Created “\(newDevice.name)”, but could not create its paired Apple Watch: \(error.localizedDescription)") }
                    do { try await pair(watchIdentifier, identifier) }
                    catch { throw HostError.operation("Created “\(newDevice.name)” and “\(watch.name)”, but could not pair them: \(error.localizedDescription)") }
                }
                message = watch.map { "Created “\(newDevice.name)” and “\($0.name)”." } ?? "Created “\(newDevice.name)”."
                showsWatchPage = false
                onCreated?()
            } catch {
                if let onFailure { onFailure(error) }
                else { self.error = error.localizedDescription }
            }
        }
    }
}
