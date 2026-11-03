import AppKit
import SwiftUI

@MainActor
final class NewSimulatorViewController: NSHostingController<NewSimulatorView> {
    let model: NewSimulatorModel

    init(model: NewSimulatorModel) {
        self.model = model
        super.init(rootView: NewSimulatorView(model: model))
        model.startLoadingRuntimeNames()
        title = model.title
        sizingOptions = [.standardBounds, .preferredContentSize]
    }

    required init?(coder: NSCoder) { nil }
}
