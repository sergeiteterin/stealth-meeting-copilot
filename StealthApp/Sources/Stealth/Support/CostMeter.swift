import Foundation

/// Running ESTIMATE of what the current session costs on the OpenAI API.
///
/// Audio models are billed per minute of audio sent; text models per token
/// (the API reports exact token counts at the end of every response). Prices
/// are OpenAI list prices known at build time — they change, and the account's
/// invoice is the only exact figure. Foundation-only, unit-tested.
struct CostMeter: Equatable {
    /// USD per minute of audio.
    static let audioPerMinute: [String: Double] = [
        "gpt-live-transcribe": 0.017,
        "gpt-realtime-translate": 0.034,
        "gpt-4o-transcribe": 0.006,
        "gpt-4o-mini-transcribe": 0.003,
    ]

    /// USD per million tokens: (fresh input, cached input, output).
    static let textPerMillion: [String: (input: Double, cached: Double, output: Double)] = [
        "gpt-4.1-mini": (0.40, 0.10, 1.60),
        "gpt-4.1-nano": (0.10, 0.025, 0.40),
        "gpt-4.1": (2.00, 0.50, 8.00),
        "gpt-4o-mini": (0.15, 0.075, 0.60),
        "gpt-4o": (2.50, 1.25, 10.00),
    ]

    private(set) var audioSeconds: [String: Double] = [:]
    private(set) var audioUSD = 0.0
    private(set) var textUSD = 0.0
    private(set) var textRequests = 0
    /// Models used that have no price in the tables above (their cost is NOT included).
    private(set) var unpriced: Set<String> = []

    var totalUSD: Double { audioUSD + textUSD }

    /// Price for a model id, also matching dated snapshots ("gpt-4.1-mini-2025-04-14").
    private static func lookup<T>(_ model: String, in table: [String: T]) -> T? {
        if let exact = table[model] { return exact }
        let match = table.keys.filter { model.hasPrefix($0) }.max { $0.count < $1.count }
        return match.flatMap { table[$0] }
    }

    mutating func addAudio(model: String, seconds: Double) {
        guard seconds > 0 else { return }
        audioSeconds[model, default: 0] += seconds
        if let rate = Self.lookup(model, in: Self.audioPerMinute) {
            audioUSD += seconds / 60 * rate
        } else {
            unpriced.insert(model)
        }
    }

    mutating func addText(model: String, inputTokens: Int, cachedTokens: Int, outputTokens: Int) {
        textRequests += 1
        guard let price = Self.lookup(model, in: Self.textPerMillion) else {
            unpriced.insert(model)
            return
        }
        let fresh = max(0, inputTokens - cachedTokens)
        textUSD += (Double(fresh) * price.input + Double(cachedTokens) * price.cached
                    + Double(outputTokens) * price.output) / 1_000_000
    }

    /// "≈ $0.42" — more digits while the amount is still tiny.
    static func format(_ usd: Double) -> String {
        usd < 0.1 ? String(format: "≈ $%.3f", usd) : String(format: "≈ $%.2f", usd)
    }

    var label: String { Self.format(totalUSD) + (unpriced.isEmpty ? "" : "+") }

    /// Multi-line breakdown for the tooltip.
    var breakdown: String {
        var rows: [String] = []
        for (model, seconds) in audioSeconds.sorted(by: { $0.key < $1.key }) {
            let cost = Self.lookup(model, in: Self.audioPerMinute).map { Self.format(seconds / 60 * $0) } ?? "цена неизвестна"
            rows.append(String(format: "%@: %.1f мин — %@", model, seconds / 60, cost))
        }
        rows.append("Перевод текста, подсказки, цели, резюме: \(textRequests) запросов — \(Self.format(textUSD))")
        if !unpriced.isEmpty {
            rows.append("Не учтено (нет цены): \(unpriced.sorted().joined(separator: ", "))")
        }
        rows.append("Оценка по прайсу OpenAI; точная сумма — в кабинете OpenAI.")
        return rows.joined(separator: "\n")
    }
}
