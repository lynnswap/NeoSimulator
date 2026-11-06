import NeoSimulatorKit
import AppKit
import Observation

@MainActor @Observable
package final class NewSimulatorModel {
    package struct ExistingDevice {
        package let identifier: String
        package let name: String
        package let productFamily: String
        package let deviceType: String
        package let runtime: String

        package init(identifier: String, name: String, productFamily: String, deviceType: String, runtime: String) {
            self.identifier = identifier
            self.name = name
            self.productFamily = productFamily
            self.deviceType = deviceType
            self.runtime = runtime
        }
    }

    package typealias Create = @MainActor (_ name: String, _ deviceType: String, _ runtime: String) async throws -> String
    package typealias Pair = @MainActor (_ watch: String, _ phone: String) async throws -> Void

    package let catalog: SimulatorCatalog
    package let existingDevice: ExistingDevice?
    private let preferences: SimulatorPreferences?
    private let create: Create
    private let pair: Pair
    package var name = ""
    package var watchName = ""
    package private(set) var category: DeviceCategory?
    package private(set) var deviceType: String?
    package private(set) var runtime: String?
    package private(set) var watchType: String?
    package private(set) var watchRuntime: String?
    package private(set) var availableWatchRuntimes: [SimulatorCatalog.Runtime] = []
    private var runtimeNames: [String: String] = [:]
    package private(set) var addsWatch = false
    package private(set) var showsWatchPage = false
    package private(set) var isCreating = false
    package private(set) var message: String?
    package var error: String?
    @ObservationIgnored package var onCreated: (() -> Void)?
    @ObservationIgnored package var onFailure: ((Error) -> Void)?
    package var onCancel: (() -> Void)?
    @ObservationIgnored private var creation: Task<Void, Never>?
    @ObservationIgnored private var runtimeNameLoading: Task<Void, Never>?

    package var showsError: Bool {
        get { error != nil }
        set { if !newValue { error = nil } }
    }

    package func startLoadingRuntimeNames() {
        guard runtimeNameLoading == nil else { return }
        runtimeNameLoading = Task { [weak self] in await self?.loadRuntimeNames() }
    }

    package init(catalog: SimulatorCatalog, pairingWith existingDevice: ExistingDevice? = nil,
         create: @escaping Create, pair: @escaping Pair, preferences: SimulatorPreferences? = nil) {
        self.catalog = catalog
        self.existingDevice = existingDevice
        self.create = create
        self.pair = pair
        self.preferences = preferences
        let saved = preferences?.newSimulatorCategory
        category = categories.contains(where: { $0.id == saved }) ? saved : categories.first?.id
        let savedWatchType = preferences?.newSimulatorDeviceType(for: .appleWatch)
        let savedWatchRuntime = preferences?.newSimulatorRuntime(for: .appleWatch)
        resetSimulatorSelection()
        watchType = watchTypes.first?.identifier
        availableWatchRuntimes = catalog.runtimes.filter { runtime in
            watchTypes.contains { watchRuntimeSupports(runtime.identifier, type: $0.identifier) }
        }
        watchRuntime = availableWatchRuntimes.first?.identifier
        updateWatchRuntime(watchRuntime)
        restoreWatchSelection(deviceType: savedWatchType, runtime: savedWatchRuntime)
        showsWatchPage = existingDevice != nil && !createsPhone
    }

    package var createsPhone: Bool { existingDevice?.productFamily == "Apple Watch" }
    package var title: String {
        existingDevice.map { $0.productFamily == "Apple Watch" ? "New iPhone Simulator" : "New Watch Simulator" }
            ?? "New Simulator"
    }
    package var heading: String {
        existingDevice.map { "Create \(createsPhone ? "an iPhone" : "an Apple Watch") for \($0.name)" }
            ?? "Create a new simulator"
    }
    package var categories: [(id: DeviceCategory, name: String)] {
        var seen: Set<DeviceCategory> = []
        var categories = catalog.deviceTypes.compactMap { type -> (id: DeviceCategory, name: String)? in
            guard seen.insert(type.category).inserted else { return nil }
            let name: String = switch type.category {
            case .iPhone: "iPhone"
            case .iPhoneDuo: "iPhone Duo"
            case .iPad: "iPad"
            case .appleTV: "Apple TV"
            case .appleWatch: "Apple Watch"
            case .appleVision: "Apple Vision Pro"
            default: type.name
            }
            return (type.category, name)
        }
        // Keeps iPhone as the default category and Duo beside it, wherever the catalog lists Duo.
        if let duo = categories.firstIndex(where: { $0.id == .iPhoneDuo }) {
            let category = categories.remove(at: duo)
            categories.insert(category, at: categories.firstIndex { $0.id == .iPhone }.map { $0 + 1 } ?? duo)
        }
        return categories
    }
    package var deviceTypes: [SimulatorCatalog.DeviceType] {
        catalog.deviceTypes.filter { type in
            if existingDevice == nil { return type.category == category }
            return !createsPhone || (type.productFamily == 1 && catalog.runtimes.contains {
                simulatorRuntimeSupports($0.identifier, type: type.identifier)
            })
        }
    }
    package var runtimes: [SimulatorCatalog.Runtime] {
        // A companion iPhone has no category picker, so its selected model keeps same-version runtimes apart.
        let modelCategory = deviceType.flatMap(catalog.deviceType)?.category
        return catalog.runtimes.filter { runtime in
            if existingDevice == nil {
                return deviceTypes.contains { catalog.runtime(runtime.identifier, supports: $0.identifier) }
            }
            return !createsPhone || deviceTypes.contains {
                $0.category == modelCategory && simulatorRuntimeSupports(runtime.identifier, type: $0.identifier)
            }
        }
    }
    package func runtimeName(_ runtime: SimulatorCatalog.Runtime) -> String {
        guard let build = runtime.buildVersion else { return runtime.name }
        return "\(runtimeNames[build] ?? runtime.name) (\(build))"
    }

    package func loadRuntimeNames(using load: @Sendable () async throws -> Data = {
        let url = URL(string: "https://devimages-cdn.apple.com/downloads/xcode/simulators/index2.dvtdownloadableindex")!
        return try await URLSession.shared.data(from: url).0
    }) async {
        guard catalog.runtimes.contains(where: { $0.buildVersion != nil }),
              let data = try? await load(),
              let names = try? await SimulatorCatalog.RuntimeNames.decode(data),
              !Task.isCancelled else { return }
        runtimeNames = names
    }

    package var watchTypes: [SimulatorCatalog.DeviceType] {
        catalog.deviceTypes.filter { type in
            type.productFamily == 4 && (existingDevice == nil || catalog.runtimes.contains {
                watchRuntimeSupports($0.identifier, type: type.identifier)
            })
        }
    }
    package var deviceNamePlaceholder: String { deviceType.flatMap(catalog.deviceType)?.name ?? "" }
    package var watchNamePlaceholder: String { watchType.flatMap(catalog.deviceType)?.name ?? "" }
    package var canAddWatch: Bool { existingDevice == nil && deviceType.flatMap(catalog.deviceType)?.productFamily == 1 }
    package var pairsWatch: Bool { (existingDevice != nil && !createsPhone) || (canAddWatch && addsWatch) }
    package var forwardTitle: String { pairsWatch && !showsWatchPage ? "Next" : "Create" }
    package var canProceed: Bool {
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

    package func selectCategory(_ value: DeviceCategory?) {
        category = value
        preferences?.newSimulatorCategory = value
        resetSimulatorSelection()
    }
    private func resetSimulatorSelection() {
        let selectionCategory = createsPhone ? .iPhone : category
        let savedDeviceType = selectionCategory.flatMap { preferences?.newSimulatorDeviceType(for: $0) }
        let savedRuntime = selectionCategory.flatMap { preferences?.newSimulatorRuntime(for: $0) }
        deviceType = deviceTypes.first?.identifier
        runtime = runtimes.first?.identifier
        updateRuntime(runtime)
        restoreSimulatorSelection(deviceType: savedDeviceType, runtime: savedRuntime)
        if !canAddWatch { addsWatch = false }
    }

    private func restoreSimulatorSelection(deviceType savedDeviceType: String?, runtime savedRuntime: String?) {
        if let savedDeviceType, deviceTypes.contains(where: { $0.identifier == savedDeviceType }),
           catalog.runtimes.contains(where: { simulatorRuntimeSupports($0.identifier, type: savedDeviceType) }) {
            updateDeviceType(savedDeviceType)
        }
        if let savedRuntime, let deviceType, simulatorRuntimeSupports(savedRuntime, type: deviceType) {
            updateRuntime(savedRuntime)
        }
    }
    package func selectDeviceType(_ value: String?) {
        updateDeviceType(value)
        saveSimulatorSelection()
    }

    private func updateDeviceType(_ value: String?) {
        deviceType = value
        if let value, runtime.map({ simulatorRuntimeSupports($0, type: value) }) != true {
            runtime = runtimes.first(where: { simulatorRuntimeSupports($0.identifier, type: value) })?.identifier
        }
        if !canAddWatch { addsWatch = false }
    }
    package func selectRuntime(_ value: String?) {
        updateRuntime(value)
        saveSimulatorSelection()
    }

    private func updateRuntime(_ value: String?) {
        runtime = value
        if let value, deviceType.map({ simulatorRuntimeSupports(value, type: $0) }) != true {
            deviceType = deviceTypes.first(where: { simulatorRuntimeSupports(value, type: $0.identifier) })?.identifier
        }
        if !canAddWatch { addsWatch = false }
    }

    private func saveSimulatorSelection() {
        guard let category = deviceType.flatMap(catalog.deviceType)?.category else { return }
        preferences?.setNewSimulatorSelection(deviceType: deviceType, runtime: runtime, for: category)
    }

    package func setAddsWatch(_ value: Bool) { addsWatch = canAddWatch && value }
    package func selectWatchType(_ value: String?) {
        updateWatchType(value)
        saveWatchSelection()
    }

    private func updateWatchType(_ value: String?) {
        watchType = value
        if let value, watchRuntime.map({ watchRuntimeSupports($0, type: value) }) != true {
            availableWatchRuntimes = catalog.runtimes.filter { watchRuntimeSupports($0.identifier, type: value) }
            watchRuntime = availableWatchRuntimes.first?.identifier
        }
    }
    package func selectWatchRuntime(_ value: String?) {
        updateWatchRuntime(value)
        saveWatchSelection()
    }

    private func updateWatchRuntime(_ value: String?) {
        watchRuntime = value
        if let value, watchType.map({ watchRuntimeSupports(value, type: $0) }) != true {
            watchType = watchTypes.first(where: { watchRuntimeSupports(value, type: $0.identifier) })?.identifier
        }
    }

    private func restoreWatchSelection(deviceType savedWatchType: String?, runtime savedWatchRuntime: String?) {
        if let savedWatchType, watchTypes.contains(where: { $0.identifier == savedWatchType }),
           catalog.runtimes.contains(where: { watchRuntimeSupports($0.identifier, type: savedWatchType) }) {
            updateWatchType(savedWatchType)
        }
        if let savedWatchRuntime, let watchType, watchRuntimeSupports(savedWatchRuntime, type: watchType) {
            updateWatchRuntime(savedWatchRuntime)
        }
    }

    private func saveWatchSelection() {
        preferences?.setNewSimulatorSelection(deviceType: watchType, runtime: watchRuntime, for: .appleWatch)
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

    package func restoreInput(from previous: NewSimulatorModel) {
        name = previous.name
        watchName = previous.watchName
        if categories.contains(where: { $0.id == previous.category }) {
            category = previous.category
            resetSimulatorSelection()
        }
        restoreSimulatorSelection(deviceType: previous.deviceType, runtime: previous.runtime)
        restoreWatchSelection(deviceType: previous.watchType, runtime: previous.watchRuntime)
        setAddsWatch(previous.addsWatch)
        showsWatchPage = previous.showsWatchPage && pairsWatch
    }
    package func previous() { showsWatchPage = false }
    package func forward() {
        guard canProceed else { return }
        if pairsWatch && !showsWatchPage { showsWatchPage = true }
        else { createSimulator() }
    }
    package func waitForCreation() async { await creation?.value }

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
                        throw SimulatorError.operation("Created “\(newDevice.name)” (\(identifier)), but could not pair it with “\(existingDevice.name)”: \(error.localizedDescription)")
                    }
                } else if let watch {
                    let watchIdentifier: String
                    do { watchIdentifier = try await create(watch.name, watch.type, watch.runtime) }
                    catch { throw SimulatorError.operation("Created “\(newDevice.name)”, but could not create its paired Apple Watch: \(error.localizedDescription)") }
                    do { try await pair(watchIdentifier, identifier) }
                    catch { throw SimulatorError.operation("Created “\(newDevice.name)” and “\(watch.name)”, but could not pair them: \(error.localizedDescription)") }
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
