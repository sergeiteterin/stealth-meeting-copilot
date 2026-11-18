import SwiftUI
import AppKit

/// Settings: OpenAI key (→ Keychain), feature switches, meeting profile, text
/// size, models, shortcuts.
struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var hotkeys: HotkeyStore
    @ObservedObject var settings: AppSettings
    @ObservedObject var profiles: ProfileStore
    @State private var apiKeyField: String = ""
    @State private var savedFlash = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.hotkeys = coordinator.hotkeys
        self.settings = coordinator.settings
        self.profiles = coordinator.profiles
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Настройки")
                        .font(.title3.bold())
                    Spacer()
                    Text(AppInfo.display)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                apiKeySection
                Divider()
                featureSection
                Divider()
                profileSection
                Divider()
                exportSection
                Divider()
                appearanceSection
                Divider()
                modelSection
                Divider()
                shortcutSection

                Text("Звук встречи и микрофона передаётся в OpenAI только между «Старт» и «Стоп». Аудио не сохраняется; текст разговора хранится локально в ~/Library/Application Support/Stealth.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .frame(width: 460, height: 700)
    }

    // MARK: - Sections

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Ключ OpenAI API")
            SecureField("sk-…", text: $apiKeyField)
                .textFieldStyle(.roundedBorder)
            Text(coordinator.hasAPIKey
                 ? "Ключ сохранён в Связке ключей macOS."
                 : "Ключ не сохранён. Без него приложение не подключится.")
                .font(.caption)
                .foregroundStyle(coordinator.hasAPIKey ? .green : .secondary)
            HStack {
                Button("Сохранить ключ") {
                    let trimmed = apiKeyField.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    KeychainStore.save(trimmed)
                    apiKeyField = ""
                    coordinator.refreshKeyState()
                    savedFlash = true
                }
                .keyboardShortcut(.defaultAction)

                if coordinator.hasAPIKey {
                    Button("Удалить") {
                        KeychainStore.clear()
                        coordinator.refreshKeyState()
                        savedFlash = false
                    }
                }
                if savedFlash {
                    Text("Сохранено ✓").font(.caption).foregroundStyle(.green)
                }
            }
        }
    }

    private var featureSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Функции")
            Toggle("Перевод реплик собеседника на русский", isOn: $settings.translationEnabled)
            Toggle("Синхронный перевод (текст идёт, пока собеседник говорит)", isOn: $settings.syncTranslation)
                .disabled(!settings.translationEnabled)
                .help("Отдельная модель перевода со звука, около $2 в час дополнительно. Если недоступна — перевод по предложениям. Вступает в силу со следующего «Старт».")
            Toggle("Переводить и мою речь", isOn: $settings.translateOwnSpeech)
                .disabled(!settings.translationEnabled)
            Toggle("Автоматически подсказывать ответ на вопрос", isOn: $settings.autoSuggestEnabled)
            Toggle("Писать резюме и письмо после встречи", isOn: $settings.autoSummary)
            Toggle("Скрывать окно при демонстрации экрана", isOn: $settings.hideFromScreenShare)
            Toggle("Передача аудио в OpenAI разрешена", isOn: $settings.audioConsentGiven)
                .help("Если выключить, перед следующим «Старт» приложение снова спросит разрешение.")
            HStack {
                Text("Тон ответов")
                Picker("", selection: $coordinator.tone) {
                    ForEach(ReplyTone.allCases) { tone in
                        Text(tone.label).tag(tone)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .font(.callout)
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Профиль встречи")
            Picker("", selection: $settings.selectedProfileID) {
                ForEach(profiles.profiles) { profile in
                    Text(profile.title).tag(profile.id)
                }
            }
            .labelsHidden()
            HStack {
                Button("Редактировать…") {
                    if let current = profiles.profile(id: settings.selectedProfileID) {
                        NSWorkspace.shared.open(current.url)
                    }
                }
                .disabled(profiles.profile(id: settings.selectedProfileID) == nil)
                Button("Новый…") {
                    if let created = profiles.createProfile() {
                        settings.selectedProfileID = created.id
                        NSWorkspace.shared.open(created.url)
                    }
                }
                Button("Папка") { NSWorkspace.shared.open(profiles.directory) }
                Button("Обновить") { profiles.reload() }
            }
            Text("Профиль — обычный Markdown-файл: компания, цели, факты, термины, вопросы. Правки применяются сразу.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { profiles.reload() }
    }

    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Папка для заметок о встречах")
            HStack {
                Text(settings.exportFolder.isEmpty ? "Не выбрана — заметки хранятся только в Истории" : settings.exportFolder)
                    .font(.caption)
                    .foregroundStyle(settings.exportFolder.isEmpty ? .secondary : .primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer()
                Button("Выбрать…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.prompt = "Выбрать"
                    if !settings.exportFolder.isEmpty {
                        panel.directoryURL = URL(fileURLWithPath: settings.exportFolder)
                    }
                    if panel.runModal() == .OK, let url = panel.url { settings.exportFolder = url.path }
                }
                if !settings.exportFolder.isEmpty {
                    Button("Отключить") { settings.exportFolder = "" }
                }
            }
            Text("После «Стоп» сюда кладётся Markdown-заметка: расшифровка, перевод и резюме. История в приложении сохраняется как раньше.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Размер текста в окне")
            HStack {
                Image(systemName: "textformat.size.smaller")
                Slider(value: $settings.fontScale, in: AppSettings.fontScaleRange, step: 0.1)
                Image(systemName: "textformat.size.larger")
                Text("\(Int((settings.fontScale * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Модели OpenAI")
            ForEach(Config.ModelKey.allCases, id: \.rawValue) { key in
                HStack {
                    Text(key.label)
                        .font(.caption)
                        .frame(width: 130, alignment: .leading)
                    ModelField(key: key)
                }
            }
            Text("Пустое поле — модель по умолчанию. Меняйте, только если OpenAI отключил модель. Вступает в силу со следующего «Старт».")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcutSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Горячие клавиши")
            ForEach(SuggestionMode.allCases) { mode in
                HStack {
                    Label(mode.label, systemImage: mode.systemImage)
                        .font(.caption)
                        .frame(width: 130, alignment: .leading)
                    KeyRecorderView(combo: hotkeys.combo(for: mode)) { combo in
                        coordinator.updateHotkey(combo, for: mode)
                    }
                    .frame(width: 110, height: 22)
                    Button {
                        coordinator.resetHotkey(mode)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Вернуть по умолчанию")
                }
            }
            Label("⌥H — показать / скрыть окно", systemImage: "eye.slash")
                .font(.caption).foregroundStyle(.tertiary)
            Text("Щёлкните поле и нажмите модификатор + клавишу (например ⌥R). Esc — отмена.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold))
    }
}

/// One editable model name, stored straight in `UserDefaults` (read by `Config.model`).
private struct ModelField: View {
    let key: Config.ModelKey
    @State private var text: String

    init(key: Config.ModelKey) {
        self.key = key
        _text = State(initialValue: UserDefaults.standard.string(forKey: key.rawValue) ?? "")
    }

    var body: some View {
        TextField(key.defaultValue, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospaced())
            .autocorrectionDisabled()
            .onChange(of: text) { _, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    UserDefaults.standard.removeObject(forKey: key.rawValue)
                } else {
                    UserDefaults.standard.set(trimmed, forKey: key.rawValue)
                }
            }
    }
}
