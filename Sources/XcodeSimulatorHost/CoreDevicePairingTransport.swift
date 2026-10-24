import ABIBridge
import Darwin
import Foundation

@MainActor
final class CoreDevicePairingTransport: DevicePairingTransport {
    private typealias PINHandler = (Bool, Double?) async throws -> String
    private let manager: NativeSwiftValue
    private let initialize: NativeSwiftMethod<() async -> Void>
    private let readDevices: NativeSwiftMethod<() -> [UUID: NativeSwiftValue]>
    private let changes: NativeSwiftMethod<() -> NativeSwiftValue>
    private let supports: NativeSwiftMethod<(String) -> Bool>
    private let deviceInfo: NativeSwiftMethod<() -> NativeSwiftValue>
    private let readName: NativeSwiftMethod<() -> String?>
    private let readModel: NativeSwiftMethod<() -> String?>
    private let readOS: NativeSwiftMethod<() -> String?>
    private let readPairingState: NativeSwiftMethod<() -> NativeSwiftValue>
    private let stateName: NativeSwiftMethod<() -> String>
    private let pairDevice: NativeSwiftMethod<(NativeSwiftClosure<PINHandler>) async throws -> Void>
    private var beacon: CoreDevicePairingBeacon?
    private var discoveryTask: Task<Void, Never>?
    private var devicesChanged: (@MainActor ([NearbyPairingDevice]) -> Void)?
    private var reportIssue: (@MainActor (String) -> Void)?
    private var running = false

    init() throws {
        guard dlopen("/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice", RTLD_NOW | RTLD_LOCAL) != nil else {
            throw CLIError.unavailable("coredevice-runtime", "CoreDevice could not be loaded.")
        }
        let runtime = ABIRuntime.shared
        let managerType = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice.DeviceManager")
        let service = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice.CoreDeviceService")
        let connection = try service.resolveAndWait(.staticGetter("sharedConnection", as: (() -> NativeSwiftValue).self))
        let visibility = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice.DeviceVisibilityClass")
        let allowed = try [visibility.makeEnumCase(named: "default"), visibility.makeEnumCase(named: "wirelessPairableDevices")]
        let make = try managerType.resolveAndWait(.initializer("init(serviceConnection:allowedDeviceVisibilityClasses:)",
            as: ((NativeSwiftValue, [NativeSwiftValue]) -> NativeSwiftValue).self))
        manager = try unsafe make.unsafeInvoke(connection.unsafeInvoke(), allowed)
        initialize = try managerType.resolveAndWait(.method("awaitFullInitialization()", as: (() async -> Void).self))
        readDevices = try managerType.resolveAndWait(.getter("devices", as: (() -> [UUID: NativeSwiftValue]).self))
        let remote = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice.RemoteDevice")
        let dictionary = try runtime.resolveSwiftTypeAndWait(named: "Swift.Dictionary",
            genericArguments: [.type(UUID.self), .type(remote)])
        let stream = try runtime.resolveSwiftTypeAndWait(named: "Swift.AsyncThrowingStream",
            genericArguments: [.type(dictionary), .type((any Error).self)])
        // The SDK declares AsyncThrowingStream without @frozen, so the getter returns it indirectly.
        changes = try managerType.resolveAndWait(.getter("deviceChanges", as: (() -> NativeSwiftValue).self,
            valueABIs: [stream: try .opaque(named: stream.name)]))
        supports = try remote.resolveAndWait(.method("supportsFeature(identifiedBy:)", as: ((String) -> Bool).self))
        deviceInfo = try remote.resolveAndWait(.getter("deviceInfo", as: (() -> NativeSwiftValue).self))
        pairDevice = try remote.resolveAndWait(.method("pair(enteringPINUsing:)",
            as: ((NativeSwiftClosure<PINHandler>) async throws -> Void).self))
        let info = try runtime.resolveSwiftTypeAndWait(named: "CoreDeviceProtocols.DeviceInfo")
        let infoABI = try NativeType.opaque(named: info.name)
        readName = try info.resolveAndWait(.getter("name", as: (() -> String?).self, receiverABI: infoABI))
        readModel = try info.resolveAndWait(.getter("marketingName", as: (() -> String?).self, receiverABI: infoABI))
        readOS = try info.resolveAndWait(.getter("osVersion", as: (() -> String?).self, receiverABI: infoABI))
        readPairingState = try info.resolveAndWait(.getter("pairingState", as: (() -> NativeSwiftValue).self, receiverABI: infoABI))
        let state = try runtime.resolveSwiftTypeAndWait(named: "CoreDevice.PairingState")
        stateName = try state.resolveAndWait(.getter("rawValue", as: (() -> String).self,
                                                     receiverABI: .opaque(named: state.name)))
    }

    func start(devices: @escaping @MainActor ([NearbyPairingDevice]) -> Void,
               advertisement: @escaping @MainActor (String, String?) -> Void,
               issue: @escaping @MainActor (String) -> Void) async throws {
        devicesChanged = devices
        reportIssue = issue
        running = true
        try await unsafe initialize.unsafeInvoke(on: manager)
        try Task.checkCancellation()
        guard running else { throw CancellationError() }
        try publishDevices()
        let owner = try unsafe changes.unsafeInvoke(on: manager)
        guard let sequence = try owner.withCopy({ $0 as? any AsyncSequence }) else {
            throw CLIError.unavailable("pairing-discovery", "Nearby device discovery could not be started.")
        }
        discoveryTask = Task { [weak self] in
            defer { withExtendedLifetime(owner) {} }
            guard let self else { return }
            do { try await self.follow(sequence) }
            catch {
                if self.running, !Task.isCancelled { self.reportIssue?(error.localizedDescription) }
            }
        }
        do {
            let beacon = try CoreDevicePairingBeacon()
            self.beacon = beacon
            try await beacon.start(advertisement: advertisement, issue: issue)
        } catch is CancellationError { throw CancellationError() }
        catch {
            NSLog("NeoSimulator pairing advertisement: %@", String(describing: error))
            issue("This Mac could not be made discoverable. You can still pair a device listed below.")
        }
        try Task.checkCancellation()
        guard running else { throw CancellationError() }
    }

    func pair(identifier: String,
              requestPIN: @escaping @MainActor (Bool, Double?) async throws -> String) async throws {
        guard running else { throw CancellationError() }
        guard let uuid = UUID(uuidString: identifier),
              let device = try unsafe readDevices.unsafeInvoke(on: manager)[uuid],
              try unsafe supports.unsafeInvoke(on: device, "com.apple.coredevice.feature.inititatepairing") else {
            throw CLIError.unavailable("pairing-device", "The selected nearby device is no longer available for pairing.")
        }
        let operation: @Sendable (Bool, Double?) async throws -> String = { failed, throttle in
            try await requestPIN(failed, throttle)
        }
        let callback = try NativeSwiftClosure<PINHandler>(operation)
        try await unsafe pairDevice.unsafeInvoke(on: device, callback)
    }

    func stop() async throws {
        running = false
        devicesChanged = nil
        reportIssue = nil
        discoveryTask?.cancel()
        var cleanupError: (any Error)?
        do { try await beacon?.stop(); beacon = nil }
        catch { cleanupError = error }
        await discoveryTask?.value
        discoveryTask = nil
        if let cleanupError { throw cleanupError }
    }

    private func follow<S: AsyncSequence>(_ sequence: S) async throws {
        var iterator = sequence.makeAsyncIterator()
        while try await iterator.next(isolation: #isolation) != nil {
            try Task.checkCancellation()
            guard running else { return }
            try publishDevices()
        }
    }

    private func publishDevices() throws {
        let current = try unsafe readDevices.unsafeInvoke(on: manager)
        var records: [NearbyPairingDevice] = []
        for (identifier, device) in current {
            guard try unsafe supports.unsafeInvoke(on: device, "com.apple.coredevice.feature.inititatepairing") else { continue }
            let info = try unsafe deviceInfo.unsafeInvoke(on: device)
            let state = try unsafe readPairingState.unsafeInvoke(on: info)
            guard try unsafe stateName.unsafeInvoke(on: state) == "unpaired" else { continue }
            let model = try unsafe readModel.unsafeInvoke(on: info)
            records.append(NearbyPairingDevice(identifier: identifier.uuidString,
                name: try unsafe readName.unsafeInvoke(on: info) ?? model ?? "Nearby Device",
                modelName: model, operatingSystem: try unsafe readOS.unsafeInvoke(on: info)))
        }
        devicesChanged?(records.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.identifier < $1.identifier : order == .orderedAscending
        })
    }
}
