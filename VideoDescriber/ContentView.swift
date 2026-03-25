import SwiftUI
import ScreenCaptureKit

struct ContentView: View {
    @StateObject private var viewModel = MainViewModel()

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
                    ProgressView("Analyserar rörelse...")
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

            Text("Tryck § för att automatiskt analysera aktivt fönster")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Spacer()
        }
        .padding()
        .onAppear {
            viewModel.setupHotKey()
        }
    }
}

#Preview {
    ContentView()
}
