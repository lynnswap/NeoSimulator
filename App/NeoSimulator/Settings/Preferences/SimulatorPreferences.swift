import Foundation
import Observation

@MainActor @Observable
final class SimulatorPreferences {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let creationDefaults: UserDefaults?
    @ObservationIgnored private var observations: [DefaultsObservation] = []
    @ObservationIgnored private var isReloading = false
    private static let familyKey = "NewSimulatorProductFamily"
    var startLastDevice = true {
        didSet {
            guard !isReloading else { return }
            let enabled = startLastDevice
            defaults.set(enabled, forKey: HostPreferences.startLastDeviceOnLaunch)
            defaults.set(enabled, forKey: HostPreferences.sessionOnLaunch)
        }
    }
    var keepRunningOnWindowClose = false { didSet { save(keepRunningOnWindowClose, forKey: HostPreferences.detachOnWindowClose) } }
    var keepRunningOnQuit = false { didSet { save(keepRunningOnQuit, forKey: HostPreferences.detachOnAppQuit) } }
    var showSingleTouches = false { didSet { save(showSingleTouches, forKey: HostPreferences.showSingleTouches) } }
    var showPinches = true { didSet { save(showPinches, forKey: HostPreferences.showPinches) } }
    var includeDeviceMask = false { didSet { save(includeDeviceMask, forKey: HostPreferences.screenShotUseMask) } }
    var gifImageSize = 640 { didSet { save(gifImageSize, forKey: HostPreferences.gifMaxFrameSize) } }
    var gifFrameRate = 10 { didSet { save(gifFrameRate, forKey: HostPreferences.gifMaxFramerate) } }
    var newSimulatorFamily: Int? {
        didSet {
            guard !isReloading else { return }
            if let newSimulatorFamily { creationDefaults?.set(newSimulatorFamily, forKey: Self.familyKey) }
            else { creationDefaults?.removeObject(forKey: Self.familyKey) }
        }
    }

    init(defaults: UserDefaults = HostPreferences.defaults,
         creationDefaults: UserDefaults? = HostPreferences.deviceSettingsDefaults) {
        self.defaults = defaults
        self.creationDefaults = creationDefaults
        defaults.register(defaults: [
            HostPreferences.startLastDeviceOnLaunch: true, HostPreferences.sessionOnLaunch: true,
            HostPreferences.detachOnWindowClose: false, HostPreferences.detachOnAppQuit: false,
            HostPreferences.showSingleTouches: false, HostPreferences.showPinches: true,
            HostPreferences.screenShotUseMask: false, HostPreferences.gifMaxFrameSize: 640,
            HostPreferences.gifMaxFramerate: 10,
        ])
        reload()
        observations.append(DefaultsObservation(defaults, keys: [
            HostPreferences.startLastDeviceOnLaunch, HostPreferences.sessionOnLaunch,
            HostPreferences.detachOnWindowClose, HostPreferences.detachOnAppQuit,
            HostPreferences.showSingleTouches, HostPreferences.showPinches,
            HostPreferences.screenShotUseMask, HostPreferences.gifMaxFrameSize, HostPreferences.gifMaxFramerate,
        ]) { [weak self] in self?.reload() })
        if let creationDefaults {
            observations.append(DefaultsObservation(creationDefaults, keys: [Self.familyKey]) { [weak self] in self?.reload() })
        }
    }

    private func save(_ value: Any, forKey key: String) {
        if !isReloading { defaults.set(value, forKey: key) }
    }

    private func reload() {
        isReloading = true
        defer { isReloading = false }
        startLastDevice = defaults.bool(forKey: HostPreferences.startLastDeviceOnLaunch) && defaults.bool(forKey: HostPreferences.sessionOnLaunch)
        keepRunningOnWindowClose = defaults.bool(forKey: HostPreferences.detachOnWindowClose)
        keepRunningOnQuit = defaults.bool(forKey: HostPreferences.detachOnAppQuit)
        showSingleTouches = defaults.bool(forKey: HostPreferences.showSingleTouches)
        showPinches = defaults.bool(forKey: HostPreferences.showPinches)
        includeDeviceMask = defaults.bool(forKey: HostPreferences.screenShotUseMask)
        gifImageSize = defaults.integer(forKey: HostPreferences.gifMaxFrameSize)
        gifFrameRate = defaults.integer(forKey: HostPreferences.gifMaxFramerate)
        newSimulatorFamily = creationDefaults?.object(forKey: Self.familyKey) as? Int
    }

    nonisolated static func migrateStandalonePreferences(defaults: UserDefaults = .standard,
                                             sourceDomain: String = "dev.lynnswap.NeoSimulator",
                                             targetDomain: String = "dev.lynnswap.NeoSimulator.Renderer") {
        let marker = "MigratedStandalonePreferences"
        var target = defaults.persistentDomain(forName: targetDomain) ?? [:]
        guard target[marker] as? Bool != true else { return }
        for (key, value) in defaults.persistentDomain(forName: sourceDomain) ?? [:] where target[key] == nil {
            target[key] = value
        }
        target[marker] = true
        defaults.setPersistentDomain(target, forName: targetDomain)
    }
}
