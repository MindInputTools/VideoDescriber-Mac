import Foundation

/// Communicates with a locally running Ollama instance.
/// Replaces the OllamaSharp NuGet package — uses only Apple's URLSession.
class OllamaClient {

    private let baseURL: URL
    var model: String = "ministral-3:latest" // Use a vision-capable model; change to your preferred one

    init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!) {
        self.baseURL = baseURL
    }

    // MARK: - Public API

    /// Send an image to Ollama for visual description.
    /// Returns the full response string.
    func describe(imageBase64: String, prompt: String, system: String) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("api/generate")

        let body = OllamaGenerateRequest(
            model: model,
            prompt: prompt,
            system: system,
            images: [imageBase64],
            stream: false
        )

        let encoded = try JSONEncoder().encode(body)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = encoded
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw OllamaError.serverError(httpResponse.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
        return decoded.response
    }

    /// List available models from the local Ollama instance.
    func availableModels() async throws -> [String] {
        let endpoint = baseURL.appendingPathComponent("api/tags")
        let (data, _) = try await URLSession.shared.data(from: endpoint)
        let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return decoded.models.map { $0.name }
    }

    /// Stream a description, calling the update closure for each token.
    /// Use this for a more responsive UI (text appears word-by-word).
    func describeStreaming(imageBase64: String, prompt: String, system: String, onUpdate: @escaping (String) -> Void) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("api/generate")

        let body = OllamaGenerateRequest(
            model: model,
            prompt: prompt,
            system: system,
            images: [imageBase64],
            stream: true
        )

        let encoded = try JSONEncoder().encode(body)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = encoded
        request.timeoutInterval = 120

        var fullResponse = ""

        let (asyncBytes, _) = try await URLSession.shared.bytes(for: request)

        for try await line in asyncBytes.lines {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(OllamaGenerateResponse.self, from: lineData) else {
                continue
            }

            fullResponse += chunk.response
            await MainActor.run { onUpdate(fullResponse) }

            if chunk.done == true { break }
        }

        return fullResponse
    }
}

// MARK: - Codable Models

private struct OllamaGenerateRequest: Encodable {
    let model: String
    let prompt: String
    let system: String
    let images: [String]
    let stream: Bool
}

struct OllamaGenerateResponse: Decodable {
    let model: String?
    let response: String
    let done: Bool?

    enum CodingKeys: String, CodingKey {
        case model, response, done
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        response = try container.decode(String.self, forKey: .response)
        done = try container.decodeIfPresent(Bool.self, forKey: .done)
    }
}

private struct OllamaTagsResponse: Decodable {
    let models: [OllamaModel]
}

private struct OllamaModel: Decodable {
    let name: String
}

// MARK: - Errors

enum OllamaError: LocalizedError {
    case invalidResponse
    case serverError(Int, String)
    case noImageProvided

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Ogiltigt svar från Ollama"
        case .serverError(let code, let body): return "Serverfell \(code): \(body)"
        case .noImageProvided: return "Ingen bild tillhandahållen"
        }
    }
}
