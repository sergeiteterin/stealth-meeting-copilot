import Foundation

/// Writes a finished meeting as a Markdown note (with YAML front matter) into a
/// folder the user chose — e.g. the inbox of an Obsidian vault — so it lands in
/// their knowledge base without a manual export.
///
/// Foundation-only and unit-tested. The app's own History keeps working from
/// its JSON files; this is an additional copy.
enum NoteExporter {
    /// File-name prefix for a note that has not been filed yet.
    static let filePrefix = "UNC - "
    static let maxNameLength = 60

    /// The note text: front matter + the session's Markdown.
    static func note(for record: SessionRecord, now: Date = Date()) -> String {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        var front = [
            "---",
            "created: \(day.string(from: record.startedAt))",
            "updated: \(day.string(from: now))",
            "type: meeting",
            "status: inbox",
            "date: \(day.string(from: record.startedAt))",
            "time: \"\(clock.string(from: record.startedAt))–\(clock.string(from: record.endedAt))\"",
            "up: \"\"",
            "tags: [inbox, needs_review]",
            "source: Stealth meeting copilot",
            // Text comes from speech recognition and machine translation.
            "confidence: medium",
            "session_id: \(record.id.uuidString)",
        ]
        if let profile = record.profile, !profile.isEmpty {
            front.append("profile: \"\(profile.replacingOccurrences(of: "\"", with: "'"))\"")
        }
        front.append("---")
        return front.joined(separator: "\n") + "\n\n" + record.markdown
    }

    /// "UNC - Встреча Acme Robotics" — short, no date, no characters that
    /// file systems or Obsidian links dislike.
    static func baseName(for record: SessionRecord) -> String {
        let topic = (record.profile ?? "")
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|#^[]"))
            .joined(separator: " ")
            .components(separatedBy: " — ").first ?? ""
        let cleaned = topic.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let name = filePrefix + "Встреча" + (cleaned.isEmpty ? "" : " " + cleaned)
        return String(name.prefix(maxNameLength)).trimmingCharacters(in: .whitespaces)
    }

    /// Write (or rewrite) the note for a session. The same session always goes
    /// to the same file — found by its `session_id` — so the summary that
    /// arrives a few seconds after Stop updates the note instead of adding a
    /// second one. A different meeting with the same name gets " 2", " 3", …
    @discardableResult
    static func write(_ record: SessionRecord, to folder: URL, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = baseName(for: record)
        var index = 1
        while true {
            let name = index == 1 ? base : "\(base) \(index)"
            let url = folder.appendingPathComponent(name + ".md")
            if !fm.fileExists(atPath: url.path) || isNote(at: url, of: record.id) {
                try note(for: record, now: now).write(to: url, atomically: true, encoding: .utf8)
                return url
            }
            index += 1
        }
    }

    private static func isNote(at url: URL, of id: UUID) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // Lossy decoding on purpose: a fixed-size read can end in the middle of a
        // multi-byte (Cyrillic) character, which makes strict UTF-8 decoding fail.
        let head = String(decoding: handle.readData(ofLength: 1_024), as: UTF8.self)
        return head.contains("session_id: \(id.uuidString)")
    }
}
