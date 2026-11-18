import Foundation
import Combine

/// User-facing switches, persisted in `UserDefaults`.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard

    /// Live EN → RU translation of transcript lines.
    @Published var translationEnabled: Bool { didSet { defaults.set(translationEnabled, forKey: "translationEnabled") } }
    /// Also translate the user's own (mic) lines. Off by default — halves the translation calls.
    @Published var translateOwnSpeech: Bool { didSet { defaults.set(translateOwnSpeech, forKey: "translateOwnSpeech") } }
    /// Automatically suggest a reply when the other side asks a question.
    @Published var autoSuggestEnabled: Bool { didSet { defaults.set(autoSuggestEnabled, forKey: "autoSuggestEnabled") } }
    /// Simultaneous translation straight from audio (text appears while the other
    /// person is still speaking). Falls back to per-sentence translation if unavailable.
    @Published var syncTranslation: Bool { didSet { defaults.set(syncTranslation, forKey: "syncTranslation") } }
    /// Write meeting notes + a follow-up email draft when a session is stopped.
    @Published var autoSummary: Bool { didSet { defaults.set(autoSummary, forKey: "autoSummary") } }
    /// Goal checklist in the overlay: shown expanded (true) or as a one-line counter.
    @Published var goalsExpanded: Bool { didSet { defaults.set(goalsExpanded, forKey: "goalsExpanded") } }
    /// Folder that gets a Markdown note of every finished meeting (e.g. the inbox
    /// of an Obsidian vault). Empty = off.
    @Published var exportFolder: String { didSet { defaults.set(exportFolder, forKey: "exportFolder") } }
    /// Transcript layout: subtitles (two fixed zones, one per language) or the
    /// scrolling chat-like feed.
    @Published var captionMode: Bool { didSet { defaults.set(captionMode, forKey: "captionMode") } }
    /// Which language is shown larger. false = English large, Russian small.
    @Published var russianPrimary: Bool { didSet { defaults.set(russianPrimary, forKey: "russianPrimary") } }
    /// Overlay text size multiplier.
    @Published var fontScale: Double { didSet { defaults.set(fontScale, forKey: "fontScale") } }
    /// File name (without extension) of the active meeting profile.
    @Published var selectedProfileID: String { didSet { defaults.set(selectedProfileID, forKey: "selectedProfileID") } }
    /// Keep the overlay out of screen sharing / recordings.
    @Published var hideFromScreenShare: Bool { didSet { defaults.set(hideFromScreenShare, forKey: "hideFromScreenShare") } }
    /// The user has explicitly agreed that meeting audio is streamed to OpenAI.
    @Published var audioConsentGiven: Bool { didSet { defaults.set(audioConsentGiven, forKey: "audioConsentGiven") } }

    static let fontScaleRange: ClosedRange<Double> = 0.8...2.0

    init() {
        translationEnabled = defaults.object(forKey: "translationEnabled") as? Bool ?? true
        translateOwnSpeech = defaults.object(forKey: "translateOwnSpeech") as? Bool ?? false
        autoSuggestEnabled = defaults.object(forKey: "autoSuggestEnabled") as? Bool ?? true
        syncTranslation = defaults.object(forKey: "syncTranslation") as? Bool ?? true
        autoSummary = defaults.object(forKey: "autoSummary") as? Bool ?? true
        goalsExpanded = defaults.object(forKey: "goalsExpanded") as? Bool ?? true
        exportFolder = defaults.string(forKey: "exportFolder") ?? ""
        captionMode = defaults.object(forKey: "captionMode") as? Bool ?? true
        russianPrimary = defaults.object(forKey: "russianPrimary") as? Bool ?? false
        fontScale = defaults.object(forKey: "fontScale") as? Double ?? 1.0
        selectedProfileID = defaults.string(forKey: "selectedProfileID") ?? "General Business Meeting"
        hideFromScreenShare = defaults.object(forKey: "hideFromScreenShare") as? Bool ?? true
        audioConsentGiven = defaults.bool(forKey: "audioConsentGiven")
    }

    func bumpFontScale(by step: Double) {
        let next = (fontScale + step).rounded(toPlaces: 1)
        fontScale = min(max(next, Self.fontScaleRange.lowerBound), Self.fontScaleRange.upperBound)
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let m = pow(10.0, Double(places))
        return (self * m).rounded() / m
    }
}
