import AppKit
import LicenseList
import Observation

@MainActor @Observable
final class LicensesSettingsModel {
    let libraries: [Library]
    let issue: String?
    var selectedLibrary: Library?

    init(bundle: Bundle = Bundle(for: LicensesSettingsModel.self)) {
        var libraries = Library.libraries
        var issue: String?
        do {
            guard let url = bundle.url(forResource: "Credits", withExtension: "rtf") else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            let credits = try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                 documentAttributes: nil)
            libraries.append(Library(name: "simslim", url: "https://github.com/MobAI-App/simslim",
                                     licenseBody: credits.string))
        } catch {
            issue = error.localizedDescription
        }
        self.libraries = libraries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.issue = issue
        selectedLibrary = self.libraries.first
    }
}
