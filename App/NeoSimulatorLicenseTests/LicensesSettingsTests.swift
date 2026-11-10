import AppKit
import LicenseList
import Testing

@MainActor @Suite(.serialized)
struct LicensesSettingsTests {
    @Test func licensesIncludePackagesAndPortedCodeAndUseNativeSelection() throws {
        let model = LicensesSettingsModel()
        #expect(model.issue == nil)
        let names = Set(model.libraries.map(\.name))
        #expect(
            names.isSuperset(of: ["LicenseList", "ABIBridge", "ObservationBridge", "simslim", "simlock", "idevice"]))
        let simslim = try #require(model.libraries.first { $0.name == "simslim" })
        #expect(simslim.licenseBody.contains("Copyright (c) 2026 Interlap"))
        #expect(simslim.licenseBody.contains("Permission is hereby granted"))
        for (name, author) in [("simlock", "Szymon Chmal"), ("idevice", "Jackson Coxson")] {
            let library = try #require(model.libraries.first { $0.name == name })
            #expect(library.licenseBody.contains(author))
            #expect(library.licenseBody.contains("Permission is hereby granted"))
        }
        #expect(model.libraries.allSatisfy { !$0.licenseBody.isEmpty })

        let controller = LicensesSettingsViewController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        window.layoutIfNeeded()
        #expect(controller.view.frame.size == NSSize(width: 720, height: 520))
        let table = try #require(inspectorViews(controller.view).compactMap { $0 as? NSTableView }.first)
        #expect(table.selectedRow == 0)
        let row = try #require(model.libraries.firstIndex { $0.id == simslim.id })
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        #expect(model.selectedLibrary?.id == simslim.id)
    }

    private func inspectorViews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(inspectorViews)
    }
}
