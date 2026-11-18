import Foundation
import Combine

/// Who said a given line.
enum Speaker: String {
    case them = "Them"
    case you = "You"
}

/// One finished transcript line, with speaker + timestamp and (optionally) its
/// Russian translation, which streams in after the line is committed.
struct TranscriptLine: Identifiable, Equatable {
    let id: UUID
    let speaker: Speaker
    let at: Date
    let content: String
    var translation: String = ""

    init(id: UUID = UUID(), speaker: Speaker, at: Date, content: String, translation: String = "") {
        self.id = id
        self.speaker = speaker
        self.at = at
        self.content = content
        self.translation = translation
    }

    var clock: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: at)
    }
}

/// Observable two-sided transcript (You / Them), updated immutably.
@MainActor
final class TranscriptStore: ObservableObject {
    @Published private(set) var lines: [TranscriptLine] = []

    /// In-progress (not-yet-final) text per speaker, shown dimmer while streaming.
    @Published private(set) var partialThem: String = ""
    @Published private(set) var partialYou: String = ""
    /// Simultaneous translation of what the other side is saying right now
    /// (the sentence is not finished yet).
    @Published var partialTranslation: String = ""
    /// Finished Russian sentences from the simultaneous translation, in the
    /// order they arrived — independent of which English line they belong to.
    @Published private(set) var translatedStream: [String] = []

    func appendTranslatedSentence(_ sentence: String) {
        var next = translatedStream + [sentence]
        if next.count > 200 { next = Array(next.suffix(200)) }
        translatedStream = next
    }

    func appendDelta(_ delta: String, speaker: Speaker) {
        switch speaker {
        case .them: partialThem += delta
        case .you: partialYou += delta
        }
    }

    /// Replace the in-progress text for a speaker (streaming mode, where the
    /// client itself cuts the stream into lines).
    func setPartial(_ text: String, speaker: Speaker) {
        switch speaker {
        case .them: partialThem = text
        case .you: partialYou = text
        }
    }

    /// Discard the in-progress partial for a speaker without committing it.
    func clearPartial(_ speaker: Speaker) {
        switch speaker {
        case .them: partialThem = ""
        case .you: partialYou = ""
        }
    }

    /// Commit a complete transcribed line. Returns the new line, or nil if it was empty.
    @discardableResult
    func commit(_ line: String, speaker: Speaker, now: Date = Date()) -> TranscriptLine? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let newLine = TranscriptLine(speaker: speaker, at: now, content: trimmed)
        var next = lines + [newLine]
        if next.count > Config.transcriptLineLimit {
            next = Array(next.suffix(Config.transcriptLineLimit))
        }
        lines = next
        return newLine
    }

    /// Append a streamed piece of translation to an already-committed line.
    /// Translations target recent lines, so search from the end.
    func appendTranslation(_ delta: String, to id: UUID) {
        guard let index = lines.lastIndex(where: { $0.id == id }) else { return }
        lines[index].translation += delta
    }

    /// Attach a whole translated sentence to a line (space-separated from any
    /// sentence already there).
    func addTranslatedSentence(_ sentence: String, to id: UUID) {
        guard let index = lines.lastIndex(where: { $0.id == id }) else { return }
        let existing = lines[index].translation
        lines[index].translation = existing.isEmpty ? sentence : existing + " " + sentence
    }

    /// Recent transcript (speaker-labelled) for suggestion requests.
    func recentContext(now: Date = Date()) -> String {
        let cutoff = now.addingTimeInterval(-Config.suggestionContextWindow)
        let recent = lines.filter { $0.at >= cutoff }
        let chosen = recent.count < 4 ? Array(lines.suffix(4)) : recent
        return chosen.map { "\($0.speaker.rawValue): \($0.content)" }.joined(separator: "\n")
    }

    /// The last `count` lines, speaker-labelled (for the goal check).
    func tail(_ count: Int) -> String {
        lines.suffix(count).map { "\($0.speaker.rawValue): \($0.content)" }.joined(separator: "\n")
    }

    /// The few lines preceding `id`, as context for translating it.
    func contextBefore(_ id: UUID, count: Int = 3) -> [String] {
        guard let index = lines.lastIndex(where: { $0.id == id }) else { return [] }
        return lines[max(0, index - count)..<index].map { "\($0.speaker.rawValue): \($0.content)" }
    }

    func clear() {
        lines = []
        partialThem = ""
        partialYou = ""
        partialTranslation = ""
        translatedStream = []
    }
}
