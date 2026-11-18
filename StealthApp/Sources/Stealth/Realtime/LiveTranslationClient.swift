import Foundation

/// Simultaneous speech → text translation over the OpenAI Realtime translation
/// endpoint (`gpt-realtime-translate`).
///
/// Unlike the transcribe-then-translate path, the model translates straight from
/// the audio and streams target-language text while the person is still
/// speaking. It also produces translated AUDIO, which this client discards — only
/// the transcript deltas are used.
///
/// If the session cannot be set up (no access to the model, unsupported target
/// language, …) `onUnavailable` fires once and the coordinator goes back to
/// translating finished sentences through the text API.
@MainActor
final class LiveTranslationClient: NSObject {
    /// A finished translated sentence.
    var onSegment: ((String) -> Void)?
    /// The unfinished tail of the sentence currently being translated.
    var onPartial: ((String) -> Void)?
    /// The session could not be used; the reason is for the log / status line.
    var onUnavailable: ((String) -> Void)?

    private(set) var isReady = false

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var wantsConnection = false
    private var reconnectAttempt = 0
    private var reconnectWork: Task<Void, Never>?
    private var idleFlush: Task<Void, Never>?

    private var segmenter = SentenceSegmenter()
    /// Audio is forwarded in ~200 ms frames, as the endpoint recommends.
    private var pending = Data()
    private static let frameBytes = 9_600   // 200 ms of 24 kHz mono PCM16

    func connect() {
        guard !wantsConnection else { return }
        wantsConnection = true
        reconnectAttempt = 0
        openSocket()
    }

    func disconnect() {
        wantsConnection = false
        reconnectWork?.cancel()
        idleFlush?.cancel()
        flush()
        closeSocket()
    }

    private func openSocket() {
        guard let apiKey = KeychainStore.load() else { return }
        closeSocket()
        var request = URLRequest(url: Config.liveTranslationURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        DebugLog.log("[Translate] connect (attempt \(reconnectAttempt)) model=\(Config.model(.liveTranslation))")
        task.resume()
    }

    private func closeSocket() {
        isReady = false
        pending.removeAll(keepingCapacity: true)
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    /// Give up on simultaneous translation for this run.
    private func giveUp(_ reason: String) {
        guard wantsConnection else { return }
        DebugLog.log("[Translate] unavailable: \(reason)")
        wantsConnection = false
        reconnectWork?.cancel()
        flush()
        closeSocket()
        onUnavailable?(reason)
    }

    private func handleDrop(_ reason: String) {
        guard wantsConnection else { return }
        // A drop before the session ever became ready means it will not work.
        guard isReady || reconnectAttempt > 0 else { giveUp(reason); return }
        let wasReady = isReady
        closeSocket()
        reconnectAttempt = wasReady ? 1 : reconnectAttempt + 1
        guard reconnectAttempt <= 5 else { giveUp("reconnect failed: \(reason)"); return }
        let delay = Config.reconnectDelay(attempt: reconnectAttempt)
        DebugLog.log("[Translate] dropped (\(reason)) — reconnect in \(delay)s")
        reconnectWork?.cancel()
        reconnectWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.wantsConnection else { return }
            self.openSocket()
        }
    }

    // MARK: - Audio in

    func sendAudio(_ pcm16: Data) {
        guard isReady else { return }
        pending.append(pcm16)
        while pending.count >= Self.frameBytes {
            let frame = pending.prefix(Self.frameBytes)
            pending.removeFirst(Self.frameBytes)
            send([
                "type": "session.input_audio_buffer.append",
                "audio": Data(frame).base64EncodedString(),
            ])
        }
    }

    private func send(_ json: [String: Any]) {
        guard let task,
              let data = try? JSONSerialization.data(withJSONObject: json),
              let string = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(string)) { _ in }
    }

    // MARK: - Events

    private func receiveLoop(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === socket else { return }
                switch result {
                case .failure(let error):
                    self.handleDrop(error.localizedDescription)
                case .success(let message):
                    if case let .string(text) = message { self.handleEvent(text) }
                    self.receiveLoop(on: socket)
                }
            }
        }
    }

    private func handleEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return }

        switch type {
        case "session.created":
            send([
                "type": "session.update",
                "session": ["audio": ["output": ["language": Config.translationTargetLanguage]]],
            ])

        case "session.updated":
            isReady = true
            reconnectAttempt = 0
            DebugLog.log("[Translate] ready (→ \(Config.translationTargetLanguage))")

        case "session.output_transcript.delta":
            guard let delta = obj["delta"] as? String, !delta.isEmpty else { return }
            for segment in segmenter.feed(delta) { onSegment?(segment) }
            onPartial?(segmenter.buffer.trimmingCharacters(in: .whitespacesAndNewlines))
            scheduleIdleFlush()

        case "error":
            let err = obj["error"] as? [String: Any]
            let message = err?["message"] as? String ?? "unknown error"
            DebugLog.log("[Translate] ERROR \(err?["code"] as? String ?? "?"): \(message)")
            // An error before the session is configured (bad language, no access)
            // will not fix itself; later ones are documented as recoverable.
            if !isReady { giveUp(message) }

        default:
            break   // session.output_audio.delta (translated speech) is intentionally ignored
        }
    }

    /// The endpoint sends no "sentence finished" event. When the text stops
    /// arriving, the speaker has paused: emit the tail as a finished segment.
    private func scheduleIdleFlush() {
        idleFlush?.cancel()
        idleFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        if let rest = segmenter.flush() { onSegment?(rest) }
        onPartial?("")
    }
}

extension LiveTranslationClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor in
            guard self.task === webSocketTask else { return }
            self.receiveLoop(on: webSocketTask)
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if self.task === webSocketTask, !self.isReady { self.giveUp("not ready after 8s") }
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor in
            guard self.task === webSocketTask else { return }
            self.handleDrop("closed \(closeCode.rawValue)")
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        Task { @MainActor in
            guard self.task === task else { return }
            if let status, (400...499).contains(status) {
                self.giveUp("handshake HTTP \(status)")
            } else {
                self.handleDrop(error?.localizedDescription ?? "completed")
            }
        }
    }
}
