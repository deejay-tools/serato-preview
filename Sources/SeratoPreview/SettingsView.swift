import SwiftUI
import SeratoPreviewCore

/// Impostazioni: le modifiche restano in bozza finché non si preme Salva.
struct SettingsView: View {
    @ObservedObject var controller: PreviewController
    @State private var draft: PreviewSettings
    @State private var devices: [AudioDevice] = AudioDevices.outputs()

    init(controller: PreviewController) {
        self.controller = controller
        _draft = State(initialValue: controller.settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Attivazione") {
                    Picker("Tasto", selection: $draft.modifier) {
                        ForEach(PreviewSettings.Modifier.allCases) { modifier in
                            Text("\(modifier.symbol) + clic").tag(modifier)
                        }
                    }
                }

                Section("Uscita audio") {
                    Picker("Dispositivo", selection: $draft.outputDeviceUID) {
                        Text("Uscita di sistema").tag(String?.none)
                        ForEach(devices, id: \.uid) { device in
                            Text("\(device.name) (\(device.outputChannels) canali)").tag(Optional(device.uid))
                        }
                    }
                    Picker("Canali", selection: firstChannel) {
                        ForEach(Array(stride(from: 1, to: max(selectedDeviceChannels, 2), by: 2)), id: \.self) { first in
                            Text("\(first)-\(first + 1)").tag(first)
                        }
                    }
                    LabeledContent("Partenza") {
                        HStack {
                            Slider(value: $draft.startFraction, in: 0...0.9, step: 0.05)
                            Text("\(Int((draft.startFraction * 100).rounded()))%").monospacedDigit().frame(width: 40)
                        }
                    }
                    LabeledContent("Volume") {
                        HStack {
                            Slider(value: $draft.volume, in: 0...1)
                            Text("\(Int((draft.volume * 100).rounded()))%").monospacedDigit().frame(width: 40)
                        }
                    }
                    Stepper("Salto con ← →: \(Int(draft.seekStep)) s", value: $draft.seekStep, in: 1...30)
                }

                Section("Browser di Serato (punti)") {
                    TextField("Altezza riga", value: $draft.rowHeight, format: .number)
                    TextField("Margine sinistro", value: $draft.browserInsets.left, format: .number)
                    TextField("Margine superiore", value: $draft.browserInsets.top, format: .number)
                    TextField("Margine destro", value: $draft.browserInsets.right, format: .number)
                    TextField("Margine inferiore", value: $draft.browserInsets.bottom, format: .number)
                    TextField("Righe catturate", value: $draft.captureRows, format: .number)
                    TextField("Distanza testo troncato", value: $draft.truncationGap, format: .number)
                }

                Section("Riconoscimento") {
                    LabeledContent("Punteggio minimo") {
                        HStack {
                            Slider(value: $draft.minimumScore, in: 0.3...0.95, step: 0.05)
                            Text(String(format: "%.2f", draft.minimumScore)).monospacedDigit().frame(width: 40)
                        }
                    }
                    Toggle("OCR veloce", isOn: $draft.fastOCR)
                }

                if let error = controller.settingsError {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Valori predefiniti") { draft = .defaults }
                Button("Apri settings.json") { NSWorkspace.shared.open(PreviewSettings.fileURL) }
                Spacer()
                Button("Annulla") { draft = controller.settings }
                    .disabled(draft == controller.settings)
                Button("Salva") { controller.apply(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft == controller.settings)
            }
            .padding()
        }
        .frame(width: 500, height: 680)
        .onAppear { devices = AudioDevices.outputs() }
    }

    private var selectedDeviceChannels: Int {
        AudioDevices.output(uid: draft.outputDeviceUID)?.outputChannels ?? 2
    }

    private var firstChannel: Binding<Int> {
        Binding(
            get: { draft.outputChannels.first ?? 1 },
            set: { draft.outputChannels = [$0, $0 + 1] }
        )
    }
}
