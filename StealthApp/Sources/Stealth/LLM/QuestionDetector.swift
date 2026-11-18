import Foundation

/// Cheap local heuristic that decides whether a transcribed line from the other
/// side is a question / request that deserves an automatic reply suggestion.
///
/// Deliberately local (no API call): it runs on every "Them" line, must add zero
/// latency, and a miss is recoverable with the manual hotkey (⌥Space).
enum QuestionDetector {
    /// Sentence openers that mark a question or a request even when the speech
    /// recogniser drops the question mark.
    private static let openers: [String] = [
        "what", "why", "how", "when", "where", "who", "whom", "whose", "which",
        "can you", "could you", "would you", "will you", "do you", "did you", "does your",
        "are you", "is your", "is there", "are there", "have you", "has your",
        "can we", "could we", "should we", "shall we", "may i", "can i",
        "tell me", "tell us", "walk me through", "walk us through", "talk me through",
        "explain", "describe", "give me", "give us", "share your", "let me know",
        "i'd like to know", "i would like to know", "i'm curious", "i am curious",
        "i wonder", "i was wondering", "any thoughts", "any questions", "what about", "how about",
    ]

    /// Phrases that turn the end of a statement into a question addressed to the user.
    private static let tails: [String] = [
        "right", "correct", "isn't it", "don't you", "doesn't it", "aren't you",
        "what do you think", "your thoughts", "does that make sense", "make sense",
        "on your side", "from your side",
    ]

    static func isQuestion(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Too short to be a real question ("What?", "Sorry?") — not worth a suggestion.
        guard text.split(separator: " ").count >= 3 else { return false }
        if text.contains("?") { return true }

        // Check each sentence of the line: the question is often the last one.
        let sentences = text
            .split(whereSeparator: { ".!;".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for sentence in sentences {
            let stripped = stripLeadIn(sentence)
            if openers.contains(where: { startsWithPhrase(stripped, $0) }) { return true }
        }
        if let last = sentences.last {
            let trimmed = last.trimmingCharacters(in: CharacterSet(charactersIn: ", "))
            if tails.contains(where: { trimmed.hasSuffix($0) }) { return true }
        }
        return false
    }

    /// Drop conversational lead-ins ("So, and, okay, well …") before testing the opener.
    private static func stripLeadIn(_ sentence: String) -> String {
        var s = sentence
        let leadIns = ["so", "and", "but", "okay", "ok", "well", "now", "also", "then", "alright", "all right", "great", "yeah", "yes"]
        var changed = true
        while changed {
            changed = false
            for lead in leadIns where startsWithPhrase(s, lead) {
                s = String(s.dropFirst(lead.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: ", "))
                changed = true
            }
        }
        return s
    }

    /// True when `text` starts with `phrase` on a word boundary ("who" ≠ "whole").
    private static func startsWithPhrase(_ text: String, _ phrase: String) -> Bool {
        guard text.hasPrefix(phrase) else { return false }
        guard let next = text.dropFirst(phrase.count).first else { return true }
        return !next.isLetter && next != "'"
    }
}
