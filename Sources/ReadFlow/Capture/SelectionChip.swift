//
//  SelectionChip.swift
//  ReadFlow / Koe
//
//  The "Read on Highlight" affordance: when the user selects text in ANY app, a
//  small floating "声 Read in Koe" button appears next to the selection — no
//  hotkey, no menu. Clicking it reads the selection aloud in Koe. This mirrors
//  the floating Koe chip in the design mock.
//
//  Detection is NON-DESTRUCTIVE: on each global mouse-up we read the selection
//  via the AX path ONLY (AccessibilityBridge.selectedTextViaAccessibility), so we
//  never synthesize a Cmd-C just to detect a selection. Apps that don't expose AX
//  selected text simply don't get the auto-chip — the right-click "Read in Koe"
//  Service and the ⌥R hotkey still work there.
//
//  Requires Accessibility trust to READ the selection (same as all reading); the
//  global mouse MONITORS themselves are passive and need no special permission.
//

import AppKit
import SwiftUI

/// Temporary file-based debug log (the unified log doesn't capture this app's
/// NSLog under SwiftPM/CLT). DEBUG-only: in release builds every call is a no-op,
/// so nothing is written and there's no I/O on the playback/capture hot paths.
/// In DEBUG it writes to the per-user temp dir (not world-shared /tmp). Logs
/// lengths/flags only — never the user's text.
enum KoeLog {
    static let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("koe-debug.log")
    static func reset() {
        #if DEBUG
        try? "".write(toFile: path, atomically: true, encoding: .utf8)
        #endif
    }
    @inline(__always) static func d(_ msg: String) {
        #if DEBUG
        let line = "[\(Date())] \(msg)\n"
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); if let data = line.data(using: .utf8) { h.write(data) }; try? h.close()
        } else {
            try? line.write(toFile: path, atomically: true, encoding: .utf8)
        }
        #endif
    }
}

@MainActor
final class SelectionChipController {

    /// Invoked with the selected text when the user clicks the chip.
    var onRead: ((String) -> Void)?

    /// UserDefaults gate so the user can disable the auto-chip from the menu.
    static let enabledKey = "readflow.autoChip"
    private var isEnabled: Bool { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }

    private var panel: ChipPanel?
    private var mouseUpMonitor: Any?
    private var mouseDownMonitor: Any?
    private var keyMonitor: Any?
    private var pendingShow: DispatchWorkItem?
    private var autoHide: DispatchWorkItem?
    private var lastShownText: String?

    private let chipSize = NSSize(width: 168, height: 44)

    // MARK: - Lifecycle

    /// Install the passive global monitors. Safe to call once.
    func start() {
        // A drag-select ends in a left mouse-up — that's our cue to look for a
        // selection. Global monitors only fire for OTHER apps' events, which is
        // exactly what we want (selections happen in other apps).
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            self?.scheduleCheck()
        }
        KoeLog.d("chip.start: monitors installed (mouseUp=\(mouseUpMonitor != nil))")
        // Any new click (e.g. starting a fresh drag, or clicking elsewhere)
        // dismisses a showing chip.
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            self?.hide()
        }
        // Escape anywhere dismisses (local; our panel is non-activating).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 { self?.hide() }   // 53 = Escape
            return event
        }
    }

    func stop() {
        [mouseUpMonitor, mouseDownMonitor, keyMonitor].forEach { if let m = $0 { NSEvent.removeMonitor(m) } }
        mouseUpMonitor = nil; mouseDownMonitor = nil; keyMonitor = nil
        pendingShow?.cancel(); autoHide?.cancel()
        hide()
    }

    // MARK: - Detection

    private func scheduleCheck() {
        let trusted = AccessibilityBridge.isAccessibilityTrusted()
        KoeLog.d("mouseUp seen: enabled=\(isEnabled) trusted=\(trusted)")
        guard isEnabled, trusted else { return }
        // Let the selection settle before reading it (the app finishes updating
        // its AX state just after mouse-up).
        pendingShow?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.check() }
        pendingShow = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func check() {
        guard isEnabled else { return }
        guard let text = AccessibilityBridge.selectedTextViaAccessibility() else {
            KoeLog.d("check: AX selection = nil (no chip)")
            hide(); return
        }
        KoeLog.d("check: AX selection len=\(text.count) -> showing chip")
        show(text: text)
    }

    // MARK: - Presentation

    private func show(text: String) {
        lastShownText = text
        NSLog("KOE: chip shown (len=%d)", text.count)
        ensurePanel()
        guard let panel else { return }

        panel.chipModel.action = { [weak self] in
            guard let self else { return }
            let t = self.lastShownText ?? text
            NSLog("KOE: chip CLICKED (len=%d)", t.count)
            self.hide()
            self.onRead?(t)
        }

        let origin = anchorOrigin()
        panel.setFrame(NSRect(origin: origin, size: chipSize), display: true)
        panel.orderFrontRegardless()
        KoeLog.d("show: panel ordered front at \(origin) visible=\(panel.isVisible)")

        // Auto-dismiss if untouched.
        autoHide?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        autoHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: work)
    }

    private func hide() {
        autoHide?.cancel()
        panel?.orderOut(nil)
    }

    /// Place the chip just below-right of the MOUSE CURSOR. The cursor is where
    /// the user just finished selecting (and where their eyes are), and
    /// `NSEvent.mouseLocation` is in reliable global screen coordinates — unlike
    /// AX selection bounds, whose cross-app coordinate conversion proved wrong
    /// (it placed the chip off-screen). Clamped to the visible screen.
    private func anchorOrigin() -> NSPoint {
        let m = NSEvent.mouseLocation
        var origin = NSPoint(x: m.x + 6, y: m.y - chipSize.height - 14)

        let screen = NSScreen.screens.first(where: { NSMouseInRect(m, $0.frame, false) }) ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            origin.x = min(max(vf.minX + 4, origin.x), vf.maxX - chipSize.width - 4)
            origin.y = min(max(vf.minY + 4, origin.y), vf.maxY - chipSize.height - 4)
        }
        return origin
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let p = ChipPanel(contentRect: NSRect(origin: .zero, size: chipSize))
        let hosting = FirstMouseHostingView(rootView: SelectionChipView(model: p.chipModel))
        hosting.frame = NSRect(origin: .zero, size: chipSize)
        hosting.autoresizingMask = [.width, .height]
        p.contentView = hosting
        panel = p
    }
}

// MARK: - Chip panel

/// A borderless floating panel for the chip. It does NOT steal focus when shown
/// (orderFrontRegardless never makes it key), but it CAN become key when the user
/// clicks it — which is required for the SwiftUI button to receive that click.
private final class ChipPanel: NSPanel {
    let chipModel = ChipModel()

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false                       // the SwiftUI capsule draws its own
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    // Must be able to become key so the button click registers; but we only
    // order it front (never makeKey on show), so it doesn't grab focus until tapped.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that accepts the FIRST click even while our app is in the
/// background, so a single tap on the chip works (no need to click once to
/// activate, then again to press).
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor required init(rootView: Content) { super.init(rootView: rootView) }
    @available(*, unavailable) @MainActor required dynamic init?(coder: NSCoder) { fatalError() }
}

// MARK: - Chip view

@MainActor
final class ChipModel: ObservableObject {
    var action: (() -> Void)?
}

private struct SelectionChipView: View {
    @ObservedObject var model: ChipModel
    private let palette = KoePalette.light   // the chip reads cleanest in the light accent

    var body: some View {
        Button { model.action?() } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.22)).frame(width: 22, height: 22)
                    Text("声").font(KoeFont.mincho(13)).foregroundStyle(.white)
                }
                Text("Read in Koe").font(KoeFont.gothic(13, .bold)).foregroundStyle(.white)
                Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(Capsule().fill(palette.shu))
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
            .shadow(color: Color(hex: 0x281E0F, alpha: 0.40), radius: 14, y: 7)
        }
        .buttonStyle(.plain)
        .padding(8)                            // room for the shadow inside the panel
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
