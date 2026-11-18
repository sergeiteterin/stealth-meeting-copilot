import Foundation

/// Central tuning knobs for the meeting copilot.
/// Kept in one place so the audio → realtime → translation/suggestion pipeline is easy to reason about.
/// Foundation-only on purpose: this file is also compiled into the unit-test bundle.
enum Config {
    // MARK: - Models (overridable in Settings → stored in UserDefaults)

    /// UserDefaults keys for user-overridable model names. OpenAI retires models on
    /// a schedule (e.g. `gpt-4o-transcribe` is announced for shutdown in Feb 2027),
    /// so none of these are hard-wired.
    enum ModelKey: String, CaseIterable {
        case realtime = "model.realtime"
        case transcription = "model.transcription"
        case translation = "model.translation"
        case suggestion = "model.suggestion"
        case liveTranslation = "model.liveTranslation"

        var defaultValue: String {
            switch self {
            case .realtime: return "gpt-realtime"
            case .transcription: return "gpt-live-transcribe"
            case .translation: return "gpt-4.1-mini"
            case .suggestion: return "gpt-4.1-mini"
            case .liveTranslation: return "gpt-realtime-translate"
            }
        }

        var label: String {
            switch self {
            case .realtime: return "Realtime-сессия"
            case .transcription: return "Распознавание речи"
            case .translation: return "Перевод"
            case .suggestion: return "Подсказки и резюме"
            case .liveTranslation: return "Синхронный перевод"
            }
        }
    }

    static func model(_ key: ModelKey) -> String {
        let stored = UserDefaults.standard.string(forKey: key.rawValue)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? key.defaultValue : stored
    }

    /// Transcription model used when the streaming one is rejected by the API
    /// (no access, renamed, schema change). Phrase-by-phrase, but proven.
    static let fallbackTranscriptionModel = "gpt-4o-transcribe"

    /// Streaming models (`gpt-live-*`) return transcript text while the person is
    /// still speaking; the older ones only after a pause. They use a different
    /// session type and do no server-side turn detection.
    static func isStreamingTranscription(_ model: String) -> Bool {
        model.lowercased().hasPrefix("gpt-live")
    }

    /// Dedicated transcription endpoint for streaming models (no model in the URL).
    static let transcriptionURL = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!

    /// Latency setting for streaming transcription ("minimal", "low", "medium", …).
    /// Lower = text appears sooner, slightly less accurate.
    static let streamingDelay = "low"

    /// Client-side speech level (PCM16 RMS) that counts as speech in streaming mode.
    static func speechRMSThreshold(for speaker: Speaker) -> Double {
        switch speaker {
        case .you: return 500
        case .them: return 250
        }
    }

    /// OpenAI Realtime API websocket endpoint (GA — no `OpenAI-Beta` header).
    static var realtimeURL: URL {
        let model = model(.realtime).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ModelKey.realtime.defaultValue
        return URL(string: "wss://api.openai.com/v1/realtime?model=\(model)")!
    }

    /// Simultaneous speech translation endpoint (audio in → translated text out).
    static var liveTranslationURL: URL {
        let model = model(.liveTranslation).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ModelKey.liveTranslation.defaultValue
        return URL(string: "wss://api.openai.com/v1/realtime/translations?model=\(model)")!
    }

    /// Target language of the translation.
    static let translationTargetLanguage = "ru"

    /// Minimum gap between two AUTOMATIC reply suggestions. A question inside the
    /// gap is not dropped: one suggestion fires when the gap ends, using the
    /// latest transcript. The hotkey ignores the gap.
    static let autoSuggestCooldown: TimeInterval = 8

    /// How often the goal checklist is re-assessed during a call (only when new
    /// lines have arrived since the last check).
    static let goalCheckInterval: TimeInterval = 25
    /// Transcript lines given to the goal check (statuses only move forward, so
    /// a recent window is enough).
    static let goalCheckLines = 40

    /// System prompt for assessing the goal checklist.
    static let goalCheckInstructions = """
    You track the goals of a live business meeting for one participant ("You:"). \
    You get the list of goals with their current status and the recent transcript \
    ("Them:" = the other side). The transcript comes from speech recognition.

    For EVERY goal output exactly one line:
    <number>|<status>|<note>
    - status is one of: open, progress, done
      • done — clearly achieved in the transcript: the other side agreed, committed, \
    or gave the information the goal asks for. A name, a date or an explicit "yes" \
    is typical evidence. Be conservative: when in doubt it is NOT done.
      • progress — the topic of the goal is being discussed, but nothing is agreed yet.
      • open — not touched.
    - A goal already marked ACHIEVED stays done.
    - note — in Russian, at most 8 words: the evidence (who, what, when) or what is \
    still missing. Use only what was said; never invent names or dates.
    Output only these lines, nothing else.
    """

    static func goalCheckPrompt(goals: String, transcript: String) -> String {
        """
        Goals:
        \(goals)

        Recent transcript (most recent line last):
        ---
        \(transcript)
        ---
        """
    }

    /// A meeting shorter than this many lines gets no automatic summary.
    static let summaryMinLines = 6

    /// OpenAI text endpoint used for translation and reply suggestions (SSE streaming).
    static let chatCompletionsURL = URL(string: "https://api.openai.com/v1/chat/completions")!

    // MARK: - Audio / transcript

    /// Sample rate the Realtime API expects for input audio (PCM16, mono, little-endian).
    static let realtimeSampleRate: Double = 24_000

    /// Rolling transcript window (seconds) sent as context when requesting a suggestion.
    /// Smaller = faster + cheaper + more relevant to the current moment.
    static let suggestionContextWindow: TimeInterval = 90

    /// Max transcript lines kept in memory for the saved session (an hour-long call
    /// is typically well under 2 000 lines).
    static let transcriptLineLimit = 5_000

    /// How many of the most recent lines the overlay actually renders.
    static let overlayVisibleLines = 60

    /// The session JSON is re-saved every N committed lines, so a crash or a forced
    /// quit mid-call loses at most a few lines.
    static let autosaveEveryLines = 5

    /// Meeting-context Markdown is truncated to this many characters before being
    /// sent with a suggestion request (keeps latency and cost bounded).
    static let profileContextCharLimit = 24_000

    /// Apple voice processing (acoustic echo cancellation + noise suppression) on the
    /// mic. It stops speaker bleed being mislabeled "You", BUT can over-suppress the
    /// user's own voice on some setups → the "You" side captures only silence and VAD
    /// never fires. Turn OFF to test/restore mic sensitivity (echo handling then leans
    /// on the higher `vadThreshold(.you)` instead).
    static let micEchoCancellation = false

    /// VAD silence threshold (ms) before a turn is committed → transcribed.
    /// Lower = snappier transcript, BUT too low fragments continuous speech: natural
    /// speech has frequent sub-second pauses between words, so at 200ms the VAD
    /// commits mid-sentence and words get clipped/dropped at the fragment boundaries
    /// (observed on YouTube/system audio). 700ms waits for a real sentence-ending
    /// pause, keeping lines whole at the cost of a slightly later commit.
    static let vadSilenceMs = 700

    /// VAD speech-detection sensitivity, per speaker (0…1, lower = more sensitive).
    ///
    /// Values MUST be exactly representable in binary floating point, because
    /// `JSONSerialization` prints e.g. 0.3 as "0.29999999999999999" (17 decimal
    /// places) and the Realtime API rejects >16 dp. 0.25 and 0.5 are safe; 0.3 / 0.4
    /// are NOT. Stick to multiples of 0.25 / 0.5 when tuning these.
    static func vadThreshold(for speaker: Speaker) -> Double {
        switch speaker {
        case .you: return 0.25
        case .them: return 0.5
        }
    }

    /// Reconnect back-off (seconds) after an unexpected Realtime socket drop
    /// (network blip, or the server-side session duration cap on long calls).
    static func reconnectDelay(attempt: Int) -> TimeInterval {
        min(15, pow(2, Double(max(0, attempt - 1))))
    }

    /// Keychain identifiers for the OpenAI API key.
    static let keychainService = "com.stealth.app"
    static let keychainAccount = "openai-api-key"

    // MARK: - Prompts

    /// System prompt for live EN → RU translation of one transcript line.
    static let translationInstructions = """
    You are a simultaneous interpreter in a live business meeting. Translate the \
    English line marked "Translate:" into natural, concise Russian.
    Rules:
    - Output ONLY the Russian translation. No quotes, no notes, no transliteration.
    - Keep product names, company names, abbreviations and units in their original form \
    (Kubernetes, UPS, PUE, kW).
    - The line comes from speech recognition: silently fix obvious recognition errors \
    using the earlier lines as context, but never add information.
    - If the line is filler or a fragment, translate it as is, briefly.
    """

    /// User message for a translation request: a little preceding context plus the line.
    static func translationPrompt(line: String, context: [String]) -> String {
        guard !context.isEmpty else { return "Translate:\n\(line)" }
        return """
        Earlier lines (context only, do NOT translate):
        \(context.joined(separator: "\n"))

        Translate:
        \(line)
        """
    }

    /// Shared preamble: who the assistant is and who the user is.
    private static let copilotPreamble = """
    You are a silent meeting copilot for a Russian-speaking professional on a live \
    business call held in English. You are given a rolling transcript of the call, \
    speaker-labelled ("Them:" = the other people, "You:" = the user). The transcript \
    comes from speech recognition and may contain small errors.
    """

    /// Hard honesty rules shared by every mode that puts words in the user's mouth.
    private static let honestyRules = """
    - Use ONLY facts found in the meeting context below or in the transcript. NEVER \
    invent facts, numbers, prices, dates, names, capabilities or commitments.
    - Never promise anything on the user's behalf (deadlines, budgets, deliveries, decisions).
    - If answering needs a fact you do not have, give a short honest holding answer \
    instead (for example: say you will check and come back with exact details) and, \
    if useful, ask one clarifying question.
    - Ignore placeholder lines in the context such as "TODO" or "<fill in>".
    """

    /// How a suggested line should move the conversation toward the user's goals.
    /// Only well-established negotiation and rapport practice — and explicitly
    /// no pressure or deception: a suggestion the user would be embarrassed to
    /// have explained to the other side is a bad suggestion.
    private static let goalSteering = """
    GOALS. The meeting context may contain a "Meeting goals" section. Read the \
    transcript and work out which goals are already achieved and which are still open.
    - First, do what the moment requires (answer the question, acknowledge the point).
    - Then, if it fits naturally and length allows, add ONE short move that advances \
    ONE still-open goal. Pick the move that fits the moment:
      • acknowledge or label their concern before answering ("It sounds like timing is the main risk for you");
      • reuse their own key words, so they feel heard;
      • ask a calibrated open question starting with "what" or "how" instead of yes/no;
      • summarise what you both agree on, then propose the next step;
      • make the next step small, concrete and easy to accept (a named person, a date, one pilot);
      • offer two acceptable options instead of an open request;
      • frame the benefit for THEM, not for us.
    - If they resist or hesitate: do not push. Acknowledge, ask what would make it workable.
    - Never manipulate: no false urgency, no flattery, no pressure, no bluffing, \
    no claims you cannot support. Stay honest and respectful.
    - If every goal is achieved or none fits this moment, just answer well.
    """

    /// Second output line that tells the user what the suggestion is doing.
    private static let noteFormat = """
    OUTPUT FORMAT: line 1 — the text to say, nothing else. Then a new line starting \
    with "#" and a note in Russian of at most 8 words: which goal this advances and \
    the move used (for example "# цель: рабочий контакт · открытый вопрос"). If the \
    line advances no goal, write "# просто ответ". Never mention the note in line 1.
    """

    /// System prompt for a given suggestion mode, with the active meeting profile
    /// appended as context. Static instructions come first and the (stable) profile
    /// second, so OpenAI's automatic prompt caching can reuse the prefix across calls.
    static func suggestionInstructions(mode: SuggestionMode, tone: ReplyTone, meetingContext: String) -> String {
        let task: String
        switch mode {
        case .reply:
            task = """
            The most recent "Them:" line(s) are what the user needs to respond to.

            Produce ONE suggested reply the user can say out loud in English.
            - 1–2 short sentences, at most ~35 words.
            - CEFR B1–B2 English: common words, simple grammar, easy to pronounce. \
            No idioms, no rare words. Tone: \(tone.descriptor).
            - Answer the actual question directly; use the correct terms from the meeting context.
            \(honestyRules)
            - No quotes, no preamble, no explanation.
            - If the latest line is not a question, suggest a natural short acknowledgement or follow-up.

            \(goalSteering)

            \(noteFormat)
            """
        case .recap:
            task = """
            Summarise the conversation so far so the user can catch up quickly.
            - Write in Russian. 2–4 short bullet points (use "• " for each).
            - Capture key decisions, questions raised, and anything the user was asked to do.
            - Keep names, product names and numbers exactly as spoken.
            - No preamble, no heading. Output only the bullets.
            """
        case .followUp:
            task = """
            Suggest ONE relevant follow-up question the user could ask next to keep \
            the conversation moving or to clarify something important.
            - A single question in CEFR B1–B2 English, \(tone.descriptor), easy to say.
            \(honestyRules)
            - Prefer the question that best advances a still-open meeting goal.
            - No quotes, no preamble.

            \(goalSteering)

            \(noteFormat)
            """
        }

        let context = meetingContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextBlock = context.isEmpty
            ? "(no meeting context provided)"
            : String(context.prefix(profileContextCharLimit))

        return """
        \(copilotPreamble)

        \(task)

        === MEETING CONTEXT (background facts; may be partly in Russian) ===
        \(contextBlock)
        === END OF MEETING CONTEXT ===
        """
    }

    /// System prompt for the after-meeting summary.
    static func summaryInstructions(meetingContext: String) -> String {
        let context = meetingContext.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You write the after-meeting notes for a Russian-speaking professional who just \
        finished a business call held in English. You get the full transcript \
        ("Them:" = the other side, "You:" = the user). It comes from speech recognition \
        and may contain small errors.

        Write the notes in Russian, in Markdown, with exactly these sections:
        ## Итоги
        3–6 bullets: what was discussed and what became clear.
        ## Договорённости
        Decisions and commitments, each with who made it. If none: "Не зафиксировано".
        ## Задачи
        Action items as "- [ ] кто — что — срок (если назван)". Only tasks actually mentioned.
        ## Открытые вопросы
        What was asked but not answered, or left to follow up.
        ## Письмо после встречи
        A short follow-up email in ENGLISH (CEFR B2, polite, under 150 words) that thanks \
        them, lists the agreed next steps, and asks for anything still open.

        Rules:
        - Use ONLY what is in the transcript. Never add facts, numbers, names, dates or \
        commitments that were not said. Keep names, product names and numbers exactly as spoken.
        - The meeting context below is background for understanding terms and spelling \
        names correctly — do not copy facts from it into the notes.
        - If the transcript is too short or unclear for a section, say so in that section.

        === MEETING CONTEXT ===
        \(context.isEmpty ? "(none)" : String(context.prefix(profileContextCharLimit)))
        === END OF MEETING CONTEXT ===
        """
    }

    /// User message for a suggestion request.
    static func suggestionPrompt(transcript: String, mode: SuggestionMode, goals: String = "") -> String {
        let goalBlock = goals.isEmpty ? "" : """

        Meeting goals and their status right now (advance an OPEN or IN PROGRESS one; leave ACHIEVED ones alone):
        \(goals)

        """
        let task: String
        switch mode {
        case .reply: task = "Suggest my spoken reply now."
        case .recap: task = "Recap the conversation so far."
        case .followUp: task = "Suggest one follow-up question I could ask."
        }
        return """
        Recent transcript of the call (most recent line last):
        ---
        \(transcript.isEmpty ? "(no speech captured yet)" : transcript)
        ---
        \(goalBlock)\(task)
        """
    }
}

/// What kind of on-demand assistance the user is asking for.
enum SuggestionMode: String, CaseIterable, Identifiable {
    case reply
    case recap
    case followUp

    var id: String { rawValue }

    /// Short label for the overlay card header.
    var label: String {
        switch self {
        case .reply: return "Ответ"
        case .recap: return "Резюме"
        case .followUp: return "Вопрос"
        }
    }

    /// SF Symbol for the overlay button.
    var systemImage: String {
        switch self {
        case .reply: return "bubble.left.and.bubble.right"
        case .recap: return "list.bullet.rectangle"
        case .followUp: return "questionmark.bubble"
        }
    }
}

enum ReplyTone: String, CaseIterable, Identifiable {
    case professional
    case casual

    var id: String { rawValue }

    var descriptor: String {
        switch self {
        case .professional: return "polite, professional"
        case .casual: return "friendly, casual"
        }
    }

    var label: String {
        switch self {
        case .professional: return "Деловой"
        case .casual: return "Неформальный"
        }
    }
}
