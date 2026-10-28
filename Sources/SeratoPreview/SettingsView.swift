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
                Section(tr("Lingua", "Language")) {
                    Picker(tr("Lingua", "Language"), selection: $draft.language) {
                        ForEach(PreviewSettings.Language.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                }

                Section(tr("Attivazione", "Activation")) {
                    Picker(tr("Tasto", "Key"), selection: $draft.modifier) {
                        ForEach(PreviewSettings.Modifier.allCases) { modifier in
                            Text(tr("\(modifier.symbol) + clic", "\(modifier.symbol) + click")).tag(modifier)
                        }
                    }
                }

                Section(tr("Uscita audio", "Audio output")) {
                    Picker(tr("Dispositivo", "Device"), selection: $draft.outputDeviceUID) {
                        Text(tr("Uscita di sistema", "System output")).tag(String?.none)
                        ForEach(devices, id: \.uid) { device in
                            Text(tr("\(device.name) (\(device.outputChannels) canali)", "\(device.name) (\(device.outputChannels) channels)")).tag(Optional(device.uid))
                        }
                    }
                    Picker(tr("Canali", "Channels"), selection: firstChannel) {
                        ForEach(Array(stride(from: 1, to: max(selectedDeviceChannels, 2), by: 2)), id: \.self) { first in
                            Text("\(first)-\(first + 1)").tag(first)
                        }
                    }
                    LabeledContent(tr("Partenza", "Start at")) {
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
                    Stepper(tr("Salto con ← →: ", "← → seek step: ") + "\(Int(draft.seekStep)) s", value: $draft.seekStep, in: 1...30)
                }

                Section(tr("Browser di Serato (punti)", "Serato browser (points)")) {
                    TextField(tr("Altezza riga", "Row height"), value: $draft.rowHeight, format: .number)
                    TextField(tr("Margine sinistro", "Left margin"), value: $draft.browserInsets.left, format: .number)
                    TextField(tr("Margine superiore", "Top margin"), value: $draft.browserInsets.top, format: .number)
                    TextField(tr("Margine destro", "Right margin"), value: $draft.browserInsets.right, format: .number)
                    TextField(tr("Margine inferiore", "Bottom margin"), value: $draft.browserInsets.bottom, format: .number)
                    TextField(tr("Righe catturate", "Captured rows"), value: $draft.captureRows, format: .number)
                    TextField(tr("Distanza testo troncato", "Truncated text gap"), value: $draft.truncationGap,
                              format: .number)
                }

                Section(tr("Riconoscimento", "Recognition")) {
                    LabeledContent(tr("Punteggio minimo", "Minimum score")) {
                        HStack {
                            Slider(value: $draft.minimumScore, in: 0.3...0.95, step: 0.05)
                            Text(String(format: "%.2f", draft.minimumScore)).monospacedDigit().frame(width: 40)
                        }
                    }
                    Toggle(tr("OCR veloce", "Fast OCR"), isOn: $draft.fastOCR)
                }

                if let error = controller.settingsErrorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button(tr("Valori predefiniti", "Defaults")) { draft = .defaults }
                Button(tr("Apri settings.json", "Open settings.json")) { NSWorkspace.shared.open(PreviewSettings.fileURL) }
                Spacer()
                Button(tr("Annulla", "Cancel")) { draft = controller.settings }
                    .disabled(draft == controller.settings)
                Button(tr("Salva", "Save")) { controller.apply(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft == controller.settings)
            }
            .padding()
        }
        .frame(width: 500, height: 740)
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
