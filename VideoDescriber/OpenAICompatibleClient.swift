import Foundation

/// Communicates with an OpenAI-compatible chat completions endpoint.
/// Defaults to a local endpoint and keeps a compact text-only conversation
/// history so the model can focus on what changed since the previous image.
class OpenAICompatibleClient {

    static let defaultBaseURLString = "http://127.0.0.1:11434/v1"

    var baseURL: URL
    var model: String = "ministral-3:latest"
    var apiKey: String?

    /// Rolling conversation history. Kept compact — only the last
    /// `maxHistoryPairs` user/assistant exchanges are retained.
    private(set) var conversationHistory: [ConversationMessage] = []

    /// How many user+assistant pairs to keep. 5 pairs = 10 messages,
    /// enough context to avoid repetition without growing unbounded.
    var maxHistoryPairs: Int = 5

    init(baseURL: URL = URL(string: OpenAICompatibleClient.defaultBaseURLString)!) {
        self.baseURL = baseURL
    }

    // MARK: - Public API

    /// Send an image to the model for visual description using the chat completions endpoint.
    /// The conversation history is maintained automatically so the model knows
    /// what it already described.
    func describe(imageBase64: String, prompt: String, system: String) async throws -> String {
        let endpoint = endpointURL(path: "chat/completions")
        let messages = chatMessages(imageBase64: imageBase64, prompt: prompt, system: system)
        let body = OpenAIChatRequest(
            model: model,
            messages: messages,
            stream: false
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthorization(to: &request)
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        guard let responseText = decoded.choices.first?.message?.content, !responseText.isEmpty else {
            throw OpenAICompatibleError.invalidResponse
        }

        storeConversation(prompt: prompt, response: responseText)
        return responseText
    }

    /// List available models from the configured OpenAI-compatible endpoint.
    func availableModels() async throws -> [String] {
        let endpoint = endpointURL(path: "models")
        var request = URLRequest(url: endpoint)
        applyAuthorization(to: &request)
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(OpenAIModelsResponse.self, from: data)
        return decoded.data.map { $0.id }
    }

    /// Stream a description, calling the token closure with each individual token as it arrives.
    func describeStreaming(imageBase64: String, prompt: String, system: String, onToken: @escaping (String) -> Void) async throws -> String {
        let endpoint = endpointURL(path: "chat/completions")
        let messages = chatMessages(imageBase64: imageBase64, prompt: prompt, system: system)
        let body = OpenAIChatRequest(
            model: model,
            messages: messages,
            stream: true
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyAuthorization(to: &request)
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 120

        var fullResponse = ""
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        try validate(response: response, data: nil)

        for try await line in asyncBytes.lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }

            let payload: String
            if trimmedLine.hasPrefix("data:") {
                payload = String(trimmedLine.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                payload = trimmedLine
            }

            if payload == "[DONE]" { break }
            guard let lineData = payload.data(using: .utf8) else { continue }

            let token: String?
            if let chunk = try? JSONDecoder().decode(OpenAIChatStreamChunk.self, from: lineData) {
                token = chunk.choices.first?.delta.content
            } else if let response = try? JSONDecoder().decode(OpenAIChatResponse.self, from: lineData) {
                token = response.choices.first?.message?.content
            } else {
                token = nil
            }

            guard let token, !token.isEmpty else { continue }
            fullResponse += token
            await MainActor.run { onToken(token) }
        }

        guard !fullResponse.isEmpty else {
            throw OpenAICompatibleError.invalidResponse
        }

        storeConversation(prompt: prompt, response: fullResponse)
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

    private func endpointURL(path: String) -> URL {
        baseURL.appendingPathComponent(path)
    }

    private func applyAuthorization(to request: inout URLRequest) {
        guard let apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            return
        }

        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    }

    private func chatMessages(imageBase64: String, prompt: String, system: String) -> [OpenAIChatMessage] {
        var messages: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "system", content: .text(system))
        ]

        messages.append(contentsOf: trimmedHistory().map {
            OpenAIChatMessage(role: $0.role, content: .text($0.content))
        })

        messages.append(
            OpenAIChatMessage(
                role: "user",
                content: .parts([
                    OpenAIContentPart(type: "text", text: prompt, imageURL: nil),
                    OpenAIContentPart(
                        type: "image_url",
                        text: nil,
                        imageURL: OpenAIImageURL(url: "data:image/jpeg;base64,\(imageBase64)")
                    )
                ])
            )
        )

        return messages
    }

    private func validate(response: URLResponse, data: Data?) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAICompatibleError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown error"
            throw OpenAICompatibleError.serverError(httpResponse.statusCode, body)
        }
    }

    private func storeConversation(prompt: String, response: String) {
        conversationHistory.append(ConversationMessage(role: "user", content: prompt))
        conversationHistory.append(ConversationMessage(role: "assistant", content: response))
        trimHistoryIfNeeded()
    }

    /// Returns the history trimmed to the last `maxHistoryPairs` exchanges.
    private func trimmedHistory() -> [ConversationMessage] {
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

struct ConversationMessage: Codable {
    let role: String
    let content: String
}

private struct OpenAIChatRequest: Encodable {
    let model: String
    let messages: [OpenAIChatMessage]
    let stream: Bool
}

private struct OpenAIChatMessage: Encodable {
    let role: String
    let content: OpenAIMessageContent
}

private enum OpenAIMessageContent: Encodable {
    case text(String)
    case parts([OpenAIContentPart])

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let text):
            var container = encoder.singleValueContainer()
            try container.encode(text)
        case .parts(let parts):
            var container = encoder.singleValueContainer()
            try container.encode(parts)
        }
    }
}

private struct OpenAIContentPart: Encodable {
    let type: String
    let text: String?
    let imageURL: OpenAIImageURL?

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageURL = "image_url"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(imageURL, forKey: .imageURL)
    }
}

private struct OpenAIImageURL: Encodable {
    let url: String
}

private struct OpenAIChatResponse: Decodable {
    let choices: [OpenAIChoice]
}

private struct OpenAIChoice: Decodable {
    let message: OpenAIResponseMessage?
}

private struct OpenAIResponseMessage: Decodable {
    let content: String
}

private struct OpenAIChatStreamChunk: Decodable {
    let choices: [OpenAIStreamChoice]
}

private struct OpenAIStreamChoice: Decodable {
    let delta: OpenAIStreamDelta
}

private struct OpenAIStreamDelta: Decodable {
    let content: String?
}

private struct OpenAIModelsResponse: Decodable {
    let data: [OpenAIModel]
}

private struct OpenAIModel: Decodable {
    let id: String
}

// MARK: - Errors

enum OpenAICompatibleError: LocalizedError {
    case invalidResponse
    case serverError(Int, String)
    case invalidBaseURL(String)
    case noImageProvided

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Ogiltigt svar från AI-servern"
        case .serverError(let code, let body): return "Serverfel \(code): \(body)"
        case .invalidBaseURL(let value): return "Ogiltig bas-URL: \(value)"
        case .noImageProvided: return "Ingen bild tillhandahållen"
        }
    }
}
