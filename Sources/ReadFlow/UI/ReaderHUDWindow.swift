//
//  ReaderHUDWindow.swift  →  Koe window
//  ReadFlow / Koe
//
//  Hosts the Koe app window (sidebar + Capture/Read + player bar). Keeps the
//  EXACT surface the TTSEngineManager drives — present(words:sourceText:),
//  highlight(index:), setState(_:), hide() + onTogglePlayPause/onRateChange —
//  so the verified engine layer is untouched. Adds onRestart/onStop for the
//  player-bar transport, a display clock for elapsed/total, and theme persistence.
//
//  Conforms to the surface fixed in docs/SPEC.md §3.11 (semantics adapted for a
//  windowed app: `hide()` ends the reading session but keeps the window).
//

import AppKit
import SwiftUI
import Combine

@MainActor
final class ReaderHUDWindow {
    /// The model the manager and this window both drive. The HUD owns it.
    let model = ReaderHUDModel()

    // Bridged to the manager.
    var onTogglePlayPause: (() -> Void)?
    var onRateChange: ((Double) -> Void)?
    var onRestart: (() -> Void)?
    var onStop: (() -> Void)?

    private let settings: Settings
    private var window: NSWindow?
    private var hostingView: NSHostingView<KoeRootView>?
    private var cancellables: Set<AnyCancellable> = []

    // Display clock (purely cosmetic — engines don't expose a transport clock).
    private var clock: Timer?
    private let clockInterval: TimeInterval = 0.25

    init(settings: Settings) {
        self.settings = settings
        syncTypographyFromSettings()
        model.rate = settings.rate
        model.engineLabel = settings.engineKind.displayName

        // Restore saved appearance.
        if let raw = UserDefaults.standard.string(forKey: "readflow.appearance"),
           let a = KoeAppearance(rawValue: raw) {
            model.appearance = a
        }

        // Bridge SwiftUI control callbacks out to the manager.
        model.onTogglePlayPause = { [weak self] in self?.onTogglePlayPause?() }
        model.onRateChange = { [weak self] r in self?.onRateChange?(r) }
        model.onRestart = { [weak self] in self?.onRestart?() }
        model.onStop = { [weak self] in self?.onStop?() }
        model.onClose = { [weak self] in self?.hide() }

        observeSettings()

        // Persist appearance whenever the user toggles it.
        model.$appearance
            .sink { UserDefaults.standard.set($0.rawValue, forKey: "readflow.appearance") }
            .store(in: &cancellables)
    }

    // No deinit: this window lives for the whole process. The display clock uses
    // [weak self] and is invalidated through the normal stop paths; a @MainActor
    // type cannot safely touch the non-Sendable Timer from a nonisolated deinit.

    // MARK: - Window

    /// Build (once) and show the Koe window. Safe to call repeatedly.
    func showWindow() {
        ensureWindow()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func ensureWindow() {
        guard window == nil else { return }

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = "Koe"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.minSize = NSSize(width: 920, height: 620)
        w.center()
        w.isReleasedWhenClosed = false

        let hosting = NSHostingView(rootView: KoeRootView(model: model))
        w.contentView = hosting

        self.window = w
        self.hostingView = hosting
    }

    // MARK: - Manager-facing API (SPEC §3.11)

    /// Load the shared tokenization and show it. Switches to the reading view.
    func present(words: [Word], sourceText: String) {
        syncTypographyFromSettings()
        model.rate = settings.rate
        model.engineLabel = settings.engineKind.displayName
        model.words = words
        model.currentIndex = nil
        model.state = .preparing
        model.koeView = .read
        model.title = derivedTitle(from: words)
        model.elapsed = 0
        model.total = estimatedTotal(wordCount: words.count, rate: settings.rate)

        stopClock()
        showWindow()
    }

    /// Move the highlight. Out-of-range clears it rather than crash.
    func highlight(index: Int) {
        guard index >= 0, index < model.words.count else { model.currentIndex = nil; return }
        model.currentIndex = index
    }

    /// Reflect playback state; run/stop the cosmetic clock accordingly.
    func setState(_ state: TTSPlaybackState) {
        model.state = state
        switch state {
        case .speaking:
            startClock()
        case .preparing:
            stopClock()                // hold the clock until audio is audible
        case .paused, .idle:
            stopClock()
        case .finished:
            stopClock()
            model.currentIndex = nil
            model.elapsed = model.total
        }
    }

    /// Manager calls this on stop(). For a windowed app we keep the window and
    /// the text on screen (so the user can re-read), just end the live session.
    func hide() {
        stopClock()
        model.state = .idle
        model.currentIndex = nil
    }

    // MARK: - Display clock

    private func startClock() {
        guard clock == nil else { return }
        let t = Timer(timeInterval: clockInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.model.state == .speaking else { return }
                self.model.elapsed = min(self.model.total, self.model.elapsed + self.clockInterval)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        clock = t
    }

    private func stopClock() {
        clock?.invalidate()
        clock = nil
    }

    // MARK: - Helpers

    private func derivedTitle(from words: [Word]) -> String {
        guard !words.isEmpty else { return "Selection" }
        let head = words.prefix(6).map(\.text).joined(separator: " ")
        return head.count > 42 ? String(head.prefix(42)) + "…" : head
    }

    private func estimatedTotal(wordCount: Int, rate: Double) -> TimeInterval {
        // ~150 wpm baseline (0.40s/word), scaled by the speed multiplier.
        TimeInterval(Double(wordCount) * 0.40 / max(0.5, rate))
    }

    // MARK: - Settings sync

    private func syncTypographyFromSettings() {
        model.fontName = settings.fontName
        if settings.fontSize > 0 { model.fontSize = settings.fontSize }
        if settings.lineHeight > 0 { model.lineHeight = settings.lineHeight }
        model.letterSpacing = settings.letterSpacing
    }

    private func observeSettings() {
        let s = settings
        s.$fontName.sink { [weak self] v in self?.model.fontName = v }.store(in: &cancellables)
        s.$fontSize.sink { [weak self] v in if v > 0 { self?.model.fontSize = v } }.store(in: &cancellables)
        s.$lineHeight.sink { [weak self] v in if v > 0 { self?.model.lineHeight = v } }.store(in: &cancellables)
        s.$letterSpacing.sink { [weak self] v in self?.model.letterSpacing = v }.store(in: &cancellables)
        s.$rate.sink { [weak self] v in self?.model.rate = v }.store(in: &cancellables)
        s.$engineKind.sink { [weak self] v in self?.model.engineLabel = v.displayName }.store(in: &cancellables)
    }
}
