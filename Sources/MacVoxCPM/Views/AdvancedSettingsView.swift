import SwiftUI

struct AdvancedSettingsView: View {
    @Environment(AudioStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = store

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Advanced Settings").font(.title3).bold()
                Spacer()
                Button("Reset to defaults") {
                    store.settings = .defaults
                    store.persistSettings()
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20).padding(.top, 18)

            Form {
                Section("Generation") {
                    sliderRow(title: "Classifier-free guidance (CFG)",
                              value: $store.settings.cfgValue,
                              range: 1.0 ... 5.0,
                              format: "%.1f",
                              help: "Higher values push the model harder toward your prompt at the cost of naturalness. Default 2.0.")

                    Stepper(value: $store.settings.inferenceTimesteps, in: 4 ... 50) {
                        HStack {
                            Text("Inference timesteps")
                            Spacer()
                            Text("\(store.settings.inferenceTimesteps)").monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("More timesteps = higher quality, slower. Default 10.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Seed") {
                    HStack {
                        Toggle("Lock seed", isOn: $store.settings.seedLocked)
                        Spacer()
                        TextField("Seed", value: $store.settings.seed,
                                  format: .number)
                            .frame(width: 120).monospacedDigit()
                            .disabled(!store.settings.seedLocked)
                        Button {
                            store.settings.seed = Int.random(in: 0 ... 999_999)
                        } label: {
                            Image(systemName: "die.face.5")
                        }
                        .help("Roll a new random seed")
                        .disabled(!store.settings.seedLocked)
                    }
                    Text("When unlocked, the model picks a fresh seed every run.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Output") {
                    Picker("Format", selection: $store.settings.outputFormat) {
                        ForEach(AdvancedSettings.OutputFormat.allCases) { f in
                            Text(f.label).tag(f)
                        }
                    }
                    Toggle("Normalize peak (-0.3 dB)", isOn: $store.settings.normalize)
                }

                Section("Runtime") {
                    Picker("Device", selection: $store.settings.device) {
                        ForEach(AdvancedSettings.Device.allCases) { d in
                            Text(d.label).tag(d)
                        }
                    }
                    Text("Device choice applies to subsequent app launches; "
                       + "VoxCPM picks MPS automatically on Apple Silicon.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(.horizontal, 8)

            Divider()
            HStack {
                Spacer()
                Button("Done") {
                    store.persistSettings()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 540)
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>,
                           format: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }
}
