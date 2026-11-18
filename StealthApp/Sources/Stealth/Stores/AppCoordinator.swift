import Foundation
import Combine
import SwiftUI

/// Wires the pipeline together and exposes high-level app state to the UI.
///
/// Audio → text (OpenAI Realtime, one session per side):
///   • system audio → `systemRealtime` (speaker = Them)
///   • microphone   → `micRealtime`    (speaker = You)
/// Text → text (OpenAI text API, `TextLLMClient`):
///   • every finished line → Russian translation (streamed into the line)
///   • a detected question from Them, or the hotkey → a short English reply
///     suggestion grounded in the active meeting profile
@MainActor
final class AppCoordinator: ObservableObject {
    /// One overall connection indicator for the overlay.
    enum Connection: Equatable {
        case idle
        case connecting
        case live
        case reconnecting
        case failed
    }

    let transcript = TranscriptStore()
    let suggestion = SuggestionStore()
    let sessions = SessionStore()
    let hotkeys = HotkeyStore()
    let settings = AppSettings()
    let profiles = ProfileStore()
    let goals = GoalStore()
    /// Estimated OpenAI spend of the current (or just finished) session.
    @Published private(set) var cost = CostMeter()
    /// Accumulates between UI refreshes so audio chunks don't redraw the overlay.
    private var costLive = CostMeter()
    private var goalLoop: Task<Void, Never>?
    private var goalCheckTask: Task<Void, Never>?
    private var linesAtLastGoalCheck = 0
    private var cancellables: Set<AnyCancellable> = []

    let systemAudio = AudioCaptureManager()
    let mic = MicCaptureManager()

    let systemRealtime = RealtimeClient(speaker: .them)
    let micRealtime = RealtimeClient(speaker: .you)
    /// Simultaneous translation of the other side, straight from audio.
    let liveTranslator = LiveTranslationClient()
    /// True while simultaneous translation is on for the current session.
    @Published private(set) var syncActive = false
    private var pairer = TranslationPairer()
    /// Id of a saved session whose notes are being written right now.
    @Published private(set) var summarizingID: UUID?

    @Published var isRunning = false
    @Published var hasAPIKey: Bool = KeychainStore.exists()
    @Published var statusMessage: String = "Готов"
    @Published private(set) var connection: Connection = .idle

    /// Whether the user's mic is captured. Off = "Them" only (no speaker bleed
    /// being double-transcribed as "You"; also useful on speakerphone). Persists
    /// across sessions and can be toggled live while listening.
    @Published var micEnabled: Bool = UserDefaults.standard.object(forKey: "micEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(micEnabled, forKey: "micEnabled") }
    }

    @Published var tone: ReplyTone = .professional

    /// Identity + start time of the current listening session (for the saved record).
    private var sessionID = UUID()
    private var sessionStartedAt: Date?
    private var linesSinceAutosave = 0

    private var translationTasks: [UUID: Task<Void, Never>] = [:]
    private var suggestionTask: Task<Void, Never>?
    private var lastAutoSuggestAt = Date.distantPast
    private var deferredAutoSuggest: Task<Void, Never>?

    /// Set by the AppDelegate so Settings can rebind global hotkeys live.
    var onHotkeysChanged: (() -> Void)?
    /// Set by the AppDelegate: asks the user to allow streaming audio to OpenAI.
    /// Returns true if the user agreed.
    var requestAudioConsent: (() -> Bool)?

    /// Persist a new shortcut for a mode and re-register the global hotkeys.
    func updateHotkey(_ combo: HotkeyCombo, for mode: SuggestionMode) {
        hotkeys.set(combo, for: mode)
        onHotkeysChanged?()
    }

    func resetHotkey(_ mode: SuggestionMode) {
        hotkeys.reset(mode)
        onHotkeysChanged?()
    }

    init() {
        wire()
        // The checklist follows the selected profile (statuses reset on a switch).
        settings.$selectedProfileID
            .sink { [weak self] id in
                guard let self else { return }
                self.goals.load(fromMarkdown: self.profiles.markdown(for: id), resetStatuses: true)
                self.linesAtLastGoalCheck = 0
            }
            .store(in: &cancellables)
    }

    // MARK: - Goal checklist

    /// Re-read the goals from the profile file (it may have been edited).
    func reloadGoals(resetStatuses: Bool = false) {
        goals.load(fromMarkdown: profiles.markdown(for: settings.selectedProfileID), resetStatuses: resetStatuses)
    }

    private func startGoalLoop() {
        goalLoop?.cancel()
        goalLoop = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled, let self, self.isRunning else { return }
                self.cost = self.costLive            // refresh the cost readout every 5 s
                ticks += 1
                if Double(ticks) * 5 >= Config.goalCheckInterval {
                    ticks = 0
                    self.reloadGoals()
                    self.checkGoals()
                }
            }
        }
    }

    /// Ask the model which goals the conversation has reached. Skipped when
    /// nothing new was said, when every goal is ticked, or while a check runs.
    func checkGoals(force: Bool = false) {
        guard goalCheckTask == nil, !goals.goals.isEmpty else { return }
        let count = transcript.lines.count
        guard force || (goals.hasOpenGoals && count >= linesAtLastGoalCheck + 2) else { return }
        guard count > 0 else { return }
        linesAtLastGoalCheck = count
        let prompt = Config.goalCheckPrompt(goals: goals.promptSummary,
                                            transcript: transcript.tail(Config.goalCheckLines))
        goalCheckTask = Task { [weak self] in
            var answer = ""
            do {
                try await TextLLMClient.stream(
                    model: Config.model(.suggestion),
                    messages: [
                        .init(role: "system", content: Config.goalCheckInstructions),
                        .init(role: "user", content: prompt),
                    ],
                    maxTokens: 400
                ) { delta in answer += delta }
                self?.goals.apply(GoalParser.updates(fromModelOutput: answer))
            } catch {
                DebugLog.log("goal check failed: \(error.localizedDescription)")
            }
            self?.goalCheckTask = nil
        }
    }

    private func wire() {
        // System audio → "them" transcription session.
        systemAudio.onPCM16 = { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                let seconds = Double(data.count) / 2 / Config.realtimeSampleRate
                self.systemRealtime.sendAudio(data)
                if self.systemRealtime.state == .connected {
                    self.costLive.addAudio(model: self.systemRealtime.activeTranscriptionModel, seconds: seconds)
                }
                if self.syncActive {
                    self.liveTranslator.sendAudio(data)
                    if self.liveTranslator.isReady {
                        self.costLive.addAudio(model: Config.model(.liveTranslation), seconds: seconds)
                    }
                }
            }
        }
        TextLLMClient.onUsage = { [weak self] model, input, cached, output in
            self?.costLive.addText(model: model, inputTokens: input, cachedTokens: cached, outputTokens: output)
            // Text requests are rare — show them at once (also after Stop, for the summary).
            if let live = self?.costLive { self?.cost = live }
        }

        // Simultaneous translation → attach each finished sentence to its English line.
        liveTranslator.onSegment = { [weak self] text in
            guard let self else { return }
            self.transcript.appendTranslatedSentence(text)
            guard let hit = self.pairer.translationArrived(text) else { return }
            self.transcript.addTranslatedSentence(hit.text, to: hit.lineID)
        }
        liveTranslator.onPartial = { [weak self] text in
            self?.transcript.partialTranslation = text
        }
        liveTranslator.onUnavailable = { [weak self] reason in
            guard let self, self.syncActive else { return }
            // Go back to translating finished sentences through the text API,
            // including the last few lines that were still waiting.
            self.syncActive = false
            self.pairer.reset()
            self.transcript.partialTranslation = ""
            self.statusMessage = "Синхронный перевод недоступен — перевожу по предложениям"
            for line in self.transcript.lines.suffix(3) where line.speaker == .them && line.translation.isEmpty {
                self.translate(line)
            }
        }
        // Microphone → "you" transcription session.
        mic.onPCM16 = { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                self.micRealtime.sendAudio(data)
                if self.micRealtime.state == .connected {
                    self.costLive.addAudio(model: self.micRealtime.activeTranscriptionModel,
                                           seconds: Double(data.count) / 2 / Config.realtimeSampleRate)
                }
            }
        }

        for client in [systemRealtime, micRealtime] {
            client.onTranscriptDelta = { [weak self] delta, speaker in
                self?.transcript.appendDelta(delta, speaker: speaker)
            }
            client.onPartialReplaced = { [weak self] text, speaker in
                self?.transcript.setPartial(text, speaker: speaker)
            }
            client.onTranscriptCompleted = { [weak self] line, speaker in
                self?.handleCompletedLine(line, speaker: speaker)
            }
            client.onError = { [weak self] message in
                self?.statusMessage = "Ошибка: \(message)"
            }
            client.onStateChange = { [weak self] in
                self?.refreshConnection()
            }
        }
    }

    // MARK: - Transcript → translation / auto-suggestion

    private func handleCompletedLine(_ text: String, speaker: Speaker) {
        // Commit the authoritative final line and DROP the streamed partial
        // (committing the partial too would duplicate the line).
        transcript.clearPartial(speaker)
        guard let line = transcript.commit(text, speaker: speaker) else { return }

        if settings.translationEnabled {
            if speaker == .them, syncActive {
                // The simultaneous stream supplies the Russian text for this line.
                for hit in pairer.lineCommitted(line.id) {
                    transcript.addTranslatedSentence(hit.text, to: hit.lineID)
                }
            } else if speaker == .them || settings.translateOwnSpeech {
                translate(line)
            }
        }
        if speaker == .them, settings.autoSuggestEnabled, QuestionDetector.isQuestion(line.content) {
            autoSuggest()
        }

        linesSinceAutosave += 1
        if linesSinceAutosave >= Config.autosaveEveryLines { saveSession() }
    }

    private func translate(_ line: TranscriptLine) {
        // Already Russian (e.g. a Russian aside) — nothing to translate.
        guard !Self.isMostlyCyrillic(line.content) else { return }
        let context = transcript.contextBefore(line.id)
        let id = line.id
        translationTasks[id] = Task { [weak self] in
            do {
                try await TextLLMClient.stream(
                    model: Config.model(.translation),
                    messages: [
                        .init(role: "system", content: Config.translationInstructions),
                        .init(role: "user", content: Config.translationPrompt(line: line.content, context: context)),
                    ],
                    maxTokens: 400
                ) { delta in
                    self?.transcript.appendTranslation(delta, to: id)
                }
            } catch {
                // Cancellation surfaces as CancellationError or URLError(.cancelled).
                guard !Task.isCancelled else { self?.translationTasks[id] = nil; return }
                DebugLog.log("translation failed: \(error.localizedDescription)")
                if let self, self.isRunning { self.statusMessage = "Перевод: \(error.localizedDescription)" }
            }
            self?.translationTasks[id] = nil
        }
    }

    static func isMostlyCyrillic(_ text: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let cyrillic = letters.filter { (0x0400...0x04FF).contains($0.value) }.count
        return cyrillic * 2 > letters.count
    }

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning else { return }
        hasAPIKey = KeychainStore.exists()
        guard hasAPIKey else {
            statusMessage = "Нет API-ключа — откройте Настройки."
            return
        }
        // Read the key now, once. If macOS asks for access to it, this is where
        // the prompt appears — in response to pressing Start, not at launch.
        guard KeychainStore.load() != nil else {
            statusMessage = "Нет доступа к ключу в Связке ключей. Нажмите «Старт» ещё раз и выберите «Разрешать всегда»."
            return
        }
        // Audio leaves this Mac only after an explicit, one-time opt-in.
        if !settings.audioConsentGiven {
            guard requestAudioConsent?() == true else {
                statusMessage = "Отменено: передача аудио не разрешена."
                return
            }
            settings.audioConsentGiven = true
        }

        // A new session replaces whatever the overlay still shows from the last one.
        transcript.clear()
        suggestion.reset()
        sessionID = UUID()
        sessionStartedAt = Date()
        linesSinceAutosave = 0
        profiles.reload()
        reloadGoals(resetStatuses: true)
        linesAtLastGoalCheck = 0
        costLive = CostMeter()
        cost = costLive

        statusMessage = "Подключение…"
        pairer.reset()
        syncActive = settings.translationEnabled && settings.syncTranslation
        if syncActive { liveTranslator.connect() }
        systemRealtime.connect()
        if micEnabled { micRealtime.connect() }

        await systemAudio.start()
        if let err = systemAudio.lastError {
            liveTranslator.disconnect()
            syncActive = false
            systemRealtime.disconnect()
            micRealtime.disconnect()
            sessionStartedAt = nil
            statusMessage = err
            refreshConnection()
            return
        }
        if micEnabled {
            mic.start()   // mic failure is non-fatal — system audio still works
        }

        isRunning = true
        refreshConnection()
        startGoalLoop()
    }

    /// Turn the user's mic on/off, live if a session is running. Disconnecting the
    /// "You" realtime session when muted avoids an idle socket and stray state.
    func toggleMic() {
        micEnabled.toggle()
        guard isRunning else { return }
        if micEnabled {
            micRealtime.connect()
            mic.start()
        } else {
            mic.stop()
            micRealtime.disconnect()
            transcript.clearPartial(.you)
        }
        refreshConnection()
    }

    func stop() async {
        guard isRunning else { return }
        await systemAudio.stop()
        mic.stop()
        systemRealtime.disconnect()
        micRealtime.disconnect()
        liveTranslator.disconnect()   // flushes the last translated sentence
        syncActive = false
        isRunning = false
        suggestionTask?.cancel()
        deferredAutoSuggest?.cancel()
        goalLoop?.cancel()
        checkGoals(force: true)   // final assessment of the whole call

        // Give in-flight translations a moment to finish so the saved transcript
        // is complete, then archive. The overlay keeps showing the transcript
        // until the next Start.
        let pending = Array(translationTasks.values)
        if !pending.isEmpty {
            let timeout = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if !Task.isCancelled { pending.forEach { $0.cancel() } }
            }
            for task in pending { await task.value }
            timeout.cancel()
        }
        translationTasks = [:]
        transcript.clearPartial(.them)
        transcript.clearPartial(.you)

        transcript.partialTranslation = ""
        let saved = saveSession()
        sessionStartedAt = nil
        refreshConnection()
        statusMessage = saved != nil ? "Сохранено в Историю" : "Остановлено"
        if let saved {
            exportNote(saved)
            if !settings.exportFolder.isEmpty { statusMessage = "Сохранено в Историю и в папку заметок" }
        }
        if let saved, settings.autoSummary, saved.lineCount >= Config.summaryMinLines {
            summarize(saved)
        }
    }

    func toggle() async {
        if isRunning { await stop() } else { await start() }
    }

    @discardableResult
    private func saveSession() -> SessionRecord? {
        guard let startedAt = sessionStartedAt else { return nil }
        linesSinceAutosave = 0
        cost = costLive
        return sessions.save(
            id: sessionID,
            lines: transcript.lines,
            startedAt: startedAt,
            profile: profiles.profile(id: settings.selectedProfileID)?.title,
            costUSD: costLive.totalUSD
        )
    }

    /// The record of the session currently shown in the overlay (live or just finished).
    var currentSessionRecord: SessionRecord? {
        sessions.sessions.first { $0.id == sessionID }
    }

    // MARK: - Connection status

    private func refreshConnection() {
        guard isRunning else {
            if case .failed = systemRealtime.state { connection = .failed } else { connection = .idle }
            return
        }
        let states = micEnabled ? [systemRealtime.state, micRealtime.state] : [systemRealtime.state]
        if states.contains(where: { if case .failed = $0 { return true } else { return false } }) {
            connection = .failed
        } else if states.contains(.reconnecting) {
            connection = .reconnecting
            statusMessage = "Переподключение…"
        } else if states.allSatisfy({ $0 == .connected }) {
            connection = .live
            statusMessage = mic.isCapturing ? "Слушаю: вы + собеседник" : "Слушаю: только собеседник"
        } else {
            connection = .connecting
        }
    }

    // MARK: - Copy to the notes folder

    /// Write the meeting as a Markdown note into the folder chosen in Settings.
    /// Called on Stop and again when the summary is ready (same file).
    private func exportNote(_ record: SessionRecord) {
        let path = settings.exportFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        do {
            let url = try NoteExporter.write(record, to: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
            DebugLog.log("note exported: \(url.lastPathComponent)")
        } catch {
            DebugLog.log("note export failed: \(error.localizedDescription)")
            statusMessage = "Не удалось записать заметку в папку: \(error.localizedDescription)"
        }
    }

    // MARK: - After-meeting notes

    /// Write meeting notes + a follow-up email draft for a saved session and
    /// store them with it (History shows them; export includes them).
    func summarize(_ record: SessionRecord) {
        guard summarizingID == nil else { return }
        summarizingID = record.id
        statusMessage = "Пишу резюме встречи…"
        let context = profiles.context(for: settings.selectedProfileID)
        // Goal statuses belong to the session that just ended, not to old ones from History.
        let goalsNote = record.id == sessionID && !goals.goals.isEmpty
            ? "Meeting goals and where they ended up (mention unreached ones under «Открытые вопросы»):\n\(goals.promptSummary)\n\n"
            : ""
        Task { [weak self] in
            var text = ""
            do {
                try await TextLLMClient.stream(
                    model: Config.model(.suggestion),
                    messages: [
                        .init(role: "system", content: Config.summaryInstructions(meetingContext: context)),
                        .init(role: "user", content: "Transcript:\n---\n\(record.transcriptForSummary)\n---\n\(goalsNote)Write the notes."),
                    ],
                    maxTokens: 1_500
                ) { delta in text += delta }
                let notes = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if notes.isEmpty {
                    self?.statusMessage = "Резюме не получилось: пустой ответ модели"
                } else {
                    // The summary request itself is part of this session's cost.
                    let total = record.id == self?.sessionID ? self?.costLive.totalUSD : nil
                    self?.sessions.setSummary(notes, for: record.id, costUSD: total)
                    self?.statusMessage = "Резюме готово — откройте Историю"
                    if let updated = self?.sessions.sessions.first(where: { $0.id == record.id }) {
                        self?.exportNote(updated)
                    }
                }
            } catch {
                DebugLog.log("summary failed: \(error.localizedDescription)")
                self?.statusMessage = "Резюме не получилось: \(error.localizedDescription)"
            }
            self?.summarizingID = nil
        }
    }

    // MARK: - Suggestions

    /// A question was detected. Fire now, or — inside the cool-down after the
    /// previous automatic suggestion — once when the cool-down ends, so a
    /// multi-sentence question produces one suggestion, not one per sentence.
    private func autoSuggest() {
        deferredAutoSuggest?.cancel()
        let wait = Config.autoSuggestCooldown - Date().timeIntervalSince(lastAutoSuggestAt)
        guard wait > 0 else {
            requestSuggestion(mode: .reply, auto: true)
            return
        }
        deferredAutoSuggest = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isRunning else { return }
            self.requestSuggestion(mode: .reply, auto: true)
        }
    }

    /// Triggered by a detected question (`auto`), a global hotkey, or an overlay
    /// button. `mode` selects reply, recap, or follow-up; all render into the same
    /// suggestion card. A newer request replaces an in-flight one.
    func requestSuggestion(mode: SuggestionMode = .reply, auto: Bool = false) {
        guard isRunning || !transcript.lines.isEmpty else {
            statusMessage = "Сначала нажмите Старт."
            return
        }
        suggestionTask?.cancel()
        deferredAutoSuggest?.cancel()
        // A manual request also starts the cool-down, so an automatic one does
        // not replace it a second later.
        lastAutoSuggestAt = Date()
        suggestion.begin(mode: mode, auto: auto)

        let context = profiles.context(for: settings.selectedProfileID)
        let messages: [TextLLMClient.Message] = [
            .init(role: "system",
                  content: Config.suggestionInstructions(mode: mode, tone: tone, meetingContext: context)),
            .init(role: "user",
                  content: Config.suggestionPrompt(transcript: transcript.recentContext(), mode: mode,
                                                   goals: mode == .recap ? "" : goals.promptSummary)),
        ]
        suggestionTask = Task { [weak self] in
            do {
                try await TextLLMClient.stream(
                    model: Config.model(.suggestion),
                    messages: messages,
                    maxTokens: mode == .recap ? 500 : 200
                ) { delta in
                    guard !Task.isCancelled else { return }
                    self?.suggestion.appendDelta(delta)
                }
                guard !Task.isCancelled else { return }
                self?.suggestion.finish()
                // Show what the English suggestion means (recap is already Russian).
                if mode != .recap, let self, self.settings.translationEnabled, !self.suggestion.reply.isEmpty {
                    try await TextLLMClient.stream(
                        model: Config.model(.translation),
                        messages: [
                            .init(role: "system", content: Config.translationInstructions),
                            .init(role: "user", content: Config.translationPrompt(line: self.suggestion.reply, context: [])),
                        ],
                        maxTokens: 300
                    ) { delta in
                        guard !Task.isCancelled else { return }
                        self.suggestion.appendTranslation(delta)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                DebugLog.log("suggestion failed: \(error.localizedDescription)")
                // A failed gloss must not wipe a suggestion that already arrived.
                if self?.suggestion.isLoading == true { self?.suggestion.fail(error.localizedDescription) }
            }
        }
    }

    // MARK: - Demo hooks (used only by DemoMode; no network, no audio)

    /// Make the overlay look like a live session without starting one.
    func demoSetLive(_ on: Bool) {
        isRunning = on
        connection = on ? .live : .idle
    }

    func demoAddCost(minutes: Double) {
        costLive.addAudio(model: Config.ModelKey.transcription.defaultValue, seconds: minutes * 60)
        costLive.addAudio(model: Config.ModelKey.liveTranslation.defaultValue, seconds: minutes * 60)
        cost = costLive
    }

    func refreshKeyState() {
        hasAPIKey = KeychainStore.exists()
    }
}
