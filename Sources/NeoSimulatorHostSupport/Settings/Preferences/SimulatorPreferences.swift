import NeoSimulatorKit
import Foundation
import Observation

@MainActor @Observable
package final class SimulatorPreferences {
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let creationDefaults: UserDefaults?
    @ObservationIgnored private var observations: [DefaultsObservation] = []
    @ObservationIgnored private var isReloading = false
    private static let categoryKey = "NewSimulatorCategory"
    package var keepRunningOnWindowClose = false { didSet { save(keepRunningOnWindowClose, forKey: HostPreferences.detachOnWindowClose) } }
    package var keepRunningOnQuit = false { didSet { save(keepRunningOnQuit, forKey: HostPreferences.detachOnAppQuit) } }
    package var showSingleTouches = false { didSet { save(showSingleTouches, forKey: HostPreferences.showSingleTouches) } }
    package var showPinches = true { didSet { save(showPinches, forKey: HostPreferences.showPinches) } }
    package var slowAnimations = false { didSet { save(slowAnimations, forKey: HostPreferences.slowMotionAnimation) } }
    package var includeDeviceMask = false { didSet { save(includeDeviceMask, forKey: HostPreferences.screenShotUseMask) } }
    package var gifImageSize = 640 { didSet { save(gifImageSize, forKey: HostPreferences.gifMaxFrameSize) } }
    package var gifFrameRate = 10 { didSet { save(gifFrameRate, forKey: HostPreferences.gifMaxFramerate) } }
    package var newSimulatorCategory: DeviceCategory? {
        didSet {
            guard !isReloading else { return }
            if let newSimulatorCategory { creationDefaults?.set(newSimulatorCategory.rawValue, forKey: Self.categoryKey) }
            else { creationDefaults?.removeObject(forKey: Self.categoryKey) }
        }
    }

    package func newSimulatorDeviceType(for category: DeviceCategory) -> String? {
        creationDefaults?.string(forKey: "NewSimulatorDeviceType.\(category.rawValue)")
    }
    package func newSimulatorRuntime(for category: DeviceCategory) -> String? {
        creationDefaults?.string(forKey: "NewSimulatorRuntime.\(category.rawValue)")
    }
    package func setNewSimulatorSelection(deviceType: String?, runtime: String?, for category: DeviceCategory) {
        creationDefaults?.set(deviceType, forKey: "NewSimulatorDeviceType.\(category.rawValue)")
        creationDefaults?.set(runtime, forKey: "NewSimulatorRuntime.\(category.rawValue)")
    }

    package init(defaults: UserDefaults = HostPreferences.defaults,
         creationDefaults: UserDefaults? = HostPreferences.deviceSettingsDefaults) {
        self.defaults = defaults
        self.creationDefaults = creationDefaults
        defaults.register(defaults: [
            HostPreferences.detachOnWindowClose: false, HostPreferences.detachOnAppQuit: false,
            HostPreferences.showSingleTouches: false, HostPreferences.showPinches: true,
            HostPreferences.screenShotUseMask: false, HostPreferences.gifMaxFrameSize: 640,
            HostPreferences.gifMaxFramerate: 10,
        ])
        reload()
        observations.append(DefaultsObservation(defaults, keys: [
            HostPreferences.detachOnWindowClose, HostPreferences.detachOnAppQuit,
            HostPreferences.showSingleTouches, HostPreferences.showPinches, HostPreferences.slowMotionAnimation,
            HostPreferences.screenShotUseMask, HostPreferences.gifMaxFrameSize, HostPreferences.gifMaxFramerate,
        ]) { [weak self] in self?.reload() })
        if let creationDefaults {
            observations.append(DefaultsObservation(creationDefaults, keys: [Self.categoryKey]) { [weak self] in self?.reload() })
        }
    }

    private func save(_ value: Any, forKey key: String) {
        if !isReloading { defaults.set(value, forKey: key) }
    }

    private func reload() {
        isReloading = true
        defer { isReloading = false }
        keepRunningOnWindowClose = defaults.bool(forKey: HostPreferences.detachOnWindowClose)
        keepRunningOnQuit = defaults.bool(forKey: HostPreferences.detachOnAppQuit)
        showSingleTouches = defaults.bool(forKey: HostPreferences.showSingleTouches)
        showPinches = defaults.bool(forKey: HostPreferences.showPinches)
        slowAnimations = defaults.bool(forKey: HostPreferences.slowMotionAnimation)
        includeDeviceMask = defaults.bool(forKey: HostPreferences.screenShotUseMask)
        gifImageSize = defaults.integer(forKey: HostPreferences.gifMaxFrameSize)
        gifFrameRate = defaults.integer(forKey: HostPreferences.gifMaxFramerate)
        newSimulatorCategory = creationDefaults?.string(forKey: Self.categoryKey).map(DeviceCategory.init(rawValue:))
    }

    package nonisolated static func migrateStandalonePreferences(defaults: UserDefaults = .standard,
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
