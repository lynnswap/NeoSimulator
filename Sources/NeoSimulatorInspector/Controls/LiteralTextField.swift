import AppKit

/// Identifiers, names and search queries are literal text. Configure the shared
/// field editor before editing or selecting, so resigning it does not start AppKit's data detectors.
@MainActor
package final class LiteralTextField: NSTextField {
    package override class var cellClass: AnyClass? {
        get { LiteralTextFieldCell.self }
        set {}
    }
}

@MainActor
private final class LiteralTextFieldCell: NSTextFieldCell {
    package override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        (editor as? NSTextView)?.enabledTextCheckingTypes = 0
        return editor
    }
}

@MainActor
package final class LiteralSearchFieldCell: NSSearchFieldCell {
    package override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        (editor as? NSTextView)?.enabledTextCheckingTypes = 0
        return editor
    }
}
