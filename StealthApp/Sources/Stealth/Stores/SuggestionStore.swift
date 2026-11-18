import Foundation
import Combine

/// Holds the latest suggested reply plus loading / error state for the overlay card.
@MainActor
final class SuggestionStore: ObservableObject {
    @Published private(set) var text: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var error: String?
    /// Which kind of suggestion is currently shown (for the card header).
    @Published private(set) var mode: SuggestionMode = .reply

    /// The words to say — the model's first line, without the "# note" line.
    var reply: String {
        let head = text.components(separatedBy: "\n#").first ?? text
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the suggestion is doing (goal + move), from the model's "# …" line.
    var note: String {
        guard let range = text.range(of: "\n#") else { return "" }
        return text[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "# \n\t"))
    }

    /// True when the current suggestion was triggered automatically by a detected question.
    @Published private(set) var isAuto: Bool = false

    /// Russian translation of the suggested English text, so the user knows
    /// exactly what they are about to say.
    @Published private(set) var translation: String = ""

    func appendTranslation(_ delta: String) {
        translation += delta
    }

    func begin(mode: SuggestionMode = .reply, auto: Bool = false) {
        translation = ""
        self.mode = mode
        isAuto = auto
        isLoading = true
        error = nil
        text = ""
    }

    /// Streaming token from the model response.
    func appendDelta(_ delta: String) {
        text += delta
    }

    func finish() {
        isLoading = false
    }

    func fail(_ message: String) {
        isLoading = false
        error = message
    }

    func reset() {
        translation = ""
        text = ""
        isLoading = false
        error = nil
    }
}
