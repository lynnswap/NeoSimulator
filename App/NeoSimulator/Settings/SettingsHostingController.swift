import AppKit
import SwiftUI

@MainActor
class SettingsHostingController<Content: View>: NSHostingController<Content> {
    var onContentSizeChange: ((NSSize) -> Void)?

    override func viewDidLayout() {
        super.viewDidLayout()
        onContentSizeChange?(sizeThatFits(in: .zero))
    }
}
