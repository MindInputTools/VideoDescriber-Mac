import Foundation
import CoreGraphics
import CoreImage
import MLX
import Hub
import HuggingFace
import Tokenizers
import MLXLMCommon
import MLXHuggingFace
import MLXVLM

actor MLXEngine {
    static let shared = MLXEngine()

    enum EngineState: Sendable {
        case idle
        case downloading(progress: Double)
        case loading
        case ready
        case generating
        case error(String)
    }

    private(set) var state: EngineState = .idle
    private var container: ModelContainer?
    private var currentModel: MLXModel?

    private init() {
        Memory.cacheLimit = 256 * 1024 * 1024
    }

    func loadModel(_ model: MLXModel) async throws {
        if currentModel == model, case .ready = state {
            return
        }

        unloadModel()
        state = .downloading(progress: 0)

        let config = ModelConfiguration(id: model.mlxModelId)

        do {
            let loadedContainer = try await loadModelContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: config
            ) { [weak self] progress in
                Task { await self?.updateProgress(progress.fractionCompleted) }
            }

            container = loadedContainer
            currentModel = model
            state = .ready
        } catch {
            state = .error(error.localizedDescription)
            throw error
        }
    }

    func unloadModel() {
        container = nil
        currentModel = nil
        state = .idle
        Memory.clearCache()
    }

    private func updateProgress(_ progress: Double) {
        if case .downloading = state {
            state = .downloading(progress: min(progress, 1.0))
        }
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    func runAnalysis(
        image: CGImage,
        systemMessage: String,
        userPrompt: String,
        continuation: AsyncThrowingStream<String, any Error>.Continuation
    ) async {
        Memory.clearCache()

        guard let container, case .ready = state else {
            continuation.finish(throwing: EngineError.modelNotLoaded)
            return
        }

        state = .generating

        do {
            let lmInput: LMInput = try await {
                let ciImage = CIImage(cgImage: image)
                let input = UserInput(
                    chat: [
                        .system(systemMessage),
                        .user(userPrompt, images: [.ciImage(ciImage)])
                    ]
                )
                return try await container.prepare(input: input)
            }()

            var parameters = GenerateParameters()
            parameters.temperature = 0.7
            parameters.topP = 0.9
            parameters.maxTokens = 2048

            let stream = try await container.generate(
                input: lmInput,
                parameters: parameters
            )

            for await generation in stream {
                switch generation {
                case .chunk(let text):
                    continuation.yield(text)
                default:
                    break
                }
            }

            state = .ready
            continuation.finish()
        } catch {
            state = .error(error.localizedDescription)
            continuation.finish(throwing: error)
        }

        Memory.clearCache()
    }

    enum EngineError: Error, LocalizedError {
        case modelNotLoaded

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "MLX-modellen är inte laddad."
            }
        }
    }
}
