import Foundation

enum SimulatorPreferences {
    static func migrateStandalonePreferences(defaults: UserDefaults = .standard,
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
