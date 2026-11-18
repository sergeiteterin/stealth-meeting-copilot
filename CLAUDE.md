# Stealth

Native macOS meeting copilot (fork of vortechron/stealth). Captures meeting audio, live-transcribes both sides in English, translates each line to Russian, auto-detects the other side's questions and suggests a short B1–B2 English reply grounded in a Markdown meeting profile. The user is a Russian speaker; UI strings are Russian.

**Status:** in daily testing by the owner. Streaming transcription, simultaneous translation (Russian accepted by `gpt-realtime-translate`), per-sentence translation, summaries and note export have run against the live API. Goal assessment, the cost meter's accuracy and hour-long stability have NOT been verified live.

Tests: `xcodebuild -project Stealth.xcodeproj -scheme Stealth -derivedDataPath build test` (logic only, no network). Demo UI without a key: `open /Applications/Stealth.app --args -demo YES` (add `-snapshotDir <dir>` to dump window PNGs — the overlay is excluded from screenshots, so this is the only way to see it from the terminal). If `xcode-select` points at CommandLineTools, prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

**Do not rebuild or relaunch casually.** Every rebuild changes the binary's cdhash; the keychain ACL of the API key is cdhash-bound (the local signing cert is not system-trusted), so the next key read shows a blocking macOS password prompt. The key is therefore read only on Start (`KeychainStore.exists()` at launch never prompts). Killing a process that is waiting on that prompt leaves an orphan dialog on the user's screen.

## Run / build

```bash
cd StealthApp
sudo ./setup-signing.sh   # ONCE only — creates stable signing cert (see Signing below)
./run.sh                  # build + sign + install to /Applications + launch
```

`run.sh` stamps a fresh build number (`YYYYMMDD.HHMM` in `CFBundleVersion`), regenerates the Xcode project, builds **Release**, signs, installs to `/Applications/Stealth.app`, and launches. The build number shows in the UI (menu bar, overlay footer, settings) — use it to confirm the running app reflects your latest code.

- **App is a menu-bar agent** (`LSUIElement`) — no dock icon. Look for the waveform icon top-right.
- **Debug log:** `~/Library/Logs/Stealth/stealth.log` (OSLog wasn't surfacing reliably; `DebugLog` writes here — invaluable for diagnosis).

## Architecture

Two audio sources, each with its own OpenAI Realtime transcription session:

```
System audio (ScreenCaptureKit)  → RealtimeClient(speaker: .them) ─┐
Microphone   (AVAudioEngine+AEC)  → RealtimeClient(speaker: .you)  ─┤
                                                                    ├→ TranscriptStore (speaker-labelled, timestamped)
System audio also → LiveTranslationClient (gpt-realtime-translate) → Russian sentences → TranscriptStore.translatedStream
  (fallback: each finished line → TextLLMClient (chat completions, SSE) → RU translation streamed into the line)
Them question (QuestionDetector, local, 8 s cool-down) or ⌥Space → TextLLMClient + profile Markdown + goal statuses → SuggestionStore
Every 25 s → TextLLMClient goal check → GoalStore (checklist)      On Stop → summary → SessionStore + NoteExporter (notes folder)
```

- `AppCoordinator` (`Sources/Stealth/Stores/`) wires everything; the single source of truth for app state.
- `RealtimeClient` is **per-speaker** and transcription-only; it auto-reconnects with back-off on unexpected drops. Suggestions and translation use the text API, never the Realtime socket.
- Mic uses **acoustic echo cancellation** (`setVoiceProcessingEnabled(true)`) so speaker audio bleeding into the mic isn't mislabeled "You".
- Overlay is an `NSPanel` with `sharingType = .none` → **invisible to screen capture/sharing** (the "stealth"). Floating, all Spaces, draggable, resizable (bottom-right handle).

### File map
- `Support/Config.swift` — all tuning knobs (model, sample rate, VAD ms, limits, prompt).
- `Support/KeychainStore.swift` — OpenAI key in macOS Keychain (never on disk).
- `Support/AppInfo.swift` — reads version/build from bundle.
- `Support/DebugLog.swift` — file logger.
- `Audio/AudioCaptureManager.swift` — system audio via ScreenCaptureKit → 24kHz PCM16.
- `Audio/MicCaptureManager.swift` — mic via AVAudioEngine + AEC → 24kHz PCM16.
- `Realtime/RealtimeClient.swift` — one WebSocket session (transcription only, auto-reconnect).
- `LLM/TextLLMClient.swift` + `SSEParser.swift` — streaming text API for translation and suggestions.
- `LLM/QuestionDetector.swift` — local heuristic that triggers auto-suggestions.
- `Context/ProfileStore.swift` — meeting profiles as Markdown in `~/Library/Application Support/Stealth/profiles/` (seeded once from `Resources/Profiles/`).
- `Support/AppSettings.swift` — user switches (translation, auto-suggest, font scale, profile, consent).
- `Support/DemoMode.swift` — `-demo YES` sample data + window snapshots.
- `Realtime/LiveTranslationClient.swift` — simultaneous translation socket (`/v1/realtime/translations`); translated audio is discarded.
- `LLM/SentenceSegmenter.swift` — cuts a text stream into sentences; `SilenceDetector` (client VAD for streaming mode); `TranslationPairer` (RU sentence ↔ EN line, feed layout only).
- `Context/GoalStore.swift` — goals parsed from the profile's "Meeting goals" section + statuses.
- `Stores/NoteExporter.swift` — Markdown note with YAML front matter into a user-chosen folder.
- `Support/CostMeter.swift` — session cost estimate; **price tables live here** and need updating when OpenAI changes prices.
- `Stores/TranscriptStore.swift` — `[TranscriptLine{speaker,at,content}]` + per-speaker partials.
- `Stores/SuggestionStore.swift` — latest suggested reply + loading/error.
- `Stores/AppCoordinator.swift` — pipeline wiring + lifecycle.
- `Overlay/OverlayWindow.swift` — the stealth NSPanel.
- `Overlay/OverlayView.swift` — SwiftUI: scrollable transcript + suggestion card + resize handle.
- `Hotkeys/HotkeyManager.swift` — global Carbon hotkeys.
- `Settings/SettingsView.swift` — API key entry + tone toggle.
- `StealthApp.swift` — `@main`, MenuBarExtra + AppDelegate (owns overlay, hotkeys, settings window).

## Locked design decisions

- **Native Swift/SwiftUI**, NOT Electron (ScreenCaptureKit + stealth overlay are hard in web stacks).
- **No backend** — app calls OpenAI directly. Laravel + Laravel Boost deferred to Phase 2 (needed for hiding the API key when distributing).
- **OpenAI Realtime API (GA)** over WebSocket. Default transcription: `gpt-live-transcribe` on `?intent=transcription` (session type `transcription`, no server VAD — the client commits on silence). Fallback: `gpt-realtime` session with `gpt-4o-transcribe` and server VAD (the upstream path; gotchas 1–3 below apply to it).
- **API key in Keychain**, direct connection. **This is a personal build — never distribute it** (the key would leak).
- Suggestions fire **automatically on a detected question** and manually on ⌥Space. ⌥H = show/hide overlay.
- **Audio consent**: nothing is streamed until the user accepts the one-time alert (`AppSettings.audioConsentGiven`).
- Model names are user-overridable (`Config.ModelKey`, Settings) because OpenAI retires models.
- **Two-sided transcript**: mic (You, blue) + system (Them, green), each timestamped (HH:mm).

## Critical gotchas (all hit during first live bring-up — don't regress these)

1. **Realtime API is GA, not beta.** Model `gpt-realtime` (NOT `gpt-4o-realtime-preview`). NO `OpenAI-Beta` header. Session schema is nested: `session.audio.input.{format:{type:"audio/pcm",rate:24000}, transcription, turn_detection}`. Response uses `output_modalities` (not `modalities`). Text deltas arrive as `response.output_text.delta`.
2. **"Socket is not connected" had two causes:** (a) calling `receive()` before the WS opens → start the receive loop only from `didOpenWithProtocol`; (b) VAD disabled meant the audio buffer was never committed, so the server closed the idle socket (~30s). Fix: `server_vad` with `create_response: false` — auto-commits (→ transcription fires) but never auto-replies. On intentional `disconnect()`, an `isClosing` flag suppresses the expected receive failure.
3. **VAD silence = 700ms** (`Config.vadSilenceMs`). Was 200ms ("snappy"), but that fragmented continuous speech — natural sub-second pauses between words triggered mid-sentence commits and **clipped/dropped boundary words** (seen on YouTube/system audio). 700ms waits for a real sentence pause; `prefix_padding_ms = 500` keeps lead-in so the first word isn't clipped. Transcription is still **sentence-chunked, not word-by-word** — that's `gpt-4o-transcribe` behavior. True live word streaming needs a different model.
4. **Echo:** speaker output bleeds into the mic and gets labeled "You". Mitigated by mic AEC. Residual leakage may still occur with loud speakers — options: raise mic VAD threshold, or add a mic-mute toggle.
5. **Don't double-commit transcript lines.** On `transcription.completed`, `clearPartial(speaker)` then `commit(line)` — committing the partial too duplicates the line.

## Signing (why permissions used to keep resetting)

macOS ties Screen Recording / Microphone TCC grants to the app's **code signature (cdhash)**. Ad-hoc re-signing changes the cdhash every build → grant orphaned → re-prompts forever. Fixed with a **stable self-signed cert** "Stealth Local Signing" (login keychain, trusted for codeSign) created by `setup-signing.sh`, plus install to a fixed `/Applications` path and **Release** config (single binary — Debug's separate `Stealth.debug.dylib` broke re-signing). Grant Screen Recording + Microphone **once** and it sticks across rebuilds.

App Sandbox is **OFF** for the MVP (entitlements in `Resources/Stealth.entitlements`: network client, audio input). Re-enable sandbox in Phase 2 for distribution.

## Permissions required (granted once)

- **Screen & System Audio Recording** — ScreenCaptureKit needs it even for audio-only.
- **Microphone** — for the "You" transcript side.

Both prompt the first time you click **Start Listening**. If a grant seems ignored, quit + relaunch (TCC sometimes needs an app restart).

## Roadmap (next phases)

- Phase 2: Laravel backend (hide API key via ephemeral tokens, meeting history, auth) → enables distribution.
- Auto question-detection (currently manual hotkey only).
- Live word-by-word transcription (streaming model).
- Comprehension/"what they're asking" layer (currently reply-only).
