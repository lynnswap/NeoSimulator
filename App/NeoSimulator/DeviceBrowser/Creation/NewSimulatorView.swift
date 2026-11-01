import SwiftUI

struct NewSimulatorView: View {
    @Bindable var model: NewSimulatorModel

    var body: some View {
        Form {
            Section(model.heading) {
                if model.showsWatchPage { watchFields }
                else { simulatorFields }
            }
            if let message = model.message { Text(message).foregroundStyle(.secondary) }
            Section {
                HStack {
                    if let cancel = model.onCancel {
                        Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                    }
                    Spacer()
                    if model.existingDevice == nil, model.showsWatchPage {
                        Button("Previous", action: model.previous)
                    }
                    Button(model.forwardTitle, action: model.forward)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canProceed)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Unable to Create Simulator", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    @ViewBuilder private var simulatorFields: some View {
        if model.existingDevice == nil {
            Picker("Device", selection: Binding(get: { model.family }, set: model.selectFamily)) {
                ForEach(model.families, id: \.id) { family in
                    Text(family.name).tag(Optional(family.id))
                }
            }
        }
        TextField("Simulator Name", text: $model.name, prompt: Text(model.deviceNamePlaceholder))
        Picker("Model", selection: Binding(get: { model.deviceType }, set: model.selectDeviceType)) {
            ForEach(model.deviceTypes, id: \.identifier) { type in
                Text(type.name).tag(Optional(type.identifier))
            }
        }
        Picker("OS Version", selection: Binding(get: { model.runtime }, set: model.selectRuntime)) {
            if model.runtimes.isEmpty { Text("No Runtimes Available").tag(String?.none) }
            ForEach(model.runtimes, id: \.identifier) { runtime in
                Text(runtime.name).tag(Optional(runtime.identifier))
            }
        }
        .disabled(model.runtimes.isEmpty)
        if model.existingDevice == nil {
            Toggle("Paired Apple Watch", isOn: Binding(get: { model.addsWatch }, set: model.setAddsWatch))
                .disabled(!model.canAddWatch)
        }
    }

    private var watchFields: some View {
        Group {
            TextField("Paired Watch Name", text: $model.watchName, prompt: Text(model.watchNamePlaceholder))
            Picker("Model", selection: Binding(get: { model.watchType }, set: model.selectWatchType)) {
                ForEach(model.watchTypes, id: \.identifier) { type in Text(type.name).tag(Optional(type.identifier)) }
            }
            Picker("OS Version", selection: Binding(get: { model.watchRuntime }, set: model.selectWatchRuntime)) {
                if model.availableWatchRuntimes.isEmpty { Text("No Runtimes Available").tag(String?.none) }
                ForEach(model.availableWatchRuntimes, id: \.identifier) { runtime in
                    Text(runtime.name).tag(Optional(runtime.identifier))
                }
            }
            .disabled(model.availableWatchRuntimes.isEmpty)
        }
    }
}
