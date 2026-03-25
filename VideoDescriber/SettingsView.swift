import SwiftUI

struct SettingsView: View {
    static let defaultSystemPrompt = "Du är en professionell syntolk. Beskriv bilden kort och objektivt för en person med synnedsättning. Svara direkt på svenska."
    static let defaultDefaultQuestion = "Utför din uppgift enligt din systemroll"
    @AppStorage("selectedModel") private var selectedModel = "ministral-3:latest"
    @AppStorage("systemPrompt") private var systemPrompt = SettingsView.defaultSystemPrompt
    @AppStorage("defaultQuestion") private var defaultQuestion =
    SettingsView.defaultDefaultQuestion
    @AppStorage("useVoiceOver") private var useVoiceOver = false
    @AppStorage("selectedVoice") private var selectedVoice = ""
    @AppStorage("speechRate") private var speechRate: Double = 175

    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?

    private let ollamaClient = OllamaClient()
    private let voices: [(id: String, label: String)] = {
        NSSpeechSynthesizer.availableVoices.map { voice in
            let attrs = NSSpeechSynthesizer.attributes(forVoice: voice)
            let name = attrs[.name] as? String ?? voice.rawValue
            let lang = attrs[.localeIdentifier] as? String ?? ""
            return (id: voice.rawValue, label: "\(name) [\(lang)]")
        }
    }()

    var body: some View {
        Form {
            // --- Modellval ---
            Section("Modell") {
                if isLoadingModels {
                    ProgressView("Hämtar modeller...")
                } else if let error = modelLoadError {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kunde inte hämta modeller: \(error)")
                            .foregroundColor(.red)
                            .font(.caption)
                        Button("Försök igen") {
                            Task { await loadModels() }
                        }
                    }
                    TextField("Modellnamn", text: $selectedModel)
                } else {
                    Picker("Aktiv modell", selection: $selectedModel) {
                        ForEach(availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }
            }

            // --- Systemprompt ---
            Section("Systemprompt") {
                TextEditor(text: $systemPrompt)
                    .font(.body)
                    .frame(minHeight: 80)
                    .border(Color.secondary.opacity(0.3))

                Button("Återställ standard") {
                    systemPrompt = SettingsView.defaultSystemPrompt
                }
                .font(.caption)
            }

            // --- Tal ---
            Section("Tal") {
                Toggle("Använd VoiceOver för tal", isOn: $useVoiceOver)
                Text("Med VoiceOver pausas videon men du startar den manuellt. Med systemtal pausas och återupptas videon automatiskt, och du kan stoppa talet med §-tangenten.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Picker("Röst (systemtal)", selection: $selectedVoice) {
                    Text("Systemstandard").tag("")
                    ForEach(voices, id: \.id) { voice in
                        Text(voice.label).tag(voice.id)
                    }
                }
                .disabled(useVoiceOver)

                VStack(alignment: .leading) {
                    HStack {
                        Text("Talhastighet")
                        Spacer()
                        Text("\(Int(speechRate)) ord/min")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $speechRate, in: 80...400, step: 5)
                }
                .disabled(useVoiceOver)
            }

            // --- Standardfråga ---
            Section("Standardfråga (valfritt)") {
                TextField("T.ex. 'Fokusera på ansiktsuttryck och gester'", text: $defaultQuestion)
                Button("Återställ standard") {
                    defaultQuestion = SettingsView.defaultDefaultQuestion
                }
                .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 520)
        .task {
            await loadModels()
        }
    }

    private func loadModels() async {
        isLoadingModels = true
        modelLoadError = nil
        do {
            let models = try await ollamaClient.availableModels()
            availableModels = models
            if !models.contains(selectedModel) && !models.isEmpty {
                availableModels.insert(selectedModel, at: 0)
            }
        } catch {
            modelLoadError = error.localizedDescription
            availableModels = [selectedModel]
        }
        isLoadingModels = false
    }
}
