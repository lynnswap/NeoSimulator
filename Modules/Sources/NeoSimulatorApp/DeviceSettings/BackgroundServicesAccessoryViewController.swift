import AppKit
import ObservationBridge
import SwiftUI

@MainActor
final class BackgroundServicesAccessoryViewController: NSSplitViewItemAccessoryViewController {
    let model: BackgroundServicesInspectorModel
    var isActive = false { didSet { updateVisibility() } }

    private let hosting: NSHostingController<BackgroundServicesProfileForm>
    private var observation: PortableObservationTracking.Token?
    private var editor: ServiceProfileEditorController?

    init(model: BackgroundServicesInspectorModel) {
        self.model = model
        hosting = NSHostingController(rootView: BackgroundServicesProfileForm(model: model))
        super.init(nibName: nil, bundle: nil)
        preferredScrollEdgeEffectStyle = .hard
        automaticallyAppliesContentInsets = false
        hosting.sizingOptions = [.intrinsicContentSize]
        addChild(hosting)
        view = hosting.view
        observation = withPortableContinuousObservation { [weak self] _ in
            self?.updateVisibility()
            self?.showEditor(model.profileEditor)
        }
    }

    required init?(coder: NSCoder) { nil }

    private func updateVisibility() {
        if case .simulator = model.content { isHidden = !isActive }
        else { isHidden = true }
    }

    private func showEditor(_ model: ServiceProfileEditorModel?) {
        guard editor?.model !== model else { return }
        if let editor { dismiss(editor); self.editor = nil }
        guard let model else { return }
        let editor = ServiceProfileEditorController(model: model)
        editor.onClose = { [weak self] in self?.model.profileEditor = nil }
        self.editor = editor
        presentAsSheet(editor)
    }
}

private struct BackgroundServicesProfileForm: View {
    @Bindable var model: BackgroundServicesInspectorModel

    var body: some View {
        Form {
            Section {
                Picker("Profile", selection: Binding<UUID?>(
                    get: { model.selectedProfileID },
                    set: { id in
                        if let id { model.selectedProfileID = id }
                        else { model.customizeProfile() }
                    }
                )) {
                    ForEach(model.profileChoices, id: \.id) { choice in
                        Text(choice.title).tag(Optional(choice.id))
                    }
                    Divider()
                    Text("Custom…").tag(UUID?.none)
                }
                .pickerStyle(.menu)
                .disabled(model.holdsChanges || model.profiles.issue != nil)
                HStack {
                    Button("Revert", action: model.revertProfile)
                        .disabled(model.holdsChanges || !model.hasProfileChanges)
                    Spacer()
                    Button("Save", action: model.saveProfile)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canSaveProfile)
                }
            }
        }
        // WORKAROUND: OS 27で表示できないので、ひとまずcolumns + paddigで対応
        .formStyle(.columns)
        .scenePadding()
        .fixedSize(horizontal: false, vertical: true)
        .alert("Unable to Save Service Profile", isPresented: $model.showsActionIssue) {
            Button("OK") { model.actionIssue = nil }
        } message: {
            Text(model.actionIssue ?? "")
        }
    }
}
