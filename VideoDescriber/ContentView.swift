import SwiftUI
import ScreenCaptureKit

struct ContentView: View {
    @StateObject private var viewModel = MainViewModel()
    @State private var showDiagnostics = false

    var body: some View {
        VStack(spacing: 16) {
            Text("VideoDescriber")
                .font(.title)
                .fontWeight(.bold)

            Divider()

            // Status
            HStack {
                Circle()
                    .fill(viewModel.statusColor)
                    .frame(width: 10, height: 10)
                Text(viewModel.statusMessage)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(.horizontal)

            // Current selection info
            if viewModel.selectedAppName != nil || viewModel.videoAreaDescription != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let app = viewModel.selectedAppName {
                        HStack(spacing: 4) {
                            Text("App:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(app)
                                .font(.caption)
                                .fontWeight(.medium)
                            if let title = viewModel.selectedWindowTitle, !title.isEmpty {
                                Text("— \(title)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                    if let area = viewModel.videoAreaDescription {
                        HStack(spacing: 4) {
                            Text("Videoyta:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(area)
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                    }
                }
                .padding(.horizontal)

                Button(action: { viewModel.resetSelection() }) {
                    Label("Återställ val", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .padding(.horizontal)
            }

            Divider()

            // Buttons
            VStack(spacing: 12) {
                Button(action: { Task { await viewModel.pickWindow() } }) {
                    Label("Välj fönster", systemImage: "rectangle.on.rectangle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isCapturing)

                Button(action: { Task { await viewModel.calibrate() } }) {
                    Label("Hitta Video (§)", systemImage: "viewfinder")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.hasCapture || viewModel.isCalibrating)

                if viewModel.isCalibrating {
                    ProgressView(viewModel.calibrationProgressMessage)
                        .progressViewStyle(.linear)
                }

                Button(action: { Task { await viewModel.describe() } }) {
                    Label("Beskriv nuvarande scen", systemImage: "eye")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.hasVideoArea || viewModel.isDescribing)

                if viewModel.isDescribing {
                    ProgressView("Analyserar med AI...")
                        .progressViewStyle(.linear)
                }
            }
            .padding(.horizontal)

            Divider()

            // AI Response
            if !viewModel.aiResponse.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Beskrivning")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        if viewModel.hasConversationContext {
                            Button(action: { viewModel.resetConversationContext() }) {
                                Label("Rensa kontext", systemImage: "eraser.line.dashed")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .accessibilityHint("Rensar AI-kontexten så nästa beskrivning börjar utan historik")
                        }
                        // Stop speaking button — only shown while speech is active
                        Button(action: { viewModel.stopSpeaking() }) {
                            Label("Avbryt uppläsning", systemImage: "stop.fill")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        // Always visible so keyboard/VO users can reach it easily,
                        // but visually dimmed when not speaking
                        .opacity(viewModel.isSpeaking ? 1.0 : 0.4)
                        .accessibilityHint("Stoppar den pågående uppläsningen av bildbeskrivningen")
                    }
                    .padding(.horizontal)

                    ScrollView {
                        Text(viewModel.aiResponse)
                            .font(.body)
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // VoiceOver label so screen reader users know what this area is
                            .accessibilityLabel("Bildbeskrivning: \(viewModel.aiResponse)")
                    }
                    .frame(maxHeight: 140)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(8)
                    .padding(.horizontal)
                    // Mark this region as a live region so VoiceOver
                    // announces updates without the user navigating to it
                    .accessibilityAddTraits(.updatesFrequently)
                }
            }

            // Continuous mode indicator
            if viewModel.isContinuousModeActive {
                HStack {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("Kontinuerligt läge aktivt — tryck § för att stoppa")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding(.horizontal)

                Button(action: { viewModel.stopContinuousMode() }) {
                    Label("Stoppa kontinuerligt läge", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .padding(.horizontal)
            } else {
                Text("Tryck § för att automatiskt analysera aktivt fönster")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // Diagnostics toggle — only shown after a calibration has produced data
            if !viewModel.detectionDiagnostics.isEmpty {
                Button(action: { showDiagnostics.toggle() }) {
                    Label(showDiagnostics ? "Dölj diagnostik" : "Visa diagnostik",
                          systemImage: showDiagnostics ? "chevron.up" : "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)

                if showDiagnostics {
                    ScrollView {
                        Text(viewModel.detectionDiagnostics)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 100)
                    .background(Color(nsColor: .textBackgroundColor))
                    .cornerRadius(6)
                    .padding(.horizontal)
                }
            }

            Spacer()
        }
        .padding()
        .onAppear {
            MainViewModel.shared = viewModel
            viewModel.setupHotKey()
        }
    }
}

#Preview {
    ContentView()
}
