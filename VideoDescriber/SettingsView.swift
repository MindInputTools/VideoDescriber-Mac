import SwiftUI

struct SettingsView: View {
    static let defaultSystemPrompt = "Du är en professionell syntolk. Beskriv bilden kort och objektivt för en person med synnedsättning. Svara direkt på svenska."

    @AppStorage("selectedModel") private var selectedModel = "ministral-3:latest"
    @AppStorage("systemPrompt") private var systemPrompt = SettingsView.defaultSystemPrompt
    @AppStorage("defaultQuestion") private var defaultQuestion = ""

    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false
    @State private var modelLoadError: String?

    private let ollamaClient = OllamaClient()

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

            // --- Standardfråga ---
            Section("Standardfråga (valfritt)") {
                TextField("T.ex. 'Fokusera på ansiktsuttryck och gester'", text: $defaultQuestion)
                Text("Om ifyllt läggs detta till efter systemprompten vid varje beskrivning.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 360)
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
