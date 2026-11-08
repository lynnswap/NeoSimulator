#if DEBUG
import AppKit
import SwiftUI

package struct PreviewViewController<Controller: NSViewController>: NSViewControllerRepresentable {
    package let makeController: () -> Controller
    package init(makeController: @escaping () -> Controller) { self.makeController = makeController }
    package func makeNSViewController(context: Context) -> Controller { makeController() }
    package func updateNSViewController(_ controller: Controller, context: Context) {}
}
#endif
