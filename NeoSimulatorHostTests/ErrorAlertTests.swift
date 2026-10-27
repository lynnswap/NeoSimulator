import AppKit
import Testing

@Suite @MainActor
struct ErrorAlertTests {
    @Test func longDiagnosticsAreScrollableAndSelectableWithoutLosingRecoveryText() throws {
        let diagnostic = (0..<40).map { "Recorder diagnostic line \($0): 日本語の詳細 and a file path." }.joined(separator: "\n")
        let error = NSError(domain: NSPOSIXErrorDomain, code: 16, userInfo: [
            NSLocalizedDescriptionKey: diagnostic,
            NSLocalizedFailureReasonErrorKey: "A recording is already in progress.",
            NSLocalizedRecoverySuggestionErrorKey: "Stop the recording and try again.",
        ])
        let alert = NSAlert(presenting: error)
        let scroll = try #require(alert.accessoryView as? NSScrollView)
        let text = try #require(scroll.documentView as? NSTextView)
        #expect(text.string.contains(diagnostic))
        #expect((text.string + alert.informativeText).contains("Stop the recording and try again."))
        #expect(text.isSelectable && !text.isEditable && scroll.hasVerticalScroller)
        #expect(alert.messageText != diagnostic)
        alert.layout()
        text.layoutManager?.ensureLayout(for: try #require(text.textContainer))
        #expect(text.frame.height > scroll.contentSize.height)
        text.selectAll(nil)
        #expect(text.selectedRange().length == text.string.utf16.count)
    }

    @Test func shortErrorsAndExplicitRecoveryActionsKeepTheirPresentation() {
        let error = HostError.conflict("The device screen is open in another app.")
        let native = NSAlert(error: error)
        let alert = NSAlert(presenting: error)
        #expect(alert.accessoryView == nil)
        #expect(alert.messageText == native.messageText && alert.informativeText == native.informativeText)
        #expect(alert.buttons.map(\.title) == native.buttons.map(\.title))

        alert.addButton(withTitle: "Restore Saved Values…")
        let titles = alert.buttons.map(\.title)
        alert.addDiagnosticDetails("routing diagnostic")
        #expect(alert.messageText == native.messageText && alert.informativeText == native.informativeText)
        #expect(alert.buttons.map(\.title) == titles)
        #expect((alert.accessoryView as? NSScrollView)?.documentView is NSTextView)
    }
}
