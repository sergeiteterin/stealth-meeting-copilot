import Foundation

/// A single archived line in a saved session. Mirrors `TranscriptLine` but is
/// `Codable` (the live `TranscriptLine.id` is a runtime UUID; here it's persisted).
struct SessionLine: Codable, Identifiable, Equatable {
    let id: UUID
    let speaker: Speaker
    let at: Date
    let content: String
    /// Russian translation, if live translation was on. Optional so sessions saved
    /// by older builds still decode.
    let translation: String?

    init(from line: TranscriptLine) {
        self.id = line.id
        self.speaker = line.speaker
        self.at = line.at
        self.content = line.content
        self.translation = line.translation.isEmpty ? nil : line.translation
    }

    var clock: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: at)
    }
}

// `Speaker` is a raw-value enum → free `Codable` conformance.
extension Speaker: Codable {}

/// One saved listening session: its time bounds and full transcript.
struct SessionRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let lines: [SessionLine]
    /// Title of the meeting profile that was active (nil for older sessions).
    let profile: String?
    /// After-meeting notes + follow-up email draft (Markdown), if generated.
    var summary: String?
    /// Estimated OpenAI cost of the session in USD (nil for older sessions).
    var costUSD: Double?

    init(id: UUID = UUID(), startedAt: Date, endedAt: Date, lines: [SessionLine],
         profile: String? = nil, summary: String? = nil) {
        self.summary = summary
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lines = lines
        self.profile = profile
    }

    var lineCount: Int { lines.count }

    var duration: TimeInterval { max(0, endedAt.timeIntervalSince(startedAt)) }

    /// "Mon 30 Jun, 21:57"
    var title: String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM, HH:mm"
        return f.string(from: startedAt)
    }

    /// "12 мин" / "45 сек"
    var durationLabel: String {
        let secs = Int(duration)
        if secs >= 60 { return "\(secs / 60) мин" }
        return "\(secs) сек"
    }

    /// Full speaker-labelled transcript as plain text (for copy / preview).
    var plainText: String {
        lines.map { line in
            var text = "[\(line.clock)] \(line.speaker.rawValue): \(line.content)"
            if let ru = line.translation { text += "\n        → \(ru)" }
            return text
        }
        .joined(separator: "\n")
    }

    /// The transcript as a Markdown document (original + translation), for export.
    var markdown: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var out = "# Встреча \(f.string(from: startedAt))\n\n"
        if let profile, !profile.isEmpty { out += "- Профиль: \(profile)\n" }
        out += "- Длительность: \(durationLabel)\n- Реплик: \(lineCount)\n"
        if let costUSD { out += "- Стоимость OpenAI (оценка): \(CostMeter.format(costUSD))\n" }
        out += "\n---\n\n"
        if let summary, !summary.isEmpty { out += summary + "\n\n---\n\n## Расшифровка\n\n" }
        for line in lines {
            out += "**\(line.speaker.rawValue)** `\(line.clock)`  \n\(line.content)\n"
            if let ru = line.translation { out += "\n> \(ru)\n" }
            out += "\n"
        }
        return out
    }

    /// Speaker-labelled English transcript, as input for the summary model.
    var transcriptForSummary: String {
        lines.map { "\($0.speaker.rawValue): \($0.content)" }.joined(separator: "\n")
    }

    /// "2026-11-17_1530-meeting.md"
    var suggestedFileName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmm"
        return "\(f.string(from: startedAt))-meeting.md"
    }
}
