import Foundation
import OSLog

/// Drives one OpenAI Realtime API session over a WebSocket — transcription only.
///
/// Responsibilities:
///  - connect with the Keychain API key
///  - configure the session for input-audio transcription (live transcript)
///  - stream one audio source up as base64 PCM16
///  - surface transcription deltas + completed lines
///  - reconnect automatically after an unexpected drop (network blip, or the
///    server-side session duration cap on long calls)
///
/// Translation and reply suggestions are NOT done here — they go through the
/// text API (`TextLLMClient`). All callbacks are invoked on the main actor.
@MainActor
final class RealtimeClient: NSObject, ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case failed(String)
    }

    @Published private(set) var state: ConnectionState = .disconnected {
        didSet { if state != oldValue { onStateChange?() } }
    }

    /// Which side of the conversation this client transcribes.
    let speaker: Speaker

    init(speaker: Speaker) {
        self.speaker = speaker
        super.init()
    }

    // Callbacks wired up by the coordinator.
    var onTranscriptDelta: ((String, Speaker) -> Void)?
    var onTranscriptCompleted: ((String, Speaker) -> Void)?
    /// Streaming mode: the not-yet-finished tail of the current sentence.
    var onPartialReplaced: ((String, Speaker) -> Void)?
    var onError: ((String) -> Void)?
    var onStateChange: (() -> Void)?

    private let log = Logger(subsystem: "com.stealth.app", category: "realtime")
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?

    /// True between `connect()` and `disconnect()` — i.e. the user wants this
    /// session up, so an unexpected drop triggers a reconnect.
    private var wantsConnection = false
    private var reconnectAttempt = 0
    private var reconnectWork: Task<Void, Never>?

    // --- Streaming transcription mode (gpt-live-*) ---
    /// True while this socket runs a streaming transcription session: text arrives
    /// during speech, the client cuts it into sentences and signals utterance ends.
    private var streaming = false
    /// Set when the API rejected the streaming session; stay on the proven
    /// phrase-by-phrase model for the rest of this run.
    private var streamingRejected = false
    private var segmenter = SentenceSegmenter()
    private lazy var silenceDetector = SilenceDetector(speechThreshold: Config.speechRMSThreshold(for: speaker))

    /// The transcription model this socket is actually using (after any fallback).
    var activeTranscriptionModel: String { transcriptionModel }

    private var transcriptionModel: String {
        streamingRejected ? Config.fallbackTranscriptionModel : Config.model(.transcription)
    }

    /// Errors that will not fix themselves by retrying (bad key, no access to the model).
    private static let fatalCodes: Set<String> = [
        "invalid_api_key", "insufficient_quota", "model_not_found", "invalid_model",
    ]

    // MARK: - Connection

    func connect() {
        guard !wantsConnection else { return }
        wantsConnection = true
        reconnectAttempt = 0
        openSocket()
    }

    func disconnect() {
        wantsConnection = false
        reconnectWork?.cancel()
        reconnectWork = nil
        closeSocket()
        state = .disconnected
    }

    private func openSocket() {
        guard let apiKey = KeychainStore.load() else {
            wantsConnection = false
            state = .failed("Нет API-ключа — откройте Настройки.")
            onError?("Нет API-ключа — откройте Настройки.")
            return
        }
        closeSocket()
        state = reconnectAttempt == 0 ? .connecting : .reconnecting

        streaming = Config.isStreamingTranscription(transcriptionModel)
        flushSegmenter()
        silenceDetector = SilenceDetector(speechThreshold: Config.speechRMSThreshold(for: speaker))

        var request = URLRequest(url: streaming ? Config.transcriptionURL : Config.realtimeURL)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // GA interface: the `OpenAI-Beta: realtime=v1` header must NOT be sent.

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        // Do NOT start receiving yet — wait for `didOpenWithProtocol`.
        // Calling receive() before the socket is open throws POSIX 57
        // ("Socket is not connected") and tears the connection down.
        DebugLog.log("[\(speaker.rawValue)] connect (attempt \(reconnectAttempt)) transcription=\(transcriptionModel) streaming=\(streaming)")
        task.resume()
    }

    private func closeSocket() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        // URLSession retains its delegate until invalidated — release it.
        session?.invalidateAndCancel()
        session = nil
    }

    /// The socket dropped without us asking. Retry with back-off for as long as
    /// the user still wants the session.
    private func handleUnexpectedDrop(_ reason: String) {
        guard wantsConnection else { return }
        closeSocket()
        reconnectAttempt += 1
        let delay = Config.reconnectDelay(attempt: reconnectAttempt)
        state = .reconnecting
        DebugLog.log("[\(speaker.rawValue)] dropped (\(reason)) — reconnect #\(reconnectAttempt) in \(delay)s")
        reconnectWork?.cancel()
        reconnectWork = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.wantsConnection else { return }
            self.openSocket()
        }
    }

    /// Configure the session (GA schema): input-audio transcription enabled and
    /// NO automatic responses — this socket only ever transcribes.
    private func configureSession() {
        if streaming {
            // Streaming transcription session: text deltas arrive while the person
            // speaks. No server turn detection — we commit on client-detected silence.
            send([
                "type": "session.update",
                "session": [
                    "type": "transcription",
                    "audio": [
                        "input": [
                            "format": [
                                "type": "audio/pcm",
                                "rate": Int(Config.realtimeSampleRate),
                            ],
                            "transcription": [
                                "model": transcriptionModel,
                                "languages": ["en"],
                                "delay": Config.streamingDelay,
                            ],
                            "turn_detection": NSNull(),
                        ],
                    ],
                ],
            ])
            return
        }
        let event: [String: Any] = [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["text"],
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": Int(Config.realtimeSampleRate),
                        ],
                        "transcription": [
                            "model": transcriptionModel,
                            "language": "en",
                        ],
                        // Server VAD detects speech boundaries and auto-commits the
                        // audio buffer, which is what triggers transcription. We keep
                        // `create_response: false` so the model NEVER replies on this
                        // socket. Without VAD the buffer is never committed, no
                        // transcription fires, and the server eventually closes the
                        // idle socket (close code 1001).
                        "turn_detection": [
                            "type": "server_vad",
                            // IMPORTANT: must be a binary-clean Double — JSONSerialization
                            // prints e.g. 0.3 as "0.29999999999999999" (17 dp), which the
                            // API rejects (decimal_max_decimal_places_exceeded). Config only
                            // returns exactly-representable values (0.25, 0.5).
                            "threshold": Config.vadThreshold(for: speaker),
                            // Lead-in audio kept before the detected speech start, so
                            // the first word isn't clipped.
                            "prefix_padding_ms": 500,
                            "silence_duration_ms": Config.vadSilenceMs,
                            "create_response": false,
                            "interrupt_response": false,
                        ],
                    ],
                ],
            ],
        ]
        send(event)
    }

    // MARK: - Audio in

    private var audioChunkCount = 0

    /// Append a chunk of PCM16 mono 24kHz audio to the input buffer.
    /// Audio that arrives while (re)connecting is dropped.
    func sendAudio(_ pcm16: Data) {
        audioChunkCount += 1
        guard state == .connected else {
            if audioChunkCount % 200 == 1 {
                DebugLog.log("[\(speaker.rawValue)] sendAudio dropped (state=\(state))")
            }
            return
        }
        if audioChunkCount % 500 == 1 {
            DebugLog.log("[\(speaker.rawValue)] sendAudio OK #\(audioChunkCount) — \(pcm16.count) bytes")
        }
        send([
            "type": "input_audio_buffer.append",
            "audio": pcm16.base64EncodedString(),
        ])
        // Streaming mode has no server VAD: tell the server when the utterance
        // ended so it finalises the text and frees its buffer.
        if streaming, silenceDetector.process(pcm16) {
            send(["type": "input_audio_buffer.commit"])
        }
    }

    // MARK: - Streaming text → sentences

    private func handleStreamingDelta(_ delta: String) {
        for segment in segmenter.feed(delta) {
            onTranscriptCompleted?(segment, speaker)
        }
        onPartialReplaced?(segmenter.buffer.trimmingCharacters(in: .whitespacesAndNewlines), speaker)
    }

    /// Utterance ended (or the socket is being replaced): emit the unfinished tail.
    private func flushSegmenter() {
        if let rest = segmenter.flush() {
            onTranscriptCompleted?(rest, speaker)
        }
        onPartialReplaced?("", speaker)
    }

    /// The API refused the streaming session — reconnect with the older model.
    private func fallBackFromStreaming(_ reason: String) {
        DebugLog.log("[\(speaker.rawValue)] streaming transcription rejected (\(reason)) — falling back to \(Config.fallbackTranscriptionModel)")
        streamingRejected = true
        reconnectAttempt = 0
        openSocket()
    }

    // MARK: - Send / receive plumbing

    private func send(_ json: [String: Any]) {
        guard let task else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: json),
              let string = String(data: data, encoding: .utf8)
        else { return }
        task.send(.string(string)) { _ in
            // A failed send means the socket is going down; the receive loop
            // reports that and triggers the reconnect.
        }
    }

    private func receiveLoop(on socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            Task { @MainActor in
                // Ignore callbacks from a socket we've already replaced or closed.
                guard let self, self.task === socket else { return }
                switch result {
                case .failure(let error):
                    self.handleUnexpectedDrop(error.localizedDescription)
                case .success(let message):
                    if case let .string(text) = message { self.handleEvent(text) }
                    self.receiveLoop(on: socket)
                }
            }
        }
    }

    // MARK: - Event handling

    private func handleEvent(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String
        else { return }

        switch type {
        case "session.created", "transcription_session.created":
            // Configure as soon as the session exists.
            configureSession()

        case "session.updated", "transcription_session.updated":
            reconnectAttempt = 0
            state = .connected
            DebugLog.log("[\(speaker.rawValue)] connected")

        // --- Live transcription of this client's audio source ---
        case "conversation.item.input_audio_transcription.delta":
            if let delta = obj["delta"] as? String {
                if streaming { handleStreamingDelta(delta) } else { onTranscriptDelta?(delta, speaker) }
            }

        case "conversation.item.input_audio_transcription.completed":
            if streaming {
                // Lines were already emitted sentence by sentence from the deltas;
                // only the unfinished tail is left.
                flushSegmenter()
            } else if let transcript = obj["transcript"] as? String {
                onTranscriptCompleted?(transcript, speaker)
            }

        case "conversation.item.input_audio_transcription.failed":
            let err = obj["error"] as? [String: Any]
            DebugLog.log("[\(speaker.rawValue)] transcription failed: \(err?["message"] as? String ?? "?")")

        case "error":
            let err = obj["error"] as? [String: Any]
            let message = err?["message"] as? String ?? "Unknown realtime error"
            let code = err?["code"] as? String ?? "?"
            DebugLog.log("[\(speaker.rawValue)] REALTIME ERROR code=\(code): \(message)")
            if streaming, state != .connected {
                // The streaming session could not be set up — use the older model.
                fallBackFromStreaming("\(code): \(message)")
                return
            }
            // An empty-buffer commit after a false speech detection is harmless.
            if code == "input_audio_buffer_commit_empty" { return }
            if Self.fatalCodes.contains(code) {
                // Retrying will not help — stop and tell the user.
                wantsConnection = false
                reconnectWork?.cancel()
                closeSocket()
                state = .failed(message)
            }
            onError?(message)

        default:
            break
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension RealtimeClient: URLSessionWebSocketDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        // Socket is genuinely open now — safe to start receiving.
        Task { @MainActor in
            guard self.task === webSocketTask else { return }
            self.receiveLoop(on: webSocketTask)
            guard self.streaming else { return }
            // If the streaming session never becomes ready, don't leave the user
            // staring at "Connecting…" — switch to the older model.
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if self.task === webSocketTask, self.streaming, self.state != .connected {
                self.fallBackFromStreaming("not ready after 6s")
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        Task { @MainActor in
            guard self.task === webSocketTask else { return }
            self.handleUnexpectedDrop("closed \(closeCode.rawValue) \(reasonText)")
        }
    }

    /// Handshake failures (401 bad key, 403/404 no model access, no network) land here.
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        Task { @MainActor in
            guard self.task === task else { return }
            if self.streaming, let status, [400, 403, 404].contains(status) {
                self.fallBackFromStreaming("handshake HTTP \(status)")
            } else if let status, [401, 403, 404].contains(status) {
                let message = status == 401
                    ? "OpenAI отклонил API-ключ (401). Проверьте ключ в Настройках."
                    : "Нет доступа к модели \(Config.model(.realtime)) (HTTP \(status)). Проверьте имя модели в Настройках."
                DebugLog.log("[\(self.speaker.rawValue)] handshake rejected: \(status)")
                self.wantsConnection = false
                self.closeSocket()
                self.state = .failed(message)
                self.onError?(message)
            } else {
                self.handleUnexpectedDrop(error?.localizedDescription ?? "completed")
            }
        }
    }
}
