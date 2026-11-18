import Foundation
import Combine

/// One goal for the meeting, taken from the profile's "Meeting goals" section.
struct MeetingGoal: Identifiable, Equatable {
    enum Status: String {
        case open
        case progress
        case done
    }

    /// 1-based position in the profile — also how the model refers to it.
    let id: Int
    let text: String
    var status: Status = .open
    /// Short Russian note on what the status is based on.
    var note: String = ""
    /// The user set the status by hand; the model must not change it.
    var manual = false
}

/// A status update for one goal, as parsed from the model's answer.
struct GoalUpdate: Equatable {
    let id: Int
    let status: MeetingGoal.Status
    let note: String
}

/// Pure helpers (unit-tested).
enum GoalParser {
    static let maxGoals = 8

    /// Bullets of the "Meeting goals" / "Цели" section of a profile.
    /// Placeholder bullets ("TODO …") are skipped.
    static func goals(fromMarkdown markdown: String) -> [String] {
        var inSection = false
        var out: [String] = []
        for raw in MeetingProfile.stripComments(markdown).split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                let title = line.drop { $0 == "#" || $0 == " " }.lowercased()
                inSection = title.hasPrefix("meeting goals") || title.hasPrefix("goals") || title.hasPrefix("цели")
                continue
            }
            guard inSection, let bullet = bulletText(line) else { continue }
            if bullet.uppercased().contains("TODO") || bullet.isEmpty { continue }
            out.append(bullet)
            if out.count == maxGoals { break }
        }
        return out
    }

    private static func bulletText(_ line: String) -> String? {
        for prefix in ["- [ ] ", "- [x] ", "- ", "* ", "• "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        // "1. goal"
        if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty {
            return String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Parse the model's answer: one line per goal, "<number>|<status>|<note>".
    static func updates(fromModelOutput output: String) -> [GoalUpdate] {
        output.split(separator: "\n").compactMap { raw in
            let parts = raw.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2,
                  let id = Int(parts[0].filter(\.isNumber)),
                  let status = MeetingGoal.Status(rawValue: parts[1].lowercased())
            else { return nil }
            return GoalUpdate(id: id, status: status, note: parts.count > 2 ? parts[2] : "")
        }
    }
}

/// The meeting's goal checklist shown in the overlay.
@MainActor
final class GoalStore: ObservableObject {
    @Published private(set) var goals: [MeetingGoal] = []

    var doneCount: Int { goals.filter { $0.status == .done }.count }
    var hasOpenGoals: Bool { goals.contains { $0.status != .done } }

    /// Load goals from a profile. Statuses are kept when the list is unchanged
    /// (e.g. the user re-saved the file mid-meeting without touching the goals).
    func load(fromMarkdown markdown: String, resetStatuses: Bool) {
        let texts = GoalParser.goals(fromMarkdown: markdown)
        if !resetStatuses, texts == goals.map(\.text) { return }
        goals = texts.enumerated().map { MeetingGoal(id: $0.offset + 1, text: $0.element) }
    }

    /// Apply the model's assessment. A goal never goes backwards on its own
    /// (speech-recognition noise must not un-tick it), and goals the user set
    /// by hand are left alone.
    func apply(_ updates: [GoalUpdate]) {
        var next = goals
        for update in updates {
            guard let index = next.firstIndex(where: { $0.id == update.id }), !next[index].manual else { continue }
            let current = next[index].status
            let rank: [MeetingGoal.Status: Int] = [.open: 0, .progress: 1, .done: 2]
            guard rank[update.status]! >= rank[current]! else { continue }
            next[index].status = update.status
            if !update.note.isEmpty { next[index].note = update.note }
        }
        goals = next
    }

    /// Click on a goal: tick / untick it by hand.
    func toggle(_ id: Int) {
        guard let index = goals.firstIndex(where: { $0.id == id }) else { return }
        goals[index].status = goals[index].status == .done ? .open : .done
        goals[index].manual = true
        goals[index].note = goals[index].status == .done ? "отмечено вручную" : ""
    }

    /// Goal list with statuses, for prompts and for the saved notes.
    var promptSummary: String {
        guard !goals.isEmpty else { return "" }
        return goals.map { goal in
            let mark: String
            switch goal.status {
            case .done: mark = "ACHIEVED"
            case .progress: mark = "IN PROGRESS"
            case .open: mark = "OPEN"
            }
            return "\(goal.id). [\(mark)] \(goal.text)"
        }.joined(separator: "\n")
    }
}
