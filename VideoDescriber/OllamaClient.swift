import Foundation

/// Communicates with a locally running Ollama instance.
/// Uses the /api/chat endpoint to maintain conversation context so the model
/// can focus on what changed since the previous description.
class OllamaClient {

    private let baseURL: URL
    var model: String = "ministral-3:latest"

    /// Rolling conversation history. Kept compact — only the last
    /// `maxHistoryPairs` user/assistant exchanges are retained (plus the
    /// system message which is sent separately).
    private(set) var conversationHistory: [ChatMessage] = []

    /// How many user+assistant pairs to keep. 5 pairs = 10 messages,
    /// enough context to avoid repetition without growing unbounded.
    var maxHistoryPairs: Int = 5

    init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!) {
        self.baseURL = baseURL
    }

    // MARK: - Public API

    /// Send an image to Ollama for visual description using the chat endpoint.
    /// The conversation history is maintained automatically so the model knows
    /// what it already described.
    func describe(imageBase64: String, prompt: String, system: String) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("api/chat")

        // Build the full messages array: system + past history (text only) + current user message (with image)
        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: system, images: nil)
        ]
        messages.append(contentsOf: trimmedHistory())
        messages.append(ChatMessage(role: "user", content: prompt, images: [imageBase64]))

        let body = OllamaChatRequest(
            model: model,
            messages: messages,
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

        let decoded = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        let responseText = decoded.message.content

        // Store in history *without* the image — the assistant's text description
        // provides the context for future requests, not the raw image data.
        conversationHistory.append(ChatMessage(role: "user", content: prompt, images: nil))
        conversationHistory.append(ChatMessage(role: "assistant", content: responseText, images: nil))

        trimHistoryIfNeeded()

        return responseText
    }

    /// List available models from the local Ollama instance.
    func availableModels() async throws -> [String] {
        let endpoint = baseURL.appendingPathComponent("api/tags")
        let (data, _) = try await URLSession.shared.data(from: endpoint)
        let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        return decoded.models.map { $0.name }
    }

    /// Stream a description, calling the update closure for each token.
    func describeStreaming(imageBase64: String, prompt: String, system: String, onUpdate: @escaping (String) -> Void) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("api/chat")

        var messages: [ChatMessage] = [
            ChatMessage(role: "system", content: system, images: nil)
        ]
        messages.append(contentsOf: trimmedHistory())
        messages.append(ChatMessage(role: "user", content: prompt, images: [imageBase64]))

        let body = OllamaChatRequest(
            model: model,
            messages: messages,
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
                  let chunk = try? JSONDecoder().decode(OllamaChatResponse.self, from: lineData) else {
                continue
            }

            fullResponse += chunk.message.content
            await MainActor.run { onUpdate(fullResponse) }

            if chunk.done == true { break }
        }

        // Store in history without the image
        conversationHistory.append(ChatMessage(role: "user", content: prompt, images: nil))
        conversationHistory.append(ChatMessage(role: "assistant", content: fullResponse, images: nil))
        trimHistoryIfNeeded()

        return fullResponse
    }

    // MARK: - Conversation Management

    /// Clear conversation history so the next description starts fresh.
    func resetConversation() {
        conversationHistory.removeAll()
    }

    /// Whether there is any conversation context built up.
    var hasConversationContext: Bool {
        !conversationHistory.isEmpty
    }

    // MARK: - Private Helpers

    /// Returns the history trimmed to the last `maxHistoryPairs` exchanges.
    private func trimmedHistory() -> [ChatMessage] {
        let maxMessages = maxHistoryPairs * 2
        if conversationHistory.count <= maxMessages {
            return conversationHistory
        }
        return Array(conversationHistory.suffix(maxMessages))
    }

    /// Trims stored history in-place to avoid unbounded growth.
    private func trimHistoryIfNeeded() {
        let maxMessages = maxHistoryPairs * 2
        if conversationHistory.count > maxMessages {
            conversationHistory = Array(conversationHistory.suffix(maxMessages))
        }
    }
}

// MARK: - Codable Models

struct ChatMessage: Codable {
    let role: String
    let content: String
    let images: [String]?

    enum CodingKeys: String, CodingKey {
        case role, content, images
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        // Only encode images if non-nil and non-empty
        if let images, !images.isEmpty {
            try container.encode(images, forKey: .images)
        }
    }
}

private struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
}

struct OllamaChatResponse: Decodable {
    let model: String?
    let message: ChatMessageResponse
    let done: Bool?
}

struct ChatMessageResponse: Decodable {
    let role: String
    let content: String
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
