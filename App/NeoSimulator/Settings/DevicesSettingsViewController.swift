import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class DevicesSettingsState {
    var form: NewSimulatorModel?
    var isLoading = false
    var issue: String?
    @ObservationIgnored var retry: (() -> Void)?
}

@MainActor
final class DevicesSettingsViewController: NSHostingController<DevicesSettingsView> {
    let state = DevicesSettingsState()
    private let makeSimulator: () async throws -> NewSimulatorModel
    private let reportFailure: (Error) -> Void
    private(set) var loading: Task<Void, Never>?

    init(makeSimulator: @escaping () async throws -> NewSimulatorModel, reportFailure: @escaping (Error) -> Void) {
        self.makeSimulator = makeSimulator
        self.reportFailure = reportFailure
        super.init(rootView: DevicesSettingsView(state: state))
        title = "Devices"
        sizingOptions = [.standardBounds, .preferredContentSize]
        state.retry = { [weak self] in self?.reload() }
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidAppear() {
        super.viewDidAppear()
        reload()
    }

    func reload() {
        let previous = state.form
        guard loading == nil, previous?.isCreating != true else { return }
        state.isLoading = true
        state.issue = nil
        loading = Task { [weak self, makeSimulator, reportFailure] in
            defer {
                self?.state.isLoading = false
                self?.loading = nil
            }
            do {
                let form = try await makeSimulator()
                try Task.checkCancellation()
                if let previous { form.restoreInput(from: previous) }
                form.onFailure = { [weak self, weak form, reportFailure] error in
                    if self?.view.window?.isVisible == true { form?.error = error.localizedDescription }
                    else { reportFailure(error) }
                }
                self?.state.form = form
            } catch is CancellationError {
            } catch {
                self?.state.issue = error.localizedDescription
            }
        }
    }

    isolated deinit { loading?.cancel() }
}

struct DevicesSettingsView: View {
    let state: DevicesSettingsState

    var body: some View {
        VStack {
            if let form = state.form {
                NewSimulatorView(model: form).disabled(state.isLoading)
            } else if state.issue == nil {
                Form { ProgressView("Loading simulator runtimes…") }
                    .formStyle(.grouped)
                    .frame(width: 560)
            }
            if let issue = state.issue {
                Form {
                    Text(issue)
                    Button("Retry") { state.retry?() }
                }
                .formStyle(.grouped)
                .frame(width: 560)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

#if DEBUG
#Preview("Devices", traits: .sizeThatFitsLayout) {
    let controller = DevicesSettingsViewController(makeSimulator: { SettingsPreview.simulator() }, reportFailure: { _ in })
    controller.reload()
    return controller
}
#endif
