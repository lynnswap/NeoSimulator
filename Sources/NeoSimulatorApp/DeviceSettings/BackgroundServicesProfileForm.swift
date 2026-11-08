import SwiftUI
import NeoSimulatorManager

struct BackgroundServicesProfileForm: View {
    @Bindable var model: BackgroundServicesInspectorModel

    var body: some View {
        Form {
            Section {
                Picker(selection: $model.selectedProfileSelection) {
                    profileChoice(model.defaultProfileChoice)
                    if model.selectedProfileSelection == .profile(ServiceProfile.allServices.id) {
                        Text(model.selectedProfileTitle).tag(model.selectedProfileSelection)
                    }
                    if !model.savedProfileChoices.isEmpty {
                        Divider()
                        ForEach(model.savedProfileChoices, id: \.id) { choice in
                            profileChoice(choice)
                        }
                    }
                    Divider()
                    Button(action: model.openProfileSettings) {
                        Text("Open Settings…", bundle: #bundle)
                    }
                } label: {
                    Text("Profile", bundle: #bundle)
                }
                .pickerStyle(.menu)
                .help(Text("Applies at each simulator start while NeoSimulator is open.", bundle: #bundle))
                .disabled(model.holdsChanges || model.profiles.issue != nil)
                HStack {
                    Button("Revert", action: model.revertProfile)
                        .disabled(!model.canRevertProfile)
                    Spacer()
                    Button("Save", action: model.saveProfile)
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.canSaveProfile)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectHidden()
        .fixedSize(horizontal: false, vertical: true)
        .alert("Unable to Save Service Profile", isPresented: $model.showsActionIssue) {
            Button("OK") { model.actionIssue = nil }
        } message: {
            Text(model.actionIssue ?? "")
        }
    }

    private func profileChoice(_ choice: BackgroundServicesInspectorModel.ProfileChoice) -> some View {
        Text(choice.title).tag(choice.id)
    }
}
