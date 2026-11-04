import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class DevicesSettingsState {
    enum Content {
        case loading
        case unavailable(String)
        case form(NewSimulatorModel)
    }

    var content: Content {
        switch (issue, form) {
        case (let issue?, _): .unavailable(issue)
        case (nil, let form?): .form(form)
        case (nil, nil): .loading
        }
    }

    var form: NewSimulatorModel?
    var isLoading = false
    var issue: String?
    var isVisible = false
    @ObservationIgnored private let makeSimulator: () async throws -> NewSimulatorModel
    @ObservationIgnored private let reportFailure: (Error) -> Void
    @ObservationIgnored private(set) var loading: Task<Void, Never>?

    init(makeSimulator: @escaping () async throws -> NewSimulatorModel, reportFailure: @escaping (Error) -> Void) {
        self.makeSimulator = makeSimulator
        self.reportFailure = reportFailure
    }

    func reload() {
        let previous = isVisible ? form : nil
        guard loading == nil, form?.isCreating != true else { return }
        isLoading = true
        issue = nil
        loading = Task { [weak self, makeSimulator, reportFailure] in
            defer {
                self?.isLoading = false
                self?.loading = nil
            }
            do {
                let form = try await makeSimulator()
                try Task.checkCancellation()
                if let previous { form.restoreInput(from: previous) }
                form.onFailure = { [weak self, weak form, reportFailure] error in
                    if self?.isVisible == true { form?.error = error.localizedDescription }
                    else { reportFailure(error) }
                }
                form.startLoadingRuntimeNames()
                self?.form = form
            } catch is CancellationError {
            } catch {
                self?.issue = error.localizedDescription
            }
        }
    }


    isolated deinit { loading?.cancel() }
}

@MainActor
final class DevicesSettingsViewController: NSHostingController<DevicesSettingsView> {
    let state: DevicesSettingsState

    init(makeSimulator: @escaping () async throws -> NewSimulatorModel, reportFailure: @escaping (Error) -> Void) {
        state = DevicesSettingsState(makeSimulator: makeSimulator, reportFailure: reportFailure)
        super.init(rootView: DevicesSettingsView(state: state))
        title = "Devices"
        sizingOptions = [.standardBounds, .preferredContentSize]
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidAppear() {
        super.viewDidAppear()
        state.isVisible = true
        state.reload()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        state.isVisible = false
    }

    func reload() { state.reload() }
}

struct DevicesSettingsView: View {
    let state: DevicesSettingsState

    var body: some View {
        Group {
            switch state.content {
            case .loading:
                ContentUnavailableView {
                    ProgressView()
                } description: {
                    Text("Loading simulator runtimes…")
                }
            case .unavailable(let issue):
                ContentUnavailableView {
                    Label("Unable to Load Simulator Runtimes", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(issue)
                } actions: {
                    Button("Retry", action: state.reload)
                }
            case .form(let form):
                NewSimulatorView(model: form)
                    .disabled(state.isLoading)
            }
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
#Preview("Devices", traits: .sizeThatFitsLayout) {
    let controller = DevicesSettingsViewController(makeSimulator: { SettingsPreview.simulator() }, reportFailure: { _ in })
    controller.reload()
    return controller
}

#Preview("Devices — Loading", traits: .sizeThatFitsLayout) {
    let state = DevicesSettingsState(makeSimulator: { SettingsPreview.simulator() }, reportFailure: { _ in })
    state.isLoading = true
    return DevicesSettingsView(state: state)
}

#Preview("Devices — Unavailable", traits: .sizeThatFitsLayout) {
    let state = DevicesSettingsState(makeSimulator: { SettingsPreview.simulator() }, reportFailure: { _ in })
    state.issue = "The simulator runtime catalog could not be loaded."
    return DevicesSettingsView(state: state)
}
#endif
