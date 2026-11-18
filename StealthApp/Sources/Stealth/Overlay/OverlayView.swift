import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The compact always-on-top card:
///  - status + Start/Stop + meeting profile
///  - live transcript: English line with its Russian translation underneath
///  - the suggested English reply (auto on a detected question, or on hotkey)
struct OverlayView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var transcript: TranscriptStore
    @ObservedObject var suggestion: SuggestionStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var profiles: ProfileStore
    @ObservedObject var goals: GoalStore

    /// Window size captured at the start of a resize drag (cumulative-translation baseline).
    @State private var lastDragSize: CGSize?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.transcript = coordinator.transcript
        self.suggestion = coordinator.suggestion
        self.settings = coordinator.settings
        self.profiles = coordinator.profiles
        self.goals = coordinator.goals
    }

    /// Scaled font size (Settings → text size, or A− / A+ in the toolbar).
    private func fs(_ base: CGFloat) -> CGFloat { base * settings.fontScale }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            dragGrip
            header
            toolbar
            if !goals.goals.isEmpty { goalChecklist }
            if settings.captionMode { captionZones } else { transcriptStrip }            // expands to fill available height
            Divider().overlay(Color.white.opacity(0.12))
            suggestionCard
            footer
        }
        .padding(12)
        // Fill the whole (resizable) window instead of a fixed size.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .overlay(alignment: .bottomTrailing) { resizeHandle }
    }

    /// Full-width strip at the top: grab it to move the window.
    private var dragGrip: some View {
        WindowDragArea()
            .frame(maxWidth: .infinity)
            .frame(height: 12)
            .overlay(
                Capsule().fill(Color.secondary.opacity(0.45)).frame(width: 44, height: 4)
                    .allowsHitTesting(false)
            )
            .padding(.top, -4)
            .help("Потяните, чтобы переместить окно")
    }

    // MARK: - Header: status, Start/Stop, profile

    private var statusColor: Color {
        switch coordinator.connection {
        case .idle: return .gray
        case .connecting, .reconnecting: return .yellow
        case .live: return .red
        case .failed: return .orange
        }
    }

    private var statusLabel: String {
        switch coordinator.connection {
        case .idle: return "Не слушаю"
        case .connecting: return "Подключение…"
        case .reconnecting: return "Переподключение…"
        case .live: return "Запись → OpenAI"
        case .failed: return "Ошибка"
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                Task { await coordinator.toggle() }
            } label: {
                Label(coordinator.isRunning ? "Стоп" : "Старт",
                      systemImage: coordinator.isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(coordinator.isRunning ? Color.red.opacity(0.75) : Color.green.opacity(0.7))
                    )
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(!coordinator.hasAPIKey)
            .help(coordinator.hasAPIKey
                  ? (coordinator.isRunning ? "Остановить и сохранить разговор" : "Начать слушать встречу")
                  : "Сначала сохраните API-ключ в Настройках")

            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help(coordinator.statusMessage)

            Spacer(minLength: 4)

            profileMenu
        }
    }

    private var profileMenu: some View {
        Menu {
            ForEach(profiles.profiles) { profile in
                Button {
                    settings.selectedProfileID = profile.id
                } label: {
                    if profile.id == settings.selectedProfileID {
                        Label(profile.title, systemImage: "checkmark")
                    } else {
                        Text(profile.title)
                    }
                }
            }
            Divider()
            if let current = profiles.profile(id: settings.selectedProfileID) {
                Button("Редактировать «\(current.title)»…") { NSWorkspace.shared.open(current.url) }
            }
            Button("Новый профиль…") {
                if let created = profiles.createProfile() {
                    settings.selectedProfileID = created.id
                    NSWorkspace.shared.open(created.url)
                }
            }
            Button("Открыть папку профилей") { NSWorkspace.shared.open(profiles.directory) }
            Button("Обновить список") { profiles.reload(); coordinator.reloadGoals() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "doc.text")
                Text(profiles.profile(id: settings.selectedProfileID)?.title ?? "Профиль не выбран")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 190, alignment: .trailing)
        .help("Профиль встречи — контекст для подсказок")
    }

    // MARK: - Toolbar: toggles, text size, save

    private var toolbar: some View {
        HStack(spacing: 6) {
            toggleChip("Перевод", systemImage: "character.bubble", isOn: settings.translationEnabled,
                       help: "Перевод реплик на русский") {
                settings.translationEnabled.toggle()
            }
            toggleChip("Подсказки", systemImage: "sparkles", isOn: settings.autoSuggestEnabled,
                       help: "Автоматически предлагать ответ на вопрос собеседника") {
                settings.autoSuggestEnabled.toggle()
            }
            toggleChip("Микрофон", systemImage: coordinator.micEnabled ? "mic.fill" : "mic.slash.fill",
                       isOn: coordinator.micEnabled,
                       help: "Распознавать мою речь (микрофон)") {
                coordinator.toggleMic()
            }

            Spacer(minLength: 2)

            iconButton(settings.captionMode ? "list.bullet" : "captions.bubble",
                       help: settings.captionMode ? "Показать ленту реплик" : "Показать субтитры (две зоны)") {
                settings.captionMode.toggle()
            }
            iconButton("arrow.up.arrow.down", help: "Поменять: какой язык крупнее") {
                settings.russianPrimary.toggle()
            }
            iconButton("textformat.size.smaller", help: "Уменьшить текст") { settings.bumpFontScale(by: -0.1) }
            iconButton("textformat.size.larger", help: "Увеличить текст") { settings.bumpFontScale(by: 0.1) }
            iconButton("square.and.arrow.down", help: "Сохранить разговор в файл…") { exportTranscript() }
                .disabled(transcript.lines.isEmpty)
        }
    }

    private func toggleChip(_ title: String, systemImage: String, isOn: Bool, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(isOn ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.08))
                )
                .foregroundStyle(isOn ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(help + (isOn ? " — включено" : " — выключено"))
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }

    /// Save the transcript shown in the overlay as a Markdown file the user picks.
    private func exportTranscript() {
        let record = SessionRecord(
            startedAt: transcript.lines.first?.at ?? Date(),
            endedAt: transcript.lines.last?.at ?? Date(),
            lines: transcript.lines.map(SessionLine.init(from:)),
            profile: profiles.profile(id: settings.selectedProfileID)?.title
        )
        TranscriptExporter.export(record)
    }

    // MARK: - Goal checklist

    private var goalChecklist: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                settings.goalsExpanded.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "target")
                    Text("Цели \(goals.doneCount)/\(goals.goals.count)")
                        .font(.system(size: fs(10), weight: .bold))
                    // Collapsed: one dot per goal, so progress is visible at a glance.
                    if !settings.goalsExpanded {
                        ForEach(goals.goals) { goal in
                            Circle().fill(goalColor(goal.status)).frame(width: 6, height: 6)
                        }
                    }
                    Spacer()
                    Image(systemName: settings.goalsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: fs(10)))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Цели из раздела «Meeting goals» профиля. Отмечаются автоматически по ходу разговора; щёлкните цель, чтобы отметить вручную.")

            if settings.goalsExpanded {
                ForEach(goals.goals) { goal in
                    Button {
                        goals.toggle(goal.id)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: goalIcon(goal.status))
                                .foregroundStyle(goalColor(goal.status))
                                .font(.system(size: fs(11)))
                            VStack(alignment: .leading, spacing: 0) {
                                Text(goal.text)
                                    .font(.system(size: fs(11)))
                                    .foregroundStyle(goal.status == .done ? .tertiary : .primary)
                                    .strikethrough(goal.status == .done, color: .secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                if !goal.note.isEmpty {
                                    Text(goal.note)
                                        .font(.system(size: fs(9)))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private func goalIcon(_ status: MeetingGoal.Status) -> String {
        switch status {
        case .open: return "circle"
        case .progress: return "circle.lefthalf.filled"
        case .done: return "checkmark.circle.fill"
        }
    }

    private func goalColor(_ status: MeetingGoal.Status) -> Color {
        switch status {
        case .open: return .gray
        case .progress: return .yellow
        case .done: return .green
        }
    }

    // MARK: - Subtitles: one calm zone per language

    /// What the other side said, as one flowing English text (finished
    /// sentences + the one being spoken).
    private var englishCaption: (settled: String, live: String) {
        let lines = transcript.lines.filter { $0.speaker == .them }.suffix(8).map(\.content)
        return captionParts(lines, partial: transcript.partialThem)
    }

    /// The same in Russian. In simultaneous mode it is the translation stream
    /// itself; otherwise the translations of the finished lines.
    private var russianCaption: (settled: String, live: String) {
        let sentences: [String]
        if !transcript.translatedStream.isEmpty {
            sentences = Array(transcript.translatedStream.suffix(8))
        } else {
            sentences = transcript.lines
                .filter { $0.speaker == .them && !$0.translation.isEmpty }
                .suffix(8).map(\.translation)
        }
        return captionParts(sentences, partial: transcript.partialTranslation)
    }

    /// Older sentences are shown dimmer ("settled"); the newest one plus the
    /// unfinished tail is the part being read right now ("live").
    private func captionParts(_ sentences: [String], partial: String) -> (settled: String, live: String) {
        var sentences = sentences
        var live = partial
        if live.isEmpty, let last = sentences.popLast() { live = last }
        else if let last = sentences.popLast() { live = last + " " + live }
        return (sentences.joined(separator: " "), live)
    }

    private var captionZones: some View {
        let en = englishCaption
        let ru = russianCaption
        let enBig = !settings.russianPrimary
        // Fixed split: the larger language gets a bit more room, and neither
        // zone resizes while text streams in.
        return GeometryReader { geo in
            let showRU = settings.translationEnabled
            let total = max(0, geo.size.height - (showRU ? 9 : 0))
            let enShare: CGFloat = showRU ? (enBig ? 0.56 : 0.44) : 1
            VStack(alignment: .leading, spacing: 4) {
                captionZone(label: "EN", accent: .green, parts: en, big: enBig,
                            placeholder: coordinator.isRunning ? "Жду речь…" : emptyHint)
                    .frame(height: total * enShare)
                if showRU {
                    Divider().overlay(Color.white.opacity(0.08))
                    captionZone(label: "RU", accent: .orange, parts: ru, big: !enBig,
                                placeholder: coordinator.isRunning ? "Перевод появится здесь" : "")
                        .frame(height: total * (1 - enShare))
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
    }

    /// A fixed-height zone that always shows the END of its text: new words
    /// appear at the bottom, old lines leave at the top, nothing else moves.
    private func captionZone(label: String, accent: Color, parts: (settled: String, live: String),
                             big: Bool, placeholder: String) -> some View {
        let size = big ? fs(16) : fs(12)
        let isEmpty = parts.settled.isEmpty && parts.live.isEmpty
        return HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(accent)
                .padding(.top, 3)
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    if isEmpty {
                        Text(placeholder).foregroundStyle(.secondary)
                    } else {
                        (Text(parts.settled.isEmpty ? "" : parts.settled + " ").foregroundStyle(.tertiary)
                         + Text(parts.live).foregroundStyle(.primary))
                    }
                }
                .font(.system(size: size, weight: big ? .medium : .regular))
                .lineSpacing(big ? 3 : 2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    // MARK: - Transcript

    /// Scrollable, speaker-labelled transcript (original + translation) that auto-scrolls.
    private var transcriptStrip: some View {
        let lines = Array(transcript.lines.suffix(Config.overlayVisibleLines))
        let pThem = transcript.partialThem
        let pYou = transcript.partialYou
        let pRu = transcript.partialTranslation
        let isEmpty = lines.isEmpty && pThem.isEmpty && pYou.isEmpty && pRu.isEmpty

        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if isEmpty {
                        Text(coordinator.isRunning ? "Жду речь…" : emptyHint)
                            .font(.system(size: fs(12)))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(lines) { line in
                            transcriptRow(speaker: line.speaker, clock: line.clock,
                                          text: line.content, translation: line.translation, dim: false)
                        }
                        // In-progress lines, dimmer, no timestamp yet.
                        if !pYou.isEmpty {
                            transcriptRow(speaker: .you, clock: nil, text: pYou, translation: "", dim: true)
                        }
                        if !pThem.isEmpty || !pRu.isEmpty {
                            transcriptRow(speaker: .them, clock: nil, text: pThem, translation: pRu, dim: true)
                        }
                    }
                    Color.clear.frame(height: 1).id(scrollAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Expand to fill the window's available height (min 80 so it stays usable).
            .frame(maxWidth: .infinity, minHeight: 80, maxHeight: .infinity, alignment: .leading)
            .onChange(of: transcript.lines) { _, _ in scrollToBottom(proxy) }
            .onChange(of: pThem) { _, _ in scrollToBottom(proxy) }
            .onChange(of: pYou) { _, _ in scrollToBottom(proxy) }
            .onChange(of: pRu) { _, _ in scrollToBottom(proxy) }
            .onAppear { scrollToBottom(proxy) }
        }
    }

    private var emptyHint: String {
        coordinator.hasAPIKey
            ? "Нажмите «Старт», когда встреча началась."
            : "Откройте Настройки (значок в строке меню) и сохраните ключ OpenAI API."
    }

    @ViewBuilder
    private func transcriptRow(speaker: Speaker, clock: String?, text: String,
                               translation: String, dim: Bool) -> some View {
        let accent: Color = speaker == .you ? .blue : .green
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(speaker == .you ? "Я" : "Собеседник")
                    .font(.system(size: fs(9), weight: .bold))
                    .foregroundStyle(accent)
                if let clock {
                    Text(clock)
                        .font(.system(size: fs(9)))
                        .foregroundStyle(.tertiary)
                }
            }
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: settings.russianPrimary ? fs(12) : fs(14)))
                    .foregroundStyle(settings.russianPrimary ? (dim ? .tertiary : .secondary) : (dim ? .secondary : .primary))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !translation.isEmpty {
                Text(translation)
                    .font(.system(size: settings.russianPrimary ? fs(14) : fs(11.5),
                                  weight: settings.russianPrimary ? .medium : .regular))
                    .foregroundStyle(settings.russianPrimary ? (dim ? .secondary : .primary) : .secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private let scrollAnchor = "transcript-bottom"

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        proxy.scrollTo(scrollAnchor, anchor: .bottom)
    }

    // MARK: - Suggestion

    private var suggestionCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Label(suggestion.isAuto ? "\(suggestion.mode.label) · авто" : suggestion.mode.label,
                      systemImage: suggestion.mode.systemImage)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                Spacer()
                ForEach(SuggestionMode.allCases) { mode in
                    Button {
                        coordinator.requestSuggestion(mode: mode)
                    } label: {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 10))
                            .frame(width: 22, height: 18)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("\(mode.label) — \(coordinator.hotkeys.combo(for: mode).display)")
                    .disabled(transcript.lines.isEmpty)
                }
                if !suggestion.text.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(suggestion.reply, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 10)).frame(width: 22, height: 18)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Скопировать")
                }
            }
            Group {
                if let error = suggestion.error {
                    Text(error)
                        .font(.system(size: fs(12)))
                        .foregroundStyle(.red)
                } else if suggestion.isLoading && suggestion.text.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Думаю…").font(.system(size: fs(12))).foregroundStyle(.secondary)
                    }
                } else if suggestion.text.isEmpty {
                    Text("Ответ появится после вопроса собеседника или по \(coordinator.hotkeys.combo(for: .reply).display).")
                        .font(.system(size: fs(12)))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(suggestion.reply)
                            .font(.system(size: fs(15), weight: .medium))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        if !suggestion.translation.isEmpty {
                            Text(suggestion.translation)
                                .font(.system(size: fs(11)))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !suggestion.note.isEmpty, suggestion.mode != .recap {
                            Label(suggestion.note, systemImage: "target")
                                .font(.system(size: fs(10), weight: .medium))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(coordinator.statusMessage)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if coordinator.cost.totalUSD > 0 || coordinator.isRunning {
                Text(coordinator.cost.label)
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(coordinator.cost.breakdown)
                Text("·")
            }
            Text("⌥H скрыть · \(AppInfo.display)")
                .lineLimit(1)
                .padding(.trailing, 14)   // keep clear of the resize handle
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
    }

    // MARK: - Resize

    /// Bottom-right drag handle that resizes the window (borderless panels hide
    /// the native grip). Dragging changes the window's frame live.
    private var resizeHandle: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.tertiary)
            .padding(5)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .global)
                    .onChanged { value in resizeWindow(translation: value.translation) }
                    .onEnded { _ in lastDragSize = nil }
            )
            .help("Потяните, чтобы изменить размер")
    }

    private func resizeWindow(translation: CGSize) {
        guard let window = NSApp.windows.first(where: { $0 is OverlayWindow }) else { return }
        // Capture the size once at drag start; translation is cumulative from there.
        if lastDragSize == nil { lastDragSize = window.frame.size }
        let start = lastDragSize!

        let minS = window.minSize, maxS = window.maxSize
        let newW = min(max(start.width + translation.width, minS.width), maxS.width)
        let newH = min(max(start.height - translation.height, minS.height), maxS.height)

        var frame = window.frame
        // Keep the top-left anchored while the bottom-right corner moves.
        frame.origin.y += frame.size.height - newH
        frame.size = NSSize(width: newW, height: newH)
        window.setFrame(frame, display: true)
    }
}

/// Saves a session as Markdown through a standard Save panel (explicit export —
/// nothing leaves the app's own storage otherwise).
@MainActor
enum TranscriptExporter {
    static func export(_ record: SessionRecord) {
        let panel = NSSavePanel()
        panel.title = "Сохранить разговор"
        panel.nameFieldStringValue = record.suggestedFileName
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        // Above the floating overlay, or the panel would open hidden behind it.
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try record.markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            DebugLog.log("export failed: \(error.localizedDescription)")
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }
}

/// An AppKit view that moves its window when dragged. SwiftUI controls and the
/// scroll view swallow mouse-downs, so `isMovableByWindowBackground` alone
/// leaves almost nothing to grab.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}
