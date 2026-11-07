import AppKit

/// Identifiers, names and search queries are literal text. Configure the shared
/// field editor before editing or selecting, so resigning it does not start AppKit's data detectors.
@MainActor
final class LiteralTextField: NSTextField {
    override class var cellClass: AnyClass? {
        get { LiteralTextFieldCell.self }
        set {}
    }
}

@MainActor
private final class LiteralTextFieldCell: NSTextFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        (editor as? NSTextView)?.enabledTextCheckingTypes = 0
        return editor
    }
}

@MainActor
final class LiteralSearchFieldCell: NSSearchFieldCell {
    override func setUpFieldEditorAttributes(_ textObj: NSText) -> NSText {
        let editor = super.setUpFieldEditorAttributes(textObj)
        (editor as? NSTextView)?.enabledTextCheckingTypes = 0
        return editor
    }
}
