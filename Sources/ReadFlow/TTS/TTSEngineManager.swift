//
//  TTSEngineManager.swift
//  ReadFlow
//
//  The orchestrator the rest of the app talks to. It picks the active engine
//  from `Settings.engineKind`, tokenizes the source text ONCE via the canonical
//  `WordTokenizer.tokenize` rule (SPEC §4), hands the resulting `[Word]` to the
//  HUD, starts the engine, and relays the engine's callbacks (onWord /
//  onStateChange / onFinish / onError) to the HUD and the menu.
//
//  It owns NO audio file — each engine owns its own playback (SPEC §3.7). The
//  manager only owns: the active-engine selection, the shared tokenization for
//  the in-flight utterance, and the coarse playback state.
//
//  Graceful degradation: when a non-System engine fails, the manager surfaces a
//  user-visible error and automatically falls back to the System voice so the
//  app NEVER silently fails (SPEC §6).
//
//  Consumes from Contracts.swift: Word, WordTokenizer, EngineKind,
//  TTSPlaybackState, TTSError, TTSEngine, Notification.Name.readFlow*.
//  Consumes from Settings.swift: Settings (engineKind, rate, voices, region,
//  kokoroBaseURL, loadAzureKey). Consumes from UI/ReaderHUDWindow.swift:
//  ReaderHUDWindow (present/highlight/setState/hide + onTogglePlayPause/onRateChange).
//  Exposes: TTSEngineManager (init/state/prewarm/read/togglePlayPause/stop/onStateChange).
//

import Foundation
import AppKit

/// Orchestrates text-to-speech: selects the active engine, tokenizes once,
/// shares words with the HUD, and relays per-word/state callbacks. UI-facing,
/// so it lives on the main actor.
@MainActor
final class TTSEngineManager {

    // MARK: - Dependencies

    private let settings: Settings
    private let hud: ReaderHUDWindow

    // MARK: - State (UI-facing)

    /// Coarse playback state. Mirrors what the active engine last reported (with
    /// terminal states normalized to `.idle` once an utterance ends so the menu
    /// shows a ready state).
    private(set) var state: TTSPlaybackState = .idle {
        didSet {
            guard oldValue != state else { return }
            hud.setState(state)
            onStateChange?(state)
        }
    }

    /// Observed by the menu-bar controller to reflect state in the icon/menu.
    var onStateChange: ((TTSPlaybackState) -> Void)?

    // MARK: - Engine cache

    /// Lazily-constructed, cached engines keyed by kind. Built on demand so we
    /// never spin up a network engine the user hasn't selected.
    private var engineCache: [EngineKind: TTSEngine] = [:]

    /// The engine currently driving (or last driving) playback.
    private weak var activeEngine: TTSEngine?

    // MARK: - In-flight utterance

    /// The tokenization of the EXACT string handed to the current engine. Shared
    /// with the HUD; `onWord` indices point into this array.
    private var currentWords: [Word] = []
    /// The exact source text currently loaded (for a fallback re-read).
    private var currentText: String = ""
    /// A monotonically increasing token so stale callbacks from a superseded
    /// utterance are ignored (e.g. a slow Kokoro fetch returning after `stop()`).
    private var utteranceToken: Int = 0

    /// The engine kind last seen by `settingsChanged`. Used to detect an ACTUAL
    /// engine switch (vs a rate/voice change) so we only tear down playback when
    /// the user picked a different engine.
    private var lastKnownEngineKind: EngineKind

    // MARK: - Init

    init(settings: Settings, hud: ReaderHUDWindow) {
        self.settings = settings
        self.hud = hud
        self.lastKnownEngineKind = settings.engineKind

        // Wire the HUD's transport controls back to the manager.
        hud.onTogglePlayPause = { [weak self] in
            self?.togglePlayPause()
        }
        hud.onRateChange = { [weak self] newRate in
            guard let self else { return }
            // Apply LIVE to the engine currently playing (Kokoro changes the audio
            // player's rate instantly — no reload), then persist for the next read.
            self.activeEngine?.updateRate(newRate)
            self.settings.rate = newRate
        }
        // Player-bar transport: restart re-reads the loaded text from the top;
        // stop halts and clears. Both reuse the existing read/stop paths.
        hud.onRestart = { [weak self] in self?.restart() }
        hud.onStop = { [weak self] in self?.stop() }

        // React to settings changes (engine/voice/rate) so a switch while idle
        // takes effect on the next read, and so we can prewarm the new engine.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: .readFlowSettingsChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Settings reaction

    @objc private func settingsChanged() {
        // Keep this hop on the main thread (we're @MainActor; the notification
        // is posted on the main thread per the contract).
        MainActor.assumeIsolated {
            let newKind = settings.engineKind

            // If the user switched to a DIFFERENT engine while audio is in flight,
            // tear down the old engine's playback first. Otherwise the previously
            // selected engine keeps playing to completion (its AVAudioPlayer +
            // word timer keep running), `activeEngine` stays stale, and the
            // freshly-prewarmed new engine could start a warm-up over the top.
            // Only stop on an ACTUAL engine change — rate/voice changes also post
            // this notification and must NOT interrupt playback.
            let engineKindChanged = (newKind != lastKnownEngineKind)
                || (activeEngine != nil && activeEngine?.kind != newKind)
            let midPlayback = (state == .speaking || state == .preparing || state == .paused)
            if engineKindChanged && (midPlayback || activeEngine != nil) {
                stop()
            }
            lastKnownEngineKind = newKind

            // Re-prewarm whatever engine is now selected. Cheap and idempotent.
            prewarm()
        }
    }

    // MARK: - Engine selection / construction

    /// Returns the engine for `kind`, constructing and caching it on first use.
    private func engine(for kind: EngineKind) -> TTSEngine {
        if let cached = engineCache[kind] {
            return cached
        }
        let built = makeEngine(for: kind)
        engineCache[kind] = built
        return built
    }

    /// Constructs a fresh engine for `kind` from current settings. Pure factory;
    /// no side effects beyond allocation.
    private func makeEngine(for kind: EngineKind) -> TTSEngine {
        switch kind {
        case .system:
            let voiceID = settings.systemVoiceID.isEmpty ? nil : settings.systemVoiceID
            return SystemAVSpeechEngine(voiceID: voiceID)

        case .kokoro:
            let url = URL(string: settings.kokoroBaseURL)
                ?? URL(string: "http://localhost:8880")!
            return KokoroEngine(baseURL: url, voice: settings.kokoroVoice)

        case .azure:
            // The key is read from the Keychain on demand via the provider —
            // never captured/copied here, never logged.
            return AzureNeuralEngine(
                region: settings.azureRegion,
                voice: settings.azureVoice,
                keyProvider: { [weak settings] in settings?.loadAzureKey() }
            )
        }
    }

    /// Invalidate the System engine cache entry when the chosen voice changes so
    /// a rebuilt instance honors the new voice. (Network engines read settings
    /// fresh each `speak`, so they don't need invalidation here.)
    private func invalidateSystemEngineIfVoiceChanged() {
        // Cheap heuristic: drop the cached system engine; it rebuilds lazily.
        // Only do this when not the active driver to avoid yanking playback.
        if let sys = engineCache[.system], sys !== activeEngine {
            engineCache[.system] = nil
        }
    }

    // MARK: - Prewarm

    /// Prewarm the currently selected engine (load voices / ping server). Safe to
    /// call repeatedly; never blocks, never crashes if the backend is down.
    func prewarm() {
        invalidateSystemEngineIfVoiceChanged()
        engine(for: settings.engineKind).prewarm()
    }

    // MARK: - Read

    /// Tokenize `text` ONCE, hand the words to the HUD, and start the selected
    /// engine. Empty text surfaces `TTSError.emptyText` and stops.
    func read(_ text: String) {
        // 1. Tokenize the EXACT string we will hand to the engine (SPEC §4).
        let words = WordTokenizer.tokenize(text)
        guard !words.isEmpty else {
            presentError(.emptyText, from: settings.engineKind)
            stop()
            return
        }

        // Supersede any in-flight utterance first.
        stop()

        // New utterance generation; callbacks from older ones are now ignored.
        utteranceToken &+= 1
        let token = utteranceToken
        currentWords = words
        currentText = text

        let selectedKind = settings.engineKind

        // 2. Azure with no Keychain key: fail loudly BEFORE attempting playback,
        //    then fall back to System (SPEC §3.7).
        if selectedKind == .azure, (settings.loadAzureKey()?.isEmpty ?? true) {
            presentError(.missingCredential(.azure), from: .azure)
            fallBackToSystem(text: text, token: token)
            return
        }

        // 3. Hand the shared tokenization to the HUD and show it.
        hud.present(words: words, sourceText: text)
        state = .preparing

        // 4. Start the engine, relaying every callback (guarded by `token`).
        startEngine(for: selectedKind, text: text, token: token)
    }

    /// Begin speaking on the engine for `kind`, wiring all four callbacks back to
    /// the HUD/menu. All wiring is guarded by `token` so stale callbacks from a
    /// superseded or stopped utterance are dropped.
    private func startEngine(for kind: EngineKind, text: String, token: Int) {
        let selected = engine(for: kind)
        activeEngine = selected

        let rate = settings.rate

        selected.speak(
            text: text,
            rate: rate,
            onWord: { [weak self] index in
                guard let self, self.isCurrent(token) else { return }
                // Index is in the shared tokenization space; clamp defensively.
                guard index >= 0, index < self.currentWords.count else { return }
                self.hud.highlight(index: index)
            },
            onStateChange: { [weak self] newState in
                guard let self, self.isCurrent(token) else { return }
                // Normalize terminal `.finished` to keep `state` as the live
                // engine state; `onFinish` handles the wind-down to `.idle`.
                self.state = newState
            },
            onFinish: { [weak self] in
                guard let self, self.isCurrent(token) else { return }
                self.state = .finished
                self.windDown()
            },
            onError: { [weak self] error in
                guard let self, self.isCurrent(token) else { return }
                self.handleEngineError(error, failingKind: kind, text: text, token: token)
            }
        )
    }

    /// True if `token` is still the live utterance (not superseded/stopped).
    private func isCurrent(_ token: Int) -> Bool {
        token == utteranceToken
    }

    // MARK: - Error handling / graceful degradation

    /// Handle a failure from the active engine. Surfaces a user-visible message,
    /// then — if the failing engine isn't already System — automatically retries
    /// on the System voice so the user still hears their text (SPEC §6).
    private func handleEngineError(_ error: TTSError,
                                   failingKind: EngineKind,
                                   text: String,
                                   token: Int) {
        presentError(error, from: failingKind)

        if failingKind != .system {
            fallBackToSystem(text: text, token: token)
        } else {
            // Even the System voice failed — nothing left to fall back to.
            windDown()
        }
    }

    /// Re-run the SAME text on the System engine after a non-System failure.
    /// Reuses the current tokenization/HUD presentation; only the engine changes.
    private func fallBackToSystem(text: String, token: Int) {
        // Only proceed if this is still the live utterance.
        guard isCurrent(token) else { return }

        // Ensure the HUD is showing the current words (it may not be if we
        // failed pre-credential before `present`).
        if currentWords.isEmpty {
            let words = WordTokenizer.tokenize(text)
            guard !words.isEmpty else { windDown(); return }
            currentWords = words
            currentText = text
        }
        hud.present(words: currentWords, sourceText: text)
        state = .preparing

        startEngine(for: .system, text: text, token: token)
    }

    /// Map a `TTSError` to a non-blocking, user-visible alert. Never logs secrets
    /// (errors are constructed by engines from sanitized detail strings).
    private func presentError(_ error: TTSError, from kind: EngineKind) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "ReadFlow"
        alert.informativeText = error.errorDescription ?? "Something went wrong."

        // Offer a System-voice fallback affordance when a non-System engine failed
        // (the manager already auto-falls-back, so this is informational + a way
        // to make System the persistent default).
        if kind != .system, case .emptyText = error {
            // emptyText needs no fallback button.
        }
        if kind != .system {
            switch error {
            case .emptyText:
                break
            default:
                alert.addButton(withTitle: "OK")
                alert.addButton(withTitle: "Use System Voice")
                let response = alert.runModal()
                if response == .alertSecondButtonReturn {
                    settings.engineKind = .system
                }
                return
            }
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Transport

    /// Toggle between speaking and paused. Because the protocol's `speak` is a
    /// fresh-utterance API (no pause primitive in the contract), pausing is
    /// modeled as: stop the engine but keep the words/HUD; resuming re-reads the
    /// current text from the start on the selected engine. This keeps behavior
    /// identical and reliable across all three engines (SPEC: engines that can't
    /// pause may treat pause as stop).
    func togglePlayPause() {
        switch state {
        case .speaking, .preparing:
            // Pause -> stop the audio but retain the loaded text so we can resume.
            let resumeText = currentText
            activeEngine?.stop()
            // Bump generation so the stopped engine's stray callbacks are ignored,
            // but preserve `currentText`/`currentWords` for resume.
            utteranceToken &+= 1
            currentText = resumeText
            state = .paused

        case .paused:
            // Resume -> re-read the retained text from the top.
            let text = currentText
            guard !text.isEmpty else { state = .idle; return }
            read(text)

        case .idle, .finished:
            // Nothing loaded, or finished — re-read if we still have text.
            let text = currentText
            guard !text.isEmpty else { return }
            read(text)
        }
    }

    /// Re-read the currently loaded text from the beginning. No-op if nothing is
    /// loaded (e.g. after an explicit stop cleared the text).
    func restart() {
        let text = currentText
        guard !text.isEmpty else { return }
        read(text)
    }

    /// Stop immediately: halt the active engine, drop the in-flight utterance,
    /// hide the HUD, and return to `.idle`. Safe to call when already idle.
    func stop() {
        // Supersede so any pending engine callbacks are ignored.
        utteranceToken &+= 1
        activeEngine?.stop()
        currentWords = []
        currentText = ""
        state = .idle
        hud.hide()
    }

    // MARK: - Wind-down

    /// Normalize to a ready state after a natural finish (or a final failure).
    /// Keeps the HUD visible briefly via its own `setState(.finished)` already
    /// pushed through `state`; then settles `state` to `.idle` so the menu shows
    /// "ready" without firing a spurious second HUD hide.
    private func windDown() {
        // Drop the in-flight references; keep `currentText` so togglePlayPause
        // can re-read after a finish if the user hits play again.
        currentWords = []
        activeEngine = nil
        // Settle to idle for the menu (HUD already reflected `.finished`).
        state = .idle
    }
}
