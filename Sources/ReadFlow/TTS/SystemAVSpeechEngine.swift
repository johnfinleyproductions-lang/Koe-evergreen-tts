//
//  SystemAVSpeechEngine.swift
//  ReadFlow
//
//  The instant-on default TTS engine. Wraps `AVSpeechSynthesizer` and requires
//  zero setup — it is the engine the app falls back to whenever Kokoro/Azure are
//  unavailable, and the one the user hears the first time they launch ReadFlow.
//
//  Word highlighting works by translating the synthesizer's
//  `willSpeakRangeOfSpeechString` NSRange (a UTF-16 offset into the utterance
//  text) into an index in the SHARED `[Word]` tokenization via
//  `WordTokenizer.wordIndex(forUTF16Offset:in:words:)`. Because the manager and
//  this engine tokenize the SAME `text`, the emitted index always lines up with
//  `model.words[i]` in the HUD.
//
//  Quality contract (see docs/SPEC.md §6):
//    * All four callbacks are delivered on the main thread.
//    * Exactly one of onFinish / onError fires per `speak`.
//    * `stop()` never fires onFinish.
//    * No retain cycles: the delegate is `self`; per-utterance callback state is
//      cleared on every terminal transition.
//

import Foundation
import AVFoundation

/// AVSpeechSynthesizer-backed engine. The instant-on default.
///
/// This engine owns its own playback (the synthesizer). It never touches a
/// shared audio file. Word callbacks come straight from the synthesizer's
/// boundary delegate, so timing is exact and no high-frequency timer is needed.
final class SystemAVSpeechEngine: NSObject, TTSEngine, AVSpeechSynthesizerDelegate, @unchecked Sendable {

    // MARK: TTSEngine identity

    var kind: EngineKind { .system }

    // MARK: Configuration

    /// Preferred voice identifier (`AVSpeechSynthesisVoice.identifier`). `nil` or
    /// empty => the system default voice for the current locale.
    private let voiceID: String?

    // MARK: Playback objects

    private let synthesizer = AVSpeechSynthesizer()

    // MARK: Per-utterance state
    //
    // These describe the utterance currently in flight. They are only read/written
    // on the main thread (the synthesizer delivers its delegate callbacks on the
    // main run loop, and we start utterances from the main thread), so no locking
    // is required. They are cleared on every terminal transition so a late or
    // stray delegate callback can never resurrect a finished read.

    /// The exact text handed to `speak` — the same string the manager tokenized.
    private var currentText: String = ""
    /// Tokenization of `currentText`. Built once per `speak`.
    private var currentWords: [Word] = []
    /// UTF-16 [start, end) offset of each word in `currentText`, precomputed ONCE
    /// per utterance in a single O(n) pass (parallel to `currentWords`). Lets the
    /// boundary callback map an offset to a word index in O(log n) instead of an
    /// O(n²)-per-callback linear scan, which stutters the main thread on long reads.
    private var currentWordStarts: [Int] = []
    private var currentWordEnds: [Int] = []
    /// The utterance we started; used to ignore delegate callbacks for any other.
    private var currentUtterance: AVSpeechUtterance?
    /// Last word index we emitted, to coalesce duplicate boundary callbacks that
    /// land inside the same word.
    private var lastEmittedIndex: Int = -1

    // Callbacks for the in-flight utterance.
    private var onWord: ((Int) -> Void)?
    private var onStateChange: ((TTSPlaybackState) -> Void)?
    private var onFinish: (() -> Void)?
    private var onError: ((TTSError) -> Void)?

    /// Guards against double terminal delivery (e.g. a `didCancel` arriving after
    /// we already reported `didFinish`).
    private var isActive = false

    // MARK: Init

    /// - Parameter voiceID: `AVSpeechSynthesisVoice.identifier` to prefer, or
    ///   `nil`/empty for the locale default.
    init(voiceID: String?) {
        if let voiceID, !voiceID.isEmpty {
            self.voiceID = voiceID
        } else {
            self.voiceID = nil
        }
        super.init()
        synthesizer.delegate = self
    }

    deinit {
        // Tear down without firing callbacks. `immediate` is safe from deinit.
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.delegate = nil
    }

    // MARK: TTSEngine.prewarm

    /// Warm the speech stack so the first real `speak` is snappy. We synthesize a
    /// single space at zero volume; AVSpeechSynthesizer initializes its audio
    /// graph and loads the default voice as a side effect. Idempotent, cheap, and
    /// never crashes if audio is unavailable.
    func prewarm() {
        runOnMain { [weak self] in
            guard let self else { return }
            // Don't disturb an in-flight utterance.
            guard !self.synthesizer.isSpeaking, !self.isActive else { return }
            let warm = AVSpeechUtterance(string: " ")
            warm.volume = 0.0
            warm.rate = AVSpeechUtteranceDefaultSpeechRate
            warm.voice = self.resolvedVoice()
            // This warm-up utterance is intentionally NOT tracked as
            // `currentUtterance`, so its delegate callbacks are ignored below.
            self.synthesizer.speak(warm)
        }
    }

    // MARK: TTSEngine.speak

    func speak(text: String,
               rate: Double,
               onWord: @escaping (Int) -> Void,
               onStateChange: @escaping (TTSPlaybackState) -> Void,
               onFinish: @escaping () -> Void,
               onError: @escaping (TTSError) -> Void) {

        runOnMain { [weak self] in
            guard let self else { return }

            // Begin a new utterance: stop anything already playing WITHOUT firing
            // a spurious onFinish for the previous read. We null the previous
            // callbacks first so the `didCancel` delegate from the stop is inert.
            self.teardownInFlight()
            self.synthesizer.stopSpeaking(at: .immediate)

            // Tokenize the EXACT string the manager handed us, using the shared
            // canonical rule, so our indices match the HUD's.
            let words = WordTokenizer.tokenize(text)
            guard !words.isEmpty else {
                // Never silently fail.
                onStateChange(.idle)
                onError(.emptyText)
                return
            }

            // Install per-utterance state + callbacks.
            self.currentText = text
            self.currentWords = words
            (self.currentWordStarts, self.currentWordEnds) = Self.utf16WordOffsets(of: words, in: text)
            self.lastEmittedIndex = -1
            self.onWord = onWord
            self.onStateChange = onStateChange
            self.onFinish = onFinish
            self.onError = onError
            self.isActive = true

            // Build the utterance.
            let utterance = AVSpeechUtterance(string: text)
            utterance.rate = Self.avRate(forNormalized: rate)
            utterance.voice = self.resolvedVoice()
            self.currentUtterance = utterance

            // We are about to fetch/prepare voice resources; report `.preparing`
            // before audio is audible. `didStart` will move us to `.speaking`.
            onStateChange(.preparing)
            self.synthesizer.speak(utterance)
        }
    }

    // MARK: TTSEngine.stop

    func stop() {
        runOnMain { [weak self] in
            guard let self else { return }
            let wasActive = self.isActive
            // Capture the state handler BEFORE teardown nils it, so we can still
            // report the return to `.idle` for an in-flight read.
            let stateChange = self.onStateChange
            // Drop callbacks BEFORE asking the synthesizer to cancel so the
            // resulting `didCancel` delegate is inert and cannot fire onFinish.
            self.teardownInFlight()
            self.synthesizer.stopSpeaking(at: .immediate)
            // Per contract `stop()` returns the engine to `.idle`. Only emit if we
            // were actually mid-read so a stop-while-idle is a no-op for observers.
            if wasActive {
                stateChange?(.idle)
            }
        }
    }

    // MARK: AVSpeechSynthesizerDelegate

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didStart utterance: AVSpeechUtterance) {
        // Ignore callbacks for the warm-up utterance or a stale one.
        guard utterance === currentUtterance, isActive else { return }
        onStateChange?(.speaking)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance, isActive else { return }
        guard characterRange.location != NSNotFound else { return }

        // The NSRange location is a UTF-16 offset into `currentText`. Translate it
        // to a word index in the shared tokenization. The contract's helper snaps
        // to the nearest following word when the offset lands on whitespace/
        // punctuation between words, so we never drop a highlight.
        guard let index = Self.wordIndex(forUTF16Offset: characterRange.location,
                                         starts: currentWordStarts,
                                         ends: currentWordEnds) else {
            return
        }

        // Coalesce repeated callbacks that resolve to the same word.
        guard index != lastEmittedIndex else { return }
        lastEmittedIndex = index
        onWord?(index)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance, isActive else { return }
        let finish = onFinish
        // Capture before teardown clears them.
        let stateChange = onStateChange
        teardownInFlight()
        stateChange?(.finished)
        finish?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        // Cancellation we initiate (stop/new speak) nils the callbacks first, so a
        // tracked-but-active cancel only happens if the system cancels under us.
        guard utterance === currentUtterance, isActive else { return }
        let stateChange = onStateChange
        teardownInFlight()
        // A cancel that wasn't user-initiated still must not silently vanish, but
        // it also isn't a "natural finish". Return to idle; the manager treats a
        // bare idle as a stop, not an error.
        stateChange?(.idle)
    }

    // MARK: Helpers

    /// Resolve a CONCRETE voice. Critical: leaving `utterance.voice == nil` does
    /// NOT reliably fall back to a default on macOS — it can produce SILENCE.
    /// So we always return a real voice: the user's chosen one, else the current
    /// locale's default, else en-US.
    private func resolvedVoice() -> AVSpeechSynthesisVoice? {
        if let voiceID, let v = AVSpeechSynthesisVoice(identifier: voiceID) {
            return v
        }
        return AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Clear all per-utterance state and callbacks. After this, any late delegate
    /// callback for the (now untracked) utterance is a no-op.
    private func teardownInFlight() {
        isActive = false
        currentUtterance = nil
        currentText = ""
        currentWords = []
        currentWordStarts = []
        currentWordEnds = []
        lastEmittedIndex = -1
        onWord = nil
        onStateChange = nil
        onFinish = nil
        onError = nil
    }

    // MARK: - UTF-16 offset index (fast boundary → word mapping)

    /// Record each word's UTF-16 [start, end) offset in `text` with a SINGLE
    /// linear walk (accumulating `utf16.count` per character), instead of calling
    /// `String.Index.utf16Offset(in:)` per word (each O(distance) => O(n²) total).
    private static func utf16WordOffsets(of words: [Word], in text: String) -> ([Int], [Int]) {
        var starts: [Int] = []; starts.reserveCapacity(words.count)
        var ends: [Int] = []; ends.reserveCapacity(words.count)
        var pos = 0
        var i = text.startIndex
        for word in words {
            while i < word.range.lowerBound {
                pos += text[i].utf16.count
                i = text.index(after: i)
            }
            starts.append(pos)
            while i < word.range.upperBound {
                pos += text[i].utf16.count
                i = text.index(after: i)
            }
            ends.append(pos)
        }
        return (starts, ends)
    }

    /// Binary-search the precomputed offsets for the word containing `offset` (its
    /// [start, end) range); if it falls between words (whitespace/punctuation),
    /// snap to the next word — matching `WordTokenizer.wordIndex`'s contract.
    private static func wordIndex(forUTF16Offset offset: Int, starts: [Int], ends: [Int]) -> Int? {
        guard offset >= 0, !starts.isEmpty else { return nil }
        var lo = 0, hi = starts.count - 1, cand = -1   // last word whose start <= offset
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= offset { cand = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        if cand >= 0, offset < ends[cand] { return cand }   // inside [start, end)
        let next = cand + 1                                  // first word starting at/after offset
        return next < starts.count ? next : nil
    }

    /// Map the normalized rate (1.0 == natural) onto the AVSpeech rate scale,
    /// clamped to the engine's supported band. AVSpeechUtterance rates run from
    /// `AVSpeechUtteranceMinimumSpeechRate` to `AVSpeechUtteranceMaximumSpeechRate`
    /// with `AVSpeechUtteranceDefaultSpeechRate` as "normal". We treat the
    /// normalized 0.5...2.0 band as a multiplier around the default and clamp to
    /// the platform min/max.
    private static func avRate(forNormalized normalized: Double) -> Float {
        let clampedMultiplier = min(max(normalized, 0.5), 2.0)
        let scaled = Double(AVSpeechUtteranceDefaultSpeechRate) * clampedMultiplier
        let lo = Double(AVSpeechUtteranceMinimumSpeechRate)
        let hi = Double(AVSpeechUtteranceMaximumSpeechRate)
        return Float(min(max(scaled, lo), hi))
    }

    /// Ensure work runs on the main thread without double-dispatching when we are
    /// already there (keeps synchronous delegate ordering intact).
    private func runOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}
