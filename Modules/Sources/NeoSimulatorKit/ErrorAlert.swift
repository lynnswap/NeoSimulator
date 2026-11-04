import AppKit

extension NSAlert {
    convenience init(presenting error: any Error) {
        self.init(error: error)
        addDiagnosticDetails()
    }

    func addDiagnosticDetails(_ technicalDetails: String? = nil) {
        let width: CGFloat = 460
        func height(of text: String, font: NSFont) -> CGFloat {
            (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font]).height
        }
        let longMessage = height(of: messageText, font: .boldSystemFont(ofSize: 13)) > 60
        let longInformation = height(of: informativeText, font: .systemFont(ofSize: 13)) > 160
        guard longMessage || longInformation || technicalDetails != nil else { return }

        var details: [String] = []
        if longMessage {
            details.append(messageText)
            messageText = "The operation couldn’t be completed."
        }
        if longInformation {
            details.append(informativeText)
            informativeText = ""
        }
        if let technicalDetails, !details.contains(technicalDetails) { details.append(technicalDetails) }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 220))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        text.string = details.joined(separator: "\n\n")
        text.setAccessibilityLabel("Error Details")
        scroll.documentView = text
        accessoryView = scroll
    }
}
