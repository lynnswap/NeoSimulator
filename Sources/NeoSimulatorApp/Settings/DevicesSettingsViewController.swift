import NeoSimulatorKit
import NeoSimulatorHostSupport
import NeoSimulatorPresentationAdapters
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
    /// DeviceKit's sheet for pairing a nearby device, while it is presented.
    var pairingSheet: PairingSheet?
    var pairingIssue: String?
    private(set) var isPreparingPairing = false
    @ObservationIgnored private let makeSimulator: () async throws -> NewSimulatorModel
    @ObservationIgnored private let makePairingSheet: @MainActor () async throws -> AnyView
    @ObservationIgnored private let reportFailure: (Error) -> Void
    @ObservationIgnored private(set) var loading: Task<Void, Never>?
    @ObservationIgnored private(set) var preparingPairing: Task<Void, Never>?

    struct PairingSheet: Identifiable {
        let id = UUID()
        let content: AnyView
    }

    init(makeSimulator: @escaping () async throws -> NewSimulatorModel,
         makePairingSheet: @escaping @MainActor () async throws -> AnyView = NativeNearbyDevicePairing.makeSheet,
         reportFailure: @escaping (Error) -> Void) {
        self.makeSimulator = makeSimulator
        self.makePairingSheet = makePairingSheet
        self.reportFailure = reportFailure
    }

    /// Presents DeviceKit's pairing sheet, loading DeviceKit first when nothing has loaded it yet.
    func pairNearbyDevice() {
        guard !isPreparingPairing, pairingSheet == nil else { return }
        isPreparingPairing = true
        preparingPairing = Task { [weak self, makePairingSheet] in
            defer {
                self?.isPreparingPairing = false
                self?.preparingPairing = nil
            }
            do {
                let content = try await makePairingSheet()
                guard let self, self.isVisible else { return }
                self.pairingSheet = PairingSheet(content: content)
            } catch {
                self?.pairingIssue = error.localizedDescription
            }
        }
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
    @Bindable var state: DevicesSettingsState

    var body: some View {
        VStack(spacing: 0) {
            simulator
            Form {
                Section("Physical Devices") {
                    LabeledContent {
                        Button("Pair…", action: state.pairNearbyDevice)
                            .disabled(state.isPreparingPairing)
                    } label: {
                        Text("Pair a Nearby Device")
                        Text("The device starts pairing from Developer Mode in its Privacy & Security settings.")
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(item: $state.pairingSheet) { $0.content }
        .alert("Unable to Pair a Device", isPresented: Binding(
            get: { state.pairingIssue != nil }, set: { if !$0 { state.pairingIssue = nil } })) {
            Button("OK") { state.pairingIssue = nil }
        } message: {
            Text(state.pairingIssue ?? "")
        }
    }

    private var simulator: some View {
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
