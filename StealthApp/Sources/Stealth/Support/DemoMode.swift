import AppKit

/// Demo mode: shows the overlay with a scripted sample conversation, so the
/// layout can be tried — and screenshots or a short clip produced — without an
/// API key, permissions or any spend. Nothing is sent anywhere.
///
///   open Stealth.app --args -demo YES                       static sample
///   … -demo YES -snapshotDir <dir>                           + PNGs of the app's windows
///   … -demo YES -demoPlay YES -snapshotDir <dir>             animated: frames in <dir>/frames
///   … -profilesDir <dir> -selectedProfileID "<file name>"    use another set of profiles
///
/// Windows are rendered from inside the app, because the overlay is excluded
/// from ordinary screen capture by design.
@MainActor
enum DemoMode {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "demo") }
    static var isAnimated: Bool { UserDefaults.standard.bool(forKey: "demoPlay") }
    static var snapshotDir: String? { UserDefaults.standard.string(forKey: "snapshotDir") }

    private struct Turn {
        let english: String
        let russian: String
    }

    private static let turns = [
        Turn(english: "Thanks for joining. We looked at your proposal, and the pilot idea is interesting.",
             russian: "Спасибо, что присоединились. Мы посмотрели ваше предложение, и идея пилота нам интересна."),
        Turn(english: "What would be the scope of the first phase, and who would lead it on your side?",
             russian: "Каким будет объём первого этапа и кто будет вести его с вашей стороны?"),
        Turn(english: "That works. Anna will be your contact, and we can meet next Tuesday.",
             russian: "Подходит. Вашим контактом будет Анна, и мы можем встретиться в следующий вторник."),
    ]

    private static let reply = "We suggest starting small: one site and one process, so the result is easy to measure. Who on your team should we plan it with?"
    private static let replyNote = "цель: рабочий контакт · открытый вопрос"
    private static let replyRussian = "Предлагаем начать с малого: одна площадка и один процесс, чтобы результат было легко измерить. С кем из вашей команды нам это спланировать?"

    // MARK: - Static sample

    static func populate(_ coordinator: AppCoordinator) {
        coordinator.demoSetLive(true)
        for turn in turns.prefix(2) { commit(turn, coordinator) }
        coordinator.transcript.setPartial("That works. Anna will be your", speaker: .them)
        coordinator.transcript.partialTranslation = "Подходит. Вашим контактом будет"
        coordinator.suggestion.begin(mode: .reply, auto: true)
        coordinator.suggestion.appendDelta(reply + "\n# " + replyNote)
        coordinator.suggestion.finish()
        coordinator.suggestion.appendTranslation(replyRussian)
        coordinator.reloadGoals(resetStatuses: true)
        coordinator.goals.apply([GoalUpdate(id: 1, status: .progress, note: "обсуждают объём первого этапа")])
        coordinator.demoAddCost(minutes: 3.5)
        coordinator.statusMessage = "Демо-режим — данные не настоящие"
    }

    private static func commit(_ turn: Turn, _ coordinator: AppCoordinator) {
        if let line = coordinator.transcript.commit(turn.english, speaker: .them) {
            coordinator.transcript.appendTranslation(turn.russian, to: line.id)
        }
        coordinator.transcript.appendTranslatedSentence(turn.russian)
    }

    // MARK: - Animated sample

    /// Play the conversation in real time, saving a frame of the overlay ten
    /// times a second, then quit. The frames are assembled into a clip outside.
    static func play(_ coordinator: AppCoordinator, overlay: NSWindow, into dir: String) async {
        let frames = URL(fileURLWithPath: dir).appendingPathComponent("frames")
        try? FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)

        coordinator.demoSetLive(true)
        coordinator.reloadGoals(resetStatuses: true)
        coordinator.statusMessage = "Слушаю: вы + собеседник"

        var frame = 0
        let recorder = Task { @MainActor in
            while !Task.isCancelled {
                if let png = snapshot(of: overlay) {
                    try? png.write(to: frames.appendingPathComponent(String(format: "f_%04d.png", frame)))
                    frame += 1
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }

        await pause(1.2)
        await speak(turns[0], coordinator)
        await pause(0.5)
        await speak(turns[1], coordinator)
        coordinator.goals.apply([GoalUpdate(id: 1, status: .progress, note: "обсуждают объём первого этапа")])

        // A question → the reply suggestion streams in.
        coordinator.suggestion.begin(mode: .reply, auto: true)
        await pause(0.9)
        for word in reply.split(separator: " ") {
            coordinator.suggestion.appendDelta(word + " ")
            await pause(0.055)
        }
        coordinator.suggestion.appendDelta("\n# " + replyNote)
        coordinator.suggestion.finish()
        await pause(0.3)
        coordinator.suggestion.appendTranslation(replyRussian)
        await pause(3.0)

        await speak(turns[2], coordinator)
        await pause(0.8)
        coordinator.goals.apply([
            GoalUpdate(id: 2, status: .done, note: "контакт — Anna"),
            GoalUpdate(id: 3, status: .done, note: "следующий вторник"),
        ])
        await pause(3.0)

        recorder.cancel()
        _ = await recorder.value
        NSApp.terminate(nil)
    }

    /// English appears word by word; the Russian follows about half a second behind.
    private static func speak(_ turn: Turn, _ coordinator: AppCoordinator) async {
        let english = turn.english.split(separator: " ").map(String.init)
        let russian = turn.russian.split(separator: " ").map(String.init)
        let lag = 3
        for step in 0..<(english.count + lag) {
            if step < english.count {
                coordinator.transcript.setPartial(english.prefix(step + 1).joined(separator: " "), speaker: .them)
            }
            // Map progress through the English sentence onto the Russian one.
            let done = max(0, step - lag + 1)
            let shown = Int((Double(done) / Double(english.count) * Double(russian.count)).rounded(.up))
            coordinator.transcript.partialTranslation = russian.prefix(min(shown, russian.count)).joined(separator: " ")
            coordinator.demoAddCost(minutes: 0.004)
            await pause(0.17)
        }
        coordinator.transcript.setPartial("", speaker: .them)
        coordinator.transcript.partialTranslation = ""
        commit(turn, coordinator)
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: - Rendering

    private static func snapshot(of window: NSWindow) -> Data? {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// Render each visible window of this app into `<dir>/<name>.png`.
    static func snapshotWindows(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for window in NSApp.windows where window.isVisible {
            guard let png = snapshot(of: window) else { continue }
            let name = window is OverlayWindow ? "overlay" : "window-\(window.title.isEmpty ? "untitled" : window.title)"
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
