import Foundation

/// Parses one line of an OpenAI Chat Completions server-sent-event stream.
/// Pure and Foundation-only so it can be unit-tested without the network.
enum SSEParser {
    enum Event: Equatable {
        /// A piece of generated text.
        case delta(String)
        /// The `[DONE]` sentinel — the stream is complete.
        case done
        /// Token counts for the whole response (sent once, at the end).
        case usage(input: Int, cached: Int, output: Int)
    }

    static func parse(line: String) -> Event? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let usage = obj["usage"] as? [String: Any], let input = usage["prompt_tokens"] as? Int {
            let details = usage["prompt_tokens_details"] as? [String: Any]
            return .usage(input: input,
                          cached: details?["cached_tokens"] as? Int ?? 0,
                          output: usage["completion_tokens"] as? Int ?? 0)
        }
        guard let choices = obj["choices"] as? [[String: Any]],
              let delta = choices.first?["delta"] as? [String: Any],
              let content = delta["content"] as? String,
              !content.isEmpty
        else { return nil }
        return .delta(content)
    }

    /// Extract a human-readable message from an OpenAI error response body.
    static func errorMessage(fromBody body: Data, status: Int) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let message = err["message"] as? String {
            return "OpenAI \(status): \(message)"
        }
        return "OpenAI HTTP \(status)"
    }
}
