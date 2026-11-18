import Foundation

/// Cuts a live stream of transcript text into short segments (sentences or long
/// clauses) as it arrives, so each one can be shown and translated immediately
/// instead of waiting for the speaker to pause.
///
/// Pure and Foundation-only (unit-tested).
struct SentenceSegmenter {
    /// Text received so far that has not been emitted as a segment yet.
    private(set) var buffer = ""

    /// A sentence shorter than this is kept and merged with what follows ("Okay." "So.").
    var minWords = 3
    /// Past this many words without a sentence end, cut at the last comma.
    var softLimitWords = 18
    /// Past this many words with no punctuation at all, cut at a word boundary.
    var hardLimitWords = 32

    private static let abbreviations: Set<String> = [
        "mr.", "mrs.", "ms.", "dr.", "prof.", "e.g.", "i.e.", "vs.", "etc.", "inc.", "ltd.",
        "no.", "u.s.", "u.k.", "a.m.", "p.m.", "st.", "jr.", "sr.",
    ]

    /// Add newly arrived text. Returns the segments that are now complete, in order.
    mutating func feed(_ delta: String) -> [String] {
        buffer += delta
        var out: [String] = []
        while let cut = nextCut() {
            let segment = String(buffer[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = String(buffer[cut...])
            if !segment.isEmpty { out.append(segment) }
        }
        return out
    }

    /// The speaker stopped: emit whatever is left.
    mutating func flush() -> String? {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? nil : rest
    }

    /// Index just past the next segment, or nil if the buffer should keep growing.
    private func nextCut() -> String.Index? {
        // 1. A sentence terminator followed by whitespace (so "3.5" and a trailing
        //    "." that may still become "..." or "3.5" are left alone).
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let ch = buffer[index]
            let next = buffer.index(after: index)
            if ".!?…".contains(ch), next < buffer.endIndex, buffer[next].isWhitespace {
                let candidate = buffer[..<next]
                if wordCount(candidate) >= minWords, !endsWithAbbreviation(candidate) {
                    return next
                }
            }
            index = next
        }

        // 2. A long run with no sentence end: cut at the last comma-like break
        //    that leaves a reasonable head.
        let words = wordCount(buffer[...])
        if words >= softLimitWords {
            var i = buffer.endIndex
            while i > buffer.startIndex {
                i = buffer.index(before: i)
                let next = buffer.index(after: i)
                if ",;:—".contains(buffer[i]), next < buffer.endIndex, buffer[next].isWhitespace,
                   wordCount(buffer[..<next]) >= softLimitWords / 2 {
                    return next
                }
            }
        }

        // 3. No punctuation at all: cut at the last word boundary.
        if words >= hardLimitWords, let space = buffer.lastIndex(where: { $0.isWhitespace }) {
            return space
        }
        return nil
    }

    private func wordCount(_ text: Substring) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private func endsWithAbbreviation(_ text: Substring) -> Bool {
        guard let last = text.split(whereSeparator: { $0.isWhitespace }).last else { return false }
        let word = last.lowercased()
        if Self.abbreviations.contains(word) { return true }
        // Single initial: "J. Smith"
        return word.count == 2 && word.first!.isLetter
    }
}

/// Minimal energy-based voice activity detector for PCM16 audio. Used in
/// streaming transcription mode, where the server does no turn detection and the
/// client must say when an utterance has ended.
struct SilenceDetector {
    /// RMS level (0…32767) above which a chunk counts as speech.
    var speechThreshold: Double
    /// Silence after speech that ends the utterance.
    var silenceToEnd: TimeInterval = 0.6
    /// Force an utterance end after this much continuous audio (bounds the server buffer).
    var maxUtterance: TimeInterval = 40
    var sampleRate: Double = 24_000

    private var heardSpeech = false
    private var silence: TimeInterval = 0
    private var utterance: TimeInterval = 0

    init(speechThreshold: Double) { self.speechThreshold = speechThreshold }

    /// Feed one PCM16 mono chunk. Returns true when the utterance just ended.
    mutating func process(_ pcm16: Data) -> Bool {
        let samples = pcm16.count / 2
        guard samples > 0 else { return false }
        let duration = Double(samples) / sampleRate
        let rms = Self.rms(pcm16)

        if rms >= speechThreshold {
            heardSpeech = true
            silence = 0
        } else if heardSpeech {
            silence += duration
        }
        guard heardSpeech else { return false }
        utterance += duration

        if silence >= silenceToEnd || utterance >= maxUtterance {
            heardSpeech = false
            silence = 0
            utterance = 0
            return true
        }
        return false
    }

    static func rms(_ pcm16: Data) -> Double {
        let count = pcm16.count / 2
        guard count > 0 else { return 0 }
        var sum = 0.0
        pcm16.withUnsafeBytes { raw in
            for i in 0..<count {
                let s = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)))
                sum += s * s
            }
        }
        return (sum / Double(count)).squareRoot()
    }
}

/// Matches translated sentences from the simultaneous-translation stream to the
/// English transcript lines they belong to.
///
/// The two streams come from different models and carry no shared ids, so this
/// is a best-effort FIFO: a translation goes to the oldest line still waiting
/// for one; a translation that arrives before its line waits for that line.
/// Stale entries are dropped so one mismatch cannot shift everything after it.
struct TranslationPairer {
    struct Attachment: Equatable {
        let lineID: UUID
        let text: String
    }

    /// A line waits this long for its translation before it is given up on.
    var lineTimeout: TimeInterval = 12
    /// An extra translated sentence within this time joins the previous line.
    var appendWindow: TimeInterval = 5

    private var waitingLines: [(id: UUID, at: Date)] = []
    private var waitingTexts: [(text: String, at: Date)] = []
    private var lastPaired: (id: UUID, at: Date)?

    /// A new English line was committed.
    mutating func lineCommitted(_ id: UUID, now: Date = Date()) -> [Attachment] {
        prune(now)
        guard !waitingTexts.isEmpty else {
            waitingLines.append((id, now))
            return []
        }
        // Translations that arrived first all belong to this line.
        let text = waitingTexts.map(\.text).joined(separator: " ")
        waitingTexts.removeAll()
        lastPaired = (id, now)
        return [Attachment(lineID: id, text: text)]
    }

    /// A translated sentence arrived.
    mutating func translationArrived(_ text: String, now: Date = Date()) -> Attachment? {
        prune(now)
        if !waitingLines.isEmpty {
            let line = waitingLines.removeFirst()
            lastPaired = (line.id, now)
            return Attachment(lineID: line.id, text: text)
        }
        if let last = lastPaired, now.timeIntervalSince(last.at) <= appendWindow {
            lastPaired = (last.id, now)
            return Attachment(lineID: last.id, text: text)
        }
        waitingTexts.append((text, now))
        return nil
    }

    mutating func reset() {
        waitingLines.removeAll()
        waitingTexts.removeAll()
        lastPaired = nil
    }

    private mutating func prune(_ now: Date) {
        waitingLines.removeAll { now.timeIntervalSince($0.at) > lineTimeout }
        waitingTexts.removeAll { now.timeIntervalSince($0.at) > lineTimeout }
    }
}
