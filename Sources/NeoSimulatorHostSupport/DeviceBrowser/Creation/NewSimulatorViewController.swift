import NeoSimulatorKit
import AppKit
import SwiftUI

@MainActor
package final class NewSimulatorViewController: NSHostingController<NewSimulatorView> {
    package let model: NewSimulatorModel

    package init(model: NewSimulatorModel) {
        self.model = model
        super.init(rootView: NewSimulatorView(model: model))
        model.startLoadingRuntimeNames()
        title = model.title
        sizingOptions = [.standardBounds, .preferredContentSize]
    }

    package required init?(coder: NSCoder) { nil }
}
