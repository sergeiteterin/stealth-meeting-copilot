import AppKit
import SwiftUI

/// A floating, always-on-top panel that is INVISIBLE to screen capture / screen sharing.
///
/// The stealth properties:
///  - `sharingType = .none`  → excluded from screen recordings & shares (Meet/Zoom/Teams).
///  - `.floating` level + joins all Spaces → stays above fullscreen calls.
///  - non-activating panel → clicking it never steals focus from the meeting.
/// The overlay is a non-activating panel, so it is usually NOT the key window.
/// Without this, the first click on a button only focuses the panel and the
/// button does nothing until it is clicked again.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class OverlayWindow: NSPanel {
    init<Content: View>(rootView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 640),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        // Resize bounds.
        minSize = NSSize(width: 360, height: 260)
        maxSize = NSSize(width: 900, height: 1200)

        // --- Stealth: stay out of screen capture (switchable in Settings) ---
        setHiddenFromScreenShare(true)

        // --- Always-on-top across every Space, including over fullscreen apps ---
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // --- Don't steal focus from the call ---
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false

        // --- Transparent chrome; SwiftUI draws the translucent card ---
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true

        let hosting = FirstClickHostingView(rootView: rootView)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting

        positionTopRight()
    }

    /// Borderless panels can't normally become key; allow it so text is selectable if needed.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let margin: CGFloat = 24
        let origin = NSPoint(
            x: visible.maxX - frame.width - margin,
            y: visible.maxY - frame.height - margin
        )
        setFrameOrigin(origin)
    }

    /// `true` → excluded from screen recordings & shares; `false` → an ordinary window.
    func setHiddenFromScreenShare(_ hidden: Bool) {
        sharingType = hidden ? .none : .readOnly
    }

    func toggleVisibility() {
        if isVisible {
            orderOut(nil)
        } else {
            orderFrontRegardless()
        }
    }
}
