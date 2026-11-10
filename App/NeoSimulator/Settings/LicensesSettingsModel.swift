import AppKit
import LicenseList
import Observation

@MainActor @Observable
final class LicensesSettingsModel {
    private static let mitPermission = """
        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.
        """

    let libraries: [Library]
    let issue: String?
    var selectedLibrary: Library?

    init(bundle: Bundle = Bundle(for: LicensesSettingsModel.self)) {
        var libraries = Library.libraries
        for (name, url, copyright) in [
            ("simlock", "https://github.com/callstackincubator/simlock", "Copyright (c) 2026 Szymon Chmal"),
            ("idevice", "https://github.com/jkcoxson/idevice", "Copyright 2026 Jackson Coxson"),
        ] {
            libraries.append(
                Library(name: name, url: url, licenseBody: "MIT License\n\n" + copyright + "\n\n" + Self.mitPermission))
        }
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
