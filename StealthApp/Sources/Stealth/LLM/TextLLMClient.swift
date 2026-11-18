import Foundation

/// Minimal streaming client for the OpenAI text API (Chat Completions over SSE).
/// Used for live translation and reply suggestions. Only TEXT is sent here — audio
/// goes exclusively through `RealtimeClient`.
enum TextLLMClient {
    struct Message {
        let role: String
        let content: String
    }

    enum ClientError: LocalizedError {
        case noAPIKey
        case http(String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "Нет API-ключа — откройте Настройки."
            case .http(let message): return message
            }
        }
    }

    /// Reports token usage of every finished request (model, input, cached input, output).
    @MainActor static var onUsage: ((String, Int, Int, Int) -> Void)?

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.waitsForConnectivity = false
        return URLSession(configuration: cfg)
    }()

    /// Stream a completion, delivering text pieces on the main actor as they arrive.
    /// Throws `CancellationError` if the surrounding task is cancelled.
    static func stream(
        model: String,
        messages: [Message],
        maxTokens: Int,
        onDelta: @MainActor @escaping (String) -> Void
    ) async throws {
        guard let apiKey = KeychainStore.load() else { throw ClientError.noAPIKey }

        var request = URLRequest(url: Config.chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        // Only parameters accepted by every current chat model (no temperature:
        // reasoning-family models reject non-default values).
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            // Ask for exact token counts at the end of the stream (for the cost meter).
            "stream_options": ["include_usage": true],
            "max_completion_tokens": maxTokens,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 16_384 { break }
            }
            throw ClientError.http(SSEParser.errorMessage(fromBody: data, status: status))
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            switch SSEParser.parse(line: line) {
            case .delta(let text): await onDelta(text)
            case .usage(let input, let cached, let output):
                await MainActor.run { onUsage?(model, input, cached, output) }
            case .done: return
            case nil: continue
            }
        }
    }
}
