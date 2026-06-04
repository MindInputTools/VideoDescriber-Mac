import Foundation

enum AIBackend: String, CaseIterable, Identifiable {
    case openAICompatible = "openai_compatible"
    case mlxLocal = "mlx_local"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAICompatible:
            return "OpenAI-kompatibel server"
        case .mlxLocal:
            return "MLX lokalt på Mac"
        }
    }
}

enum MLXModel: String, CaseIterable, Identifiable {
    case gemma4E2B = "gemma4_e2b"
    case gemma4E4B = "gemma4_e4b"
    case gemma4_26B = "gemma4_26b_a4b"
    case gemma4_31B = "gemma4_31b"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gemma4E2B:
            return "Gemma 4 E2B"
        case .gemma4E4B:
            return "Gemma 4 E4B"
        case .gemma4_26B:
            return "Gemma 4 26B A4B"
        case .gemma4_31B:
            return "Gemma 4 31B"
        }
    }

    var mlxModelId: String {
        switch self {
        case .gemma4E2B:
            return "mlx-community/gemma-4-e2b-it-4bit"
        case .gemma4E4B:
            return "mlx-community/gemma-4-e4b-it-4bit"
        case .gemma4_26B:
            return "mlx-community/gemma-4-26b-a4b-it-4bit"
        case .gemma4_31B:
            return "mlx-community/gemma-4-31b-it-4bit"
        }
    }

    var shortDescription: String {
        switch self {
        case .gemma4E2B:
            return "Minst och snabbast"
        case .gemma4E4B:
            return "Bättre kvalitet, fortfarande lätt"
        case .gemma4_26B:
            return "Stor MoE-modell för Mac med gott om minne"
        case .gemma4_31B:
            return "Störst lokal modell, kräver mest RAM"
        }
    }
}
