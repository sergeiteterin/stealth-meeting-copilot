import Foundation
import Combine

/// A meeting profile = one plain Markdown file the user can edit in any editor.
struct MeetingProfile: Identifiable, Equatable {
    /// File name without the `.md` extension (stable identifier).
    let id: String
    /// First `# Heading` of the file, or the file name.
    let title: String
    let url: URL

    /// Pull the display title out of the Markdown: the first level-1 heading.
    static func title(fromMarkdown markdown: String, fallback: String) -> String {
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true).prefix(20) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") {
                let title = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { return title }
            }
        }
        return fallback
    }

    /// Strip HTML comments (`<!-- … -->`, used as editing hints in the templates)
    /// so they are not sent to the model.
    static func stripComments(_ markdown: String) -> String {
        var out = markdown
        while let start = out.range(of: "<!--") {
            if let end = out.range(of: "-->", range: start.upperBound..<out.endIndex) {
                out.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                out.removeSubrange(start.lowerBound..<out.endIndex)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Meeting-context profiles stored as Markdown files in
/// `~/Library/Application Support/Stealth/profiles/`. The folder is seeded once
/// with the bundled templates; after that the files belong to the user.
@MainActor
final class ProfileStore: ObservableObject {
    /// Meeting profiles the user can pick from.
    @Published private(set) var profiles: [MeetingProfile] = []
    /// Always-on context: files whose name starts with "_" (e.g. `_About us.md`).
    /// They describe OUR side and are added to every meeting, whatever profile is selected.
    @Published private(set) var sharedProfiles: [MeetingProfile] = []

    let directory: URL
    private let fileManager = FileManager.default

    /// - Parameters:
    ///   - directory: where profiles live (overridable for tests).
    ///   - seedDirectory: folder with the bundled default `.md` files.
    init(directory: URL? = nil, seedDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("Profiles")) {
        if let directory {
            self.directory = directory
        } else if let override = UserDefaults.standard.string(forKey: "profilesDir"), !override.isEmpty {
            // `-profilesDir <path>` on the command line: use another set of profiles
            // (e.g. the bundled templates for a demo) without touching the user's own.
            self.directory = URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.directory = base.appendingPathComponent("Stealth/profiles", isDirectory: true)
        }
        seedIfNeeded(from: seedDirectory)
        reload()
    }

    /// Copy the bundled templates only when the folder does not exist yet, so a
    /// profile the user deleted or renamed never reappears.
    private func seedIfNeeded(from seedDirectory: URL?) {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            DebugLog.log("ProfileStore: create dir failed: \(error.localizedDescription)")
            return
        }
        guard let seedDirectory,
              let seeds = try? fileManager.contentsOfDirectory(at: seedDirectory, includingPropertiesForKeys: nil)
        else { return }
        for seed in seeds where seed.pathExtension.lowercased() == "md" {
            try? fileManager.copyItem(at: seed, to: directory.appendingPathComponent(seed.lastPathComponent))
        }
    }

    /// Re-scan the folder (files may have been added, renamed or edited outside the app).
    func reload() {
        let urls = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let all: [MeetingProfile] = urls
            .filter { $0.pathExtension.lowercased() == "md" }
            .map { (url: URL) -> MeetingProfile in
                let id = url.deletingPathExtension().lastPathComponent
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                return MeetingProfile(id: id, title: MeetingProfile.title(fromMarkdown: text, fallback: id), url: url)
            }
            .sorted { (l: MeetingProfile, r: MeetingProfile) in l.title.localizedCaseInsensitiveCompare(r.title) == .orderedAscending }
        profiles = all.filter { !$0.id.hasPrefix("_") }
        sharedProfiles = all.filter { $0.id.hasPrefix("_") }
    }

    func profile(id: String) -> MeetingProfile? {
        profiles.first { $0.id == id }
    }

    /// Current file contents (read fresh on every call, so edits apply immediately —
    /// even in the middle of a meeting), with editing hints stripped.
    func context(for id: String) -> String {
        // The meeting itself first, then the always-on files about our side.
        let files = ([profile(id: id)].compactMap { $0 }) + sharedProfiles
        return files
            .compactMap { try? String(contentsOf: $0.url, encoding: .utf8) }
            .map(MeetingProfile.stripComments)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n---\n\n")
    }

    /// Raw Markdown of one profile (for reading its goals).
    func markdown(for id: String) -> String {
        guard let profile = profile(id: id) else { return "" }
        return (try? String(contentsOf: profile.url, encoding: .utf8)) ?? ""
    }

    /// Create a new profile file from a blank template and return it.
    @discardableResult
    func createProfile() -> MeetingProfile? {
        var name = "New Meeting"
        var n = 2
        while fileManager.fileExists(atPath: directory.appendingPathComponent("\(name).md").path) {
            name = "New Meeting \(n)"
            n += 1
        }
        let url = directory.appendingPathComponent("\(name).md")
        do {
            try Self.blankTemplate.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            DebugLog.log("ProfileStore: create profile failed: \(error.localizedDescription)")
            return nil
        }
        reload()
        return profile(id: name)
    }

    static let blankTemplate = """
    # New Meeting

    <!-- Заголовок выше — это название профиля в приложении. Имя файла можно менять в Finder. -->

    ## Company
    - Who they are:

    ## Meeting goals
    -

    ## About us
    -

    ## Key facts
    -

    ## Terms (EN — RU)
    -

    ## Likely questions
    -
    """
}
