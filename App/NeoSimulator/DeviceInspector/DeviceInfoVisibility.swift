import Foundation
import Observation

/// Owns the Info field choices, including the existing raw-property hiding contract.
@MainActor @Observable
final class DeviceInfoVisibility {
    private struct Selection {
        let defaultVisible: Bool
        var overrides: [[String]: Bool]
    }

    static let preferenceKey = "DeviceInfoVisibility"
    static let legacyPreferenceKey = "DeviceInfoHiddenFields"

    private let defaults: UserDefaults
    private var selection: Selection

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let saved = defaults.dictionary(forKey: Self.preferenceKey),
           let defaultVisible = saved["defaultVisible"] as? Bool,
           let entries = saved["overrides"] as? [[String: Any]] {
            var overrides: [[String]: Bool] = [:]
            for entry in entries {
                if let path = entry["path"] as? [String], let visible = entry["visible"] as? Bool {
                    overrides[path] = visible
                }
            }
            selection = Selection(defaultVisible: defaultVisible, overrides: overrides)
        } else if let hidden = defaults.array(forKey: Self.legacyPreferenceKey) as? [[String]] {
            var overrides = Dictionary(hidden.map { ($0, false) }, uniquingKeysWith: { _, value in value })
            // Core rows now have stable paths even when their legacy values came from a category.
            for (field, sources) in DeviceInformation.legacySourcePaths
                where hidden.contains(where: { parent in sources.contains { $0.starts(with: parent) } }) {
                overrides[field] = false
            }
            selection = Selection(defaultVisible: true, overrides: overrides)
            save()
        } else {
            selection = Selection(defaultVisible: false,
                                  overrides: Dictionary(uniqueKeysWithValues: DeviceInformation.defaultFields.map { ($0, true) }))
        }
    }

    func isVisible(_ field: DeviceInformation.Field) -> Bool {
        field.visibilityPaths.contains { path in
            selection.overrides.filter { path.starts(with: $0.key) }
                .max { $0.key.count < $1.key.count }?.value ?? selection.defaultVisible
        }
    }

    func setVisible(_ visible: Bool, for field: DeviceInformation.Field) {
        for path in field.visibilityPaths where path != field.id {
            selection.overrides.removeValue(forKey: path)
        }
        selection.overrides[field.id] = visible
        save()
    }

    private func save() {
        let entries: [[String: Any]] = selection.overrides.sorted { $0.key.lexicographicallyPrecedes($1.key) }
            .map { ["path": $0.key, "visible": $0.value] }
        defaults.set(["defaultVisible": selection.defaultVisible, "overrides": entries],
                     forKey: Self.preferenceKey)
    }
}
