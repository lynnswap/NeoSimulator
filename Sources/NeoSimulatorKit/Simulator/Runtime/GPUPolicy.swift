import Foundation

/// Render-server GPU preference order in com.apple.CoreSimulator defaults.
package struct GPUPolicy {
    /// Preferred GPU kind after any leading external GPU.
    package enum Preference: String {
        case automatic
        case integrated = "lowPower"
        case discrete
    }

    package static let suiteName = "com.apple.CoreSimulator"
    package static let key = "FramebufferServerGPUPolicy"
    package static let defaultOrder = ["automatic", "external", "discrete", "lowPower", "headless"]
    private static let external = "external"

    package let defaults: UserDefaults

    package init(defaults: UserDefaults) { self.defaults = defaults }

    /// A single string is accepted as a one-element order.
    package var order: [String] {
        defaults.stringArray(forKey: Self.key) ?? defaults.string(forKey: Self.key).map { [$0] } ?? Self.defaultOrder
    }

    package var prefersExternal: Bool { order.first == Self.external }

    package var preference: Preference? {
        let order = order
        return (prefersExternal ? order.dropFirst().first : order.first).flatMap(Preference.init(rawValue:))
    }

    package func prefer(_ preference: Preference) { store(preference, external: prefersExternal) }

    package func togglePrefersExternal() { store(preference, external: !prefersExternal) }

    /// Replaces the order with the chosen kinds and external GPU; drops others such as headless.
    private func store(_ preference: Preference?, external: Bool) {
        let kinds = switch preference {
        case .automatic: ["automatic"]
        case .integrated: ["lowPower", "discrete"]
        case .discrete: ["discrete", "lowPower"]
        case nil: [String]()
        }
        defaults.set(external ? [Self.external] + kinds : kinds + [Self.external], forKey: Self.key)
    }
}
