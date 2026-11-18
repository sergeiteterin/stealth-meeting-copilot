import SwiftUI
import AppKit
import Combine

@main
struct StealthApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu-bar only — no dock icon (LSUIElement in Info.plist).
        MenuBarExtra("Stealth", systemImage: appDelegate.coordinator.isRunning ? "waveform" : "waveform.slash") {
            MenuContent(coordinator: appDelegate.coordinator,
                        openSettings: appDelegate.openSettings,
                        openHistory: appDelegate.openHistory,
                        toggleOverlay: appDelegate.toggleOverlay)
        }
    }
}

/// The menu-bar dropdown.
private struct MenuContent: View {
    @ObservedObject var coordinator: AppCoordinator
    let openSettings: () -> Void
    let openHistory: () -> Void
    let toggleOverlay: () -> Void

    var body: some View {
        Text(coordinator.statusMessage)
            .font(.caption)

        Button(coordinator.isRunning ? "Стоп" : "Старт") {
            Task { await coordinator.toggle() }
        }
        .disabled(!coordinator.hasAPIKey)

        Button("Подсказать ответ (\(coordinator.hotkeys.combo(for: .reply).display))") {
            coordinator.requestSuggestion(mode: .reply)
        }
        .disabled(!coordinator.isRunning)

        Button(coordinator.micEnabled ? "Выключить микрофон" : "Включить микрофон") {
            coordinator.toggleMic()
        }

        Button("Показать / скрыть окно (⌥H)") { toggleOverlay() }

        Divider()

        Button("История…") { openHistory() }
        Button("Настройки…") { openSettings() }
        Button("Выйти") { NSApp.terminate(nil) }

        Divider()

        Text(AppInfo.display)
            .font(.caption2)
    }
}

/// Owns the overlay window, hotkeys, and settings window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    private let hotkeys = HotkeyManager()
    private var overlay: OverlayWindow?
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // belt-and-braces: no dock icon

        let overlay = OverlayWindow(rootView: OverlayView(coordinator: coordinator))
        overlay.orderFrontRegardless()
        self.overlay = overlay

        // Keep the overlay's screen-share visibility in sync with the setting.
        coordinator.settings.$hideFromScreenShare
            .sink { [weak overlay] hidden in overlay?.setHiddenFromScreenShare(hidden) }
            .store(in: &cancellables)

        coordinator.requestAudioConsent = { [weak self] in self?.askAudioConsent() ?? false }

        hotkeys.register(
            store: coordinator.hotkeys,
            onSuggest: { [weak self] mode in self?.coordinator.requestSuggestion(mode: mode) },
            onToggleOverlay: { [weak self] in self?.toggleOverlay() }
        )
        // Rebind live whenever Settings records a new shortcut.
        coordinator.onHotkeysChanged = { [weak self] in self?.hotkeys.reload() }

        // If there's no key yet, surface settings so the user can paste one.
        if !coordinator.hasAPIKey { openSettings() }

        if DemoMode.isEnabled {
            if DemoMode.isAnimated, let dir = DemoMode.snapshotDir {
                Task { await DemoMode.play(coordinator, overlay: overlay, into: dir) }
            } else {
                DemoMode.populate(coordinator)
                if let dir = DemoMode.snapshotDir {
                    openSettings()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { DemoMode.snapshotWindows(to: dir) }
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.unregisterAll()
        Task { await coordinator.stop() }
    }

    /// One-time explicit opt-in before any audio is streamed to OpenAI.
    private func askAudioConsent() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Разрешить передачу аудио в OpenAI?"
        alert.informativeText = """
        Пока идёт запись, звук встречи (системный звук Mac) и ваш микрофон в реальном \
        времени передаются в OpenAI для распознавания речи. Текст реплик передаётся \
        в OpenAI для перевода и подсказок.

        Аудио на этом Mac не сохраняется. Текст разговора хранится только локально. \
        Передача идёт только между «Старт» и «Стоп» — в это время в окне горит \
        красный индикатор «Запись → OpenAI».

        Убедитесь, что запись и расшифровка встречи допустимы для её участников.
        """
        alert.addButton(withTitle: "Разрешить и начать")
        alert.addButton(withTitle: "Отмена")
        alert.window.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    func toggleOverlay() {
        overlay?.toggleVisibility()
    }

    func openSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(coordinator: coordinator))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Stealth"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.settingsWindow = window
    }

    func openHistory() {
        if let historyWindow {
            historyWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: HistoryView(coordinator: coordinator))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Stealth — История"
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 760, height: 500))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.historyWindow = window
    }
}
