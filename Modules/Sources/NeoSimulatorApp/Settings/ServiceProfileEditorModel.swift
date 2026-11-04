import Foundation
import Observation
import XcodeSimulatorHost

@MainActor @Observable
final class ServiceProfileEditorModel: Identifiable {
    let id = UUID()
    let profileID: UUID?
    var name: String
    let configuration: ServiceConfiguration
    var issue: String?
    @ObservationIgnored var save: ((ServiceProfileEditorModel) throws -> Void)?

    init(profileID: UUID? = nil, name: String, configuration: ServiceConfiguration) {
        self.profileID = profileID
        self.name = name
        self.configuration = configuration
    }

    var canSave: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var showsIssue: Bool {
        get { issue != nil }
        set { if !newValue { issue = nil } }
    }

    func commit() -> Bool {
        guard let save else { return false }
        do {
            try save(self)
            return true
        } catch {
            issue = error.localizedDescription
            return false
        }
    }
}
