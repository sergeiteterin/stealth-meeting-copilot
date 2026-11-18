import XCTest

final class QuestionDetectorTests: XCTestCase {
    func testDetectsQuestions() {
        let questions = [
            "What is your timeline for the pilot?",
            "Could you tell us more about your data center project",
            "So, how many cameras do you have on site",
            "Okay, and what rack densities are you planning for",
            "Tell me about your company.",
            "We ship in Q3. Does that work on your side",
            "I was wondering if you already have a design partner",
            "You are based in Lisbon, right",
            "Thanks for that. Can you walk me through the current setup",
        ]
        for q in questions { XCTAssertTrue(QuestionDetector.isQuestion(q), q) }
    }

    func testIgnoresStatements() {
        let statements = [
            "Thank you.",
            "What?",
            "We have been working on liquid cooling for several years.",
            "The whole team is here today.",
            "Whatever works best for the schedule is fine.",
            "Howard will send the slides after the call.",
            "That sounds good, let's move on.",
            "",
        ]
        for s in statements { XCTAssertFalse(QuestionDetector.isQuestion(s), s) }
    }
}

final class SSEParserTests: XCTestCase {
    func testParsesDelta() {
        let line = #"data: {"id":"x","choices":[{"index":0,"delta":{"content":"Привет"}}]}"#
        XCTAssertEqual(SSEParser.parse(line: line), .delta("Привет"))
    }

    func testDoneAndNoise() {
        XCTAssertEqual(SSEParser.parse(line: "data: [DONE]"), .done)
        XCTAssertNil(SSEParser.parse(line: ""))
        XCTAssertNil(SSEParser.parse(line: ": keep-alive"))
        XCTAssertNil(SSEParser.parse(line: #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#))
        XCTAssertNil(SSEParser.parse(line: #"data: {"choices":[],"usage":null}"#))
        XCTAssertNil(SSEParser.parse(line: "data: {broken"))
    }

    func testErrorMessage() {
        let body = Data(#"{"error":{"message":"Incorrect API key","code":"invalid_api_key"}}"#.utf8)
        XCTAssertEqual(SSEParser.errorMessage(fromBody: body, status: 401), "OpenAI 401: Incorrect API key")
        XCTAssertEqual(SSEParser.errorMessage(fromBody: Data(), status: 500), "OpenAI HTTP 500")
    }
}

@MainActor
final class TranscriptStoreTests: XCTestCase {
    func testCommitTranslationAndContext() {
        let store = TranscriptStore()
        XCTAssertNil(store.commit("   ", speaker: .them))
        let a = store.commit("Hello everyone.", speaker: .them)!
        let b = store.commit("Hi, nice to meet you.", speaker: .you)!
        store.appendTranslation("Всем ", to: a.id)
        store.appendTranslation("привет.", to: a.id)
        XCTAssertEqual(store.lines[0].translation, "Всем привет.")
        XCTAssertEqual(store.lines[1].translation, "")
        XCTAssertEqual(store.contextBefore(b.id), ["Them: Hello everyone."])
        XCTAssertEqual(store.contextBefore(a.id), [])
        XCTAssertEqual(store.recentContext(), "Them: Hello everyone.\nYou: Hi, nice to meet you.")
    }

    func testMarkdownExportAndLegacyDecode() throws {
        let store = TranscriptStore()
        let a = store.commit("What is your timeline?", speaker: .them)!
        store.appendTranslation("Какие у вас сроки?", to: a.id)
        store.commit("About six months.", speaker: .you)
        let record = SessionRecord(startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 120),
                                   lines: store.lines.map(SessionLine.init(from:)), profile: "Data Center Project")
        let md = record.markdown
        XCTAssertTrue(md.contains("Профиль: Data Center Project"))
        XCTAssertTrue(md.contains("What is your timeline?"))
        XCTAssertTrue(md.contains("> Какие у вас сроки?"))
        XCTAssertTrue(md.contains("About six months."))
        XCTAssertTrue(record.suggestedFileName.hasSuffix("-meeting.md"))

        // Sessions saved by the original app have no `translation` / `profile` keys.
        let legacy = """
        {"id":"\(UUID().uuidString)","startedAt":"2026-06-30T10:00:00Z","endedAt":"2026-06-30T10:05:00Z",
         "lines":[{"id":"\(UUID().uuidString)","speaker":"Them","at":"2026-06-30T10:00:01Z","content":"Hi"}]}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SessionRecord.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.lines.first?.content, "Hi")
        XCTAssertNil(decoded.lines.first?.translation)
        XCTAssertNil(decoded.profile)
    }
}

@MainActor
final class ProfileStoreTests: XCTestCase {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("stealth-tests-\(UUID().uuidString)")
    }

    func testTitleAndComments() {
        XCTAssertEqual(MeetingProfile.title(fromMarkdown: "\n# Technology Partner Meeting\n\n## Company", fallback: "f"), "Technology Partner Meeting")
        XCTAssertEqual(MeetingProfile.title(fromMarkdown: "## Only h2", fallback: "file"), "file")
        XCTAssertEqual(MeetingProfile.stripComments("# T\n<!-- hint\nmore -->\n- fact <!-- x -->end"), "# T\n\n- fact end")
    }

    func testSeedsOnceAndReadsLive() throws {
        let fm = FileManager.default
        let seed = tempDir(), dir = tempDir()
        try fm.createDirectory(at: seed, withIntermediateDirectories: true)
        try "# Alpha\n- fact one".write(to: seed.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "# Beta".write(to: seed.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: seed); try? fm.removeItem(at: dir) }

        let store = ProfileStore(directory: dir, seedDirectory: seed)
        XCTAssertEqual(store.profiles.map(\.title), ["Alpha", "Beta"])

        // Edits are picked up without a reload.
        try "# Alpha\n- fact two <!-- hint -->".write(to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(store.context(for: "a"), "# Alpha\n- fact two")

        // A deleted profile must not be re-seeded on next launch.
        try fm.removeItem(at: dir.appendingPathComponent("b.md"))
        let again = ProfileStore(directory: dir, seedDirectory: seed)
        XCTAssertEqual(again.profiles.map(\.id), ["a"])

        // "_" files are always-on context: hidden from the picker, appended to every profile.
        try "# About us\n- we build cities".write(to: dir.appendingPathComponent("_About us.md"), atomically: true, encoding: .utf8)
        again.reload()
        XCTAssertEqual(again.profiles.map(\.id), ["a"])
        XCTAssertEqual(again.sharedProfiles.map(\.id), ["_About us"])
        XCTAssertEqual(again.context(for: "a"), "# Alpha\n- fact two\n\n---\n\n# About us\n- we build cities")
        XCTAssertEqual(again.context(for: "missing"), "# About us\n- we build cities")

        let created = again.createProfile()
        XCTAssertEqual(created?.id, "New Meeting")
        XCTAssertEqual(again.createProfile()?.id, "New Meeting 2")
    }

    func testBundledProfilesAreValid() throws {
        // Tests/ → StealthApp/Resources/Profiles
        let profilesDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Profiles")
        let files = try FileManager.default.contentsOfDirectory(at: profilesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }
        XCTAssertEqual(files.count, 3)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let id = file.deletingPathExtension().lastPathComponent
            XCTAssertNotEqual(MeetingProfile.title(fromMarkdown: text, fallback: ""), "", id)
            let stripped = MeetingProfile.stripComments(text)
            XCTAssertFalse(stripped.contains("<!--"), id)
            XCTAssertLessThan(stripped.count, Config.profileContextCharLimit, id)
        }
    }
}

final class ConfigTests: XCTestCase {
    func testPromptsAndDefaults() {
        let sys = Config.suggestionInstructions(mode: .reply, tone: .professional, meetingContext: "- We build data centers.")
        XCTAssertTrue(sys.contains("B1–B2"))
        XCTAssertTrue(sys.contains("Meeting goals") && sys.contains("Never manipulate") && sys.contains("OUTPUT FORMAT"))
        XCTAssertFalse(Config.suggestionInstructions(mode: .recap, tone: .professional, meetingContext: "").contains("OUTPUT FORMAT"))
        XCTAssertTrue(sys.contains("NEVER invent"))
        XCTAssertTrue(sys.contains("We build data centers."))
        XCTAssertTrue(Config.suggestionInstructions(mode: .reply, tone: .casual, meetingContext: " ").contains("no meeting context provided"))
        XCTAssertEqual(Config.translationPrompt(line: "Hi", context: []), "Translate:\nHi")
        XCTAssertTrue(Config.translationPrompt(line: "Hi", context: ["Them: A"]).hasSuffix("Translate:\nHi"))
        XCTAssertEqual(Config.reconnectDelay(attempt: 1), 1)
        XCTAssertEqual(Config.reconnectDelay(attempt: 3), 4)
        XCTAssertEqual(Config.reconnectDelay(attempt: 20), 15)
        XCTAssertTrue(Config.realtimeURL.absoluteString.hasPrefix("wss://api.openai.com/v1/realtime?model="))
    }
}

final class SentenceSegmenterTests: XCTestCase {
    private func run(_ deltas: [String]) -> (segments: [String], rest: String?) {
        var seg = SentenceSegmenter()
        var out: [String] = []
        for d in deltas { out += seg.feed(d) }
        return (out, seg.flush())
    }

    func testSplitsSentencesAsTheyComplete() {
        let r = run(["Thanks for", " joining today.", " What is your", " timeline?", " We are", " ready"])
        XCTAssertEqual(r.segments, ["Thanks for joining today.", "What is your timeline?"])
        XCTAssertEqual(r.rest, "We are ready")
    }

    func testKeepsShortSentencesDecimalsAndAbbreviations() {
        var r = run(["Okay. So the load is 3.5 megawatts. "])
        XCTAssertEqual(r.segments, ["Okay. So the load is 3.5 megawatts."])
        r = run(["We spoke with Dr. Smith about cooling, e.g. liquid cooling for racks. Next"])
        XCTAssertEqual(r.segments, ["We spoke with Dr. Smith about cooling, e.g. liquid cooling for racks."])
        XCTAssertEqual(r.rest, "Next")
        // A terminator at the very end waits for what follows.
        XCTAssertEqual(run(["This is done."]).segments, [])
    }

    func testCutsLongRunsAtCommaOrWordBoundary() {
        let long = "so what we are planning to do in the first phase of the project is to build two halls, "
            + "and then we will add more capacity when the grid connection is ready and "
        let r = run([long])
        XCTAssertEqual(r.segments.first, "so what we are planning to do in the first phase of the project is to build two halls,")
        let noPunct = Array(repeating: "word", count: 40).joined(separator: " ")
        let r2 = run([noPunct])
        XCTAssertEqual(r2.segments.count, 1)
        XCTAssertEqual((r2.segments.joined(separator: " ") + " " + (r2.rest ?? "")), noPunct)
    }

    func testSilenceDetector() {
        func chunk(_ amplitude: Int16, ms: Int) -> Data {
            var d = Data()
            for i in 0..<(24 * ms) {
                var s = (i % 2 == 0 ? amplitude : -amplitude).littleEndian
                withUnsafeBytes(of: &s) { d.append(contentsOf: $0) }
            }
            return d
        }
        var vad = SilenceDetector(speechThreshold: 250)
        XCTAssertEqual(SilenceDetector.rms(chunk(1000, ms: 10)), 1000, accuracy: 1)
        // Silence before any speech never ends an utterance.
        for _ in 0..<20 { XCTAssertFalse(vad.process(chunk(0, ms: 100))) }
        XCTAssertFalse(vad.process(chunk(3000, ms: 500)))
        XCTAssertFalse(vad.process(chunk(0, ms: 300)))
        XCTAssertFalse(vad.process(chunk(3000, ms: 200)))   // speech resumes → silence resets
        XCTAssertFalse(vad.process(chunk(0, ms: 300)))
        XCTAssertTrue(vad.process(chunk(0, ms: 400)))        // 700 ms of silence → end
        XCTAssertFalse(vad.process(chunk(0, ms: 1000)))      // idle again
    }
}

final class TranslationPairerTests: XCTestCase {
    func testPairsInOrderBothDirections() {
        var p = TranslationPairer()
        let t0 = Date(timeIntervalSince1970: 1_000)
        let a = UUID(), b = UUID(), c = UUID()
        // English first, then its translation.
        XCTAssertEqual(p.lineCommitted(a, now: t0), [])
        XCTAssertEqual(p.translationArrived("А.", now: t0 + 1), .init(lineID: a, text: "А."))
        // An extra sentence soon after joins the same line.
        XCTAssertEqual(p.translationArrived("А2.", now: t0 + 2), .init(lineID: a, text: "А2."))
        // Translation first (after the append window), then its English line.
        XCTAssertNil(p.translationArrived("Б.", now: t0 + 20))
        XCTAssertNil(p.translationArrived("Б2.", now: t0 + 21))
        XCTAssertEqual(p.lineCommitted(b, now: t0 + 22), [.init(lineID: b, text: "Б. Б2.")])
        // Two lines waiting are served oldest first.
        let d = UUID()
        XCTAssertEqual(p.lineCommitted(c, now: t0 + 40), [])
        XCTAssertEqual(p.lineCommitted(d, now: t0 + 41), [])
        XCTAssertEqual(p.translationArrived("В.", now: t0 + 42)?.lineID, c)
        XCTAssertEqual(p.translationArrived("Г.", now: t0 + 43)?.lineID, d)
    }

    func testStaleEntriesDoNotShiftLaterPairs() {
        var p = TranslationPairer()
        let t0 = Date(timeIntervalSince1970: 2_000)
        let old = UUID(), fresh = UUID()
        XCTAssertEqual(p.lineCommitted(old, now: t0), [])           // never gets a translation
        XCTAssertEqual(p.lineCommitted(fresh, now: t0 + 30), [])
        XCTAssertEqual(p.translationArrived("Свежий.", now: t0 + 31)?.lineID, fresh)
        // A translation whose line never came is dropped, not glued to a later line.
        XCTAssertNil(p.translationArrived("Потерянный.", now: t0 + 60))
        XCTAssertEqual(p.lineCommitted(UUID(), now: t0 + 100), [])
    }

    func testSummaryInMarkdownAndPrompt() {
        var record = SessionRecord(startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 60),
                                   lines: [], profile: nil)
        XCTAssertFalse(record.markdown.contains("Расшифровка"))
        record.summary = "## Итоги\n- Обсудили пилот."
        XCTAssertTrue(record.markdown.contains("## Итоги\n- Обсудили пилот."))
        XCTAssertTrue(record.markdown.contains("## Расшифровка"))
        let prompt = Config.summaryInstructions(meetingContext: "- ctx fact")
        XCTAssertTrue(prompt.contains("## Задачи") && prompt.contains("ONLY what is in the transcript") && prompt.contains("ctx fact"))
        XCTAssertEqual(Config.liveTranslationURL.absoluteString, "wss://api.openai.com/v1/realtime/translations?model=gpt-realtime-translate")
    }
}

@MainActor
final class GoalTests: XCTestCase {
    let profile = """
    # Meeting
    <!-- hint -->
    ## Company
    - not a goal
    ## Meeting goals
    - Agree on ONE pilot process
    - TODO: цель этой встречи
    * Get a named contact
    1. Fix the date of the next session
    ## About us
    - also not a goal
    """

    func testParsesGoalsSection() {
        XCTAssertEqual(GoalParser.goals(fromMarkdown: profile),
                       ["Agree on ONE pilot process", "Get a named contact", "Fix the date of the next session"])
        XCTAssertEqual(GoalParser.goals(fromMarkdown: "## Цели встречи\n- Договориться о пилоте\n## Другое\n- x"), ["Договориться о пилоте"])
        XCTAssertEqual(GoalParser.goals(fromMarkdown: "# No goals here\n- x"), [])
    }

    func testParsesModelOutput() {
        let out = "1|progress|обсуждают пилот\n2 | DONE | Антон, контакт назван\nnoise line\n3|open|\n9|maybe|x"
        XCTAssertEqual(GoalParser.updates(fromModelOutput: out), [
            GoalUpdate(id: 1, status: .progress, note: "обсуждают пилот"),
            GoalUpdate(id: 2, status: .done, note: "Антон, контакт назван"),
            GoalUpdate(id: 3, status: .open, note: ""),
        ])
    }

    func testStatusesOnlyMoveForwardAndManualWins() {
        let store = GoalStore()
        store.load(fromMarkdown: profile, resetStatuses: true)
        XCTAssertEqual(store.goals.count, 3)
        store.apply([GoalUpdate(id: 1, status: .done, note: "да"), GoalUpdate(id: 2, status: .progress, note: "идёт")])
        store.apply([GoalUpdate(id: 1, status: .open, note: "шум"), GoalUpdate(id: 2, status: .open, note: "")])
        XCTAssertEqual(store.goals.map(\.status), [.done, .progress, .open])
        XCTAssertEqual(store.doneCount, 1)
        // Manual untick sticks, whatever the model says later.
        store.toggle(1)
        store.apply([GoalUpdate(id: 1, status: .done, note: "да")])
        XCTAssertEqual(store.goals[0].status, .open)
        // Re-reading an unchanged file keeps statuses; a changed goal list resets them.
        store.load(fromMarkdown: profile, resetStatuses: false)
        XCTAssertEqual(store.goals[1].status, .progress)
        store.load(fromMarkdown: "## Meeting goals\n- New goal", resetStatuses: false)
        XCTAssertEqual(store.goals.map(\.text), ["New goal"])
        XCTAssertTrue(store.promptSummary.contains("1. [OPEN] New goal"))
        XCTAssertTrue(Config.suggestionPrompt(transcript: "Them: hi", mode: .reply, goals: store.promptSummary).contains("[OPEN] New goal"))
    }
}

final class NoteExporterTests: XCTestCase {
    func testNoteNamingAndRewrite() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("stealth-notes-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: dir) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var a = SessionRecord(startedAt: start, endedAt: start + 600, lines: [],
                              profile: "Acme Robotics × Northwind — Pilot / Scope")
        XCTAssertEqual(NoteExporter.baseName(for: a), "UNC - Встреча Acme Robotics × Northwind")
        XCTAssertEqual(NoteExporter.baseName(for: SessionRecord(startedAt: start, endedAt: start, lines: [])), "UNC - Встреча")

        let first = try NoteExporter.write(a, to: dir)
        XCTAssertEqual(first.lastPathComponent, "UNC - Встреча Acme Robotics × Northwind.md")
        var text = try String(contentsOf: first, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("---\ncreated: "))
        XCTAssertTrue(text.contains("type: meeting") && text.contains("status: inbox") && text.contains("session_id: \(a.id.uuidString)"))
        XCTAssertFalse(text.contains("## Итоги"))

        // Long Cyrillic content right after the front matter must not break the
        // "is this my file?" check (a byte-limited read can split a character).
        a = SessionRecord(id: a.id, startedAt: a.startedAt, endedAt: a.endedAt, lines: [],
                          profile: a.profile, summary: String(repeating: "я", count: 3_000))
        XCTAssertEqual(try NoteExporter.write(a, to: dir), first)

        // The summary arrives later: same session → same file, updated in place.
        a.summary = "## Итоги\n- Договорились о пилоте."
        XCTAssertEqual(try NoteExporter.write(a, to: dir), first)
        text = try String(contentsOf: first, encoding: .utf8)
        XCTAssertTrue(text.contains("## Итоги"))

        // Another meeting with the same profile gets its own file.
        let b = SessionRecord(startedAt: start + 3_600, endedAt: start + 4_000, lines: [], profile: a.profile)
        XCTAssertEqual(try NoteExporter.write(b, to: dir).lastPathComponent, "UNC - Встреча Acme Robotics × Northwind 2.md")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dir.path).count, 2)
    }
}

final class CostMeterTests: XCTestCase {
    func testAudioAndTextCost() {
        var m = CostMeter()
        m.addAudio(model: "gpt-live-transcribe", seconds: 3_600)        // 60 min × $0.017
        m.addAudio(model: "gpt-realtime-translate", seconds: 1_800)     // 30 min × $0.034
        XCTAssertEqual(m.audioUSD, 1.02 + 1.02, accuracy: 0.0001)
        // 1M input of which 400k cached, 100k output on gpt-4.1-mini (dated snapshot id).
        m.addText(model: "gpt-4.1-mini-2025-04-14", inputTokens: 1_000_000, cachedTokens: 400_000, outputTokens: 100_000)
        XCTAssertEqual(m.textUSD, 0.6 * 0.40 + 0.4 * 0.10 + 0.1 * 1.60, accuracy: 0.0001)
        XCTAssertEqual(m.label, "≈ $2.48")
        XCTAssertTrue(m.unpriced.isEmpty)
        // Unknown models are flagged, not silently counted as free.
        m.addText(model: "some-future-model", inputTokens: 10, cachedTokens: 0, outputTokens: 10)
        m.addAudio(model: "another-audio-model", seconds: 60)
        XCTAssertEqual(m.unpriced, ["some-future-model", "another-audio-model"])
        XCTAssertTrue(m.label.hasSuffix("+"))
        XCTAssertTrue(m.breakdown.contains("some-future-model"))
        XCTAssertEqual(CostMeter.format(0.0123), "≈ $0.012")
    }

    func testUsageEventParsing() {
        let line = #"data: {"choices":[],"usage":{"prompt_tokens":1200,"completion_tokens":45,"prompt_tokens_details":{"cached_tokens":1024}}}"#
        XCTAssertEqual(SSEParser.parse(line: line), .usage(input: 1200, cached: 1024, output: 45))
    }
}
