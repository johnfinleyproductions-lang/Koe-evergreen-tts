//
//  Contracts.swift
//  ReadFlow
//
//  THE SINGLE SOURCE OF TRUTH for shared types. Every other file in the module
//  depends on the declarations here. Downstream agents implement against these
//  signatures VERBATIM — do not change a signature without updating docs/SPEC.md
//  and notifying all engine/UI implementers.
//
//  This file must compile on its own with `swift build` (no other ReadFlow file present).
//  It therefore imports only Foundation. Anything UI-specific lives elsewhere.
//

import Foundation

// MARK: - Word Tokenization (shared rule)

/// The canonical word model shared by the manager and the HUD.
///
/// Tokenization is performed ONCE by `TTSEngineManager` (see `WordTokenizer`)
/// and the resulting `[Word]` array is handed to the HUD. Engines emit an
/// `Int` index into THIS array via their `onWord` callback so that the
/// highlighted word always lines up with what the HUD is rendering.
public struct Word: Equatable, Sendable {
    /// The visible text of the word (no surrounding whitespace).
    public let text: String
    /// Range of this word inside the ORIGINAL, untrimmed source string.
    /// Used by file-based engines to map character offsets / boundaries back
    /// to a word index, and by the System engine to map delegate `NSRange`s.
    public let range: Range<String.Index>
    /// Position of this word in the tokenized sequence (0-based). Equals the
    /// `Int` passed to `onWord`.
    public let index: Int

    public init(text: String, range: Range<String.Index>, index: Int) {
        self.text = text
        self.range = range
        self.index = index
    }
}

/// The authoritative word-splitting rule. The manager and HUD MUST both go
/// through this type so indices line up. The rule:
///
///   * A "word" is a maximal run of NON-whitespace, NON-newline characters
///     (Unicode whitespace per `CharacterSet.whitespacesAndNewlines`).
///   * Leading/trailing whitespace is skipped and never becomes a word.
///   * Attached punctuation stays glued to its word ("Hello," is ONE word).
///   * The `range` is computed against the EXACT string passed in (no
///     normalization, no trimming of the source). Callers that normalize text
///     must tokenize the SAME normalized string they pass to the engine.
///
/// This is intentionally simple and deterministic so all three engines and the
/// HUD agree on the same index space.
public enum WordTokenizer {
    /// Split `text` into the canonical word sequence.
    public static func tokenize(_ text: String) -> [Word] {
        var words: [Word] = []
        var index = 0
        var i = text.startIndex
        let whitespace = CharacterSet.whitespacesAndNewlines

        while i < text.endIndex {
            // Skip whitespace.
            while i < text.endIndex,
                  text[i].unicodeScalars.allSatisfy({ whitespace.contains($0) }) {
                i = text.index(after: i)
            }
            guard i < text.endIndex else { break }

            // Consume a run of non-whitespace.
            let start = i
            while i < text.endIndex,
                  !text[i].unicodeScalars.allSatisfy({ whitespace.contains($0) }) {
                i = text.index(after: i)
            }
            let range = start..<i
            words.append(Word(text: String(text[range]), range: range, index: index))
            index += 1
        }
        return words
    }

    /// Map a character offset (UTF-16 / `NSRange.location` style) within `text`
    /// to the index of the word that contains or follows it. Returns `nil` if no
    /// word matches. Used by the System engine to convert delegate `NSRange`s
    /// (and by file engines if they ever work in character space) to word
    /// indices in the shared tokenization. `words` must be the tokenization of
    /// the SAME `text`.
    public static func wordIndex(forUTF16Offset offset: Int,
                                 in text: String,
                                 words: [Word]) -> Int? {
        guard offset >= 0 else { return nil }
        for word in words {
            let lower = word.range.lowerBound.utf16Offset(in: text)
            let upper = word.range.upperBound.utf16Offset(in: text)
            if offset >= lower && offset < upper { return word.index }
        }
        // Offset landed past the last consumed char (e.g. on trailing punctuation
        // whitespace) — snap to the nearest word that starts at/after the offset.
        return words.first(where: { $0.range.lowerBound.utf16Offset(in: text) >= offset })?.index
    }
}

// MARK: - Word Timing (file-based engines)

/// A single word's timing as returned by Kokoro / Azure. File-based engines
/// build `[WordTimestamp]` and schedule `onWord` callbacks off the audio
/// player's clock by comparing `player.currentTime` against `start`.
///
/// `wordIndex` is the index into the shared `[Word]` tokenization (computed by
/// the manager). Engines are responsible for aligning their server-returned
/// token sequence to the shared tokenization and filling in `wordIndex`. If an
/// engine cannot align a particular token, it should map to the best-effort
/// nearest index rather than drop the callback.
public struct WordTimestamp: Equatable, Sendable {
    /// Index into the shared `[Word]` tokenization.
    public let wordIndex: Int
    /// Seconds from the start of audio when this word begins being spoken.
    public let start: TimeInterval
    /// Seconds from the start of audio when this word finishes. May be the
    /// start of the next word if the engine only reports onsets.
    public let end: TimeInterval

    public init(wordIndex: Int, start: TimeInterval, end: TimeInterval) {
        self.wordIndex = wordIndex
        self.start = start
        self.end = end
    }
}

/// The result of synthesizing text on a file-based engine (Kokoro / Azure):
/// decoded audio plus per-word timing in the SHARED index space. The engine
/// plays `audioData` via an internal `AVAudioPlayer` and drives `onWord` from
/// `timestamps`. This type is internal plumbing for those engines; the manager
/// never sees it.
public struct TTSResult: Sendable {
    /// Decoded audio container bytes (WAV/MP3) ready for `AVAudioPlayer(data:)`.
    public let audioData: Data
    /// Per-word timing aligned to the shared tokenization.
    public let timestamps: [WordTimestamp]

    public init(audioData: Data, timestamps: [WordTimestamp]) {
        self.audioData = audioData
        self.timestamps = timestamps
    }
}

// MARK: - Engine Identity

/// Identifies which concrete TTS engine to use. Persisted in `UserDefaults`
/// via its `rawValue`. The default is `.system` so the app works instantly
/// before anything is configured.
public enum EngineKind: String, CaseIterable, Sendable {
    /// AVSpeechSynthesizer. Zero setup. Instant-on default.
    case system
    /// Local Kokoro-FastAPI at http://localhost:8880. Natural-voice upgrade.
    case kokoro
    /// Chatterbox-TTS-Server (Resemble Chatterbox Turbo) over an OpenAI-compatible
    /// `/v1/audio/speech` endpoint. Optional; higher-fidelity expressive voices,
    /// but NO native word timestamps (highlight is estimated from audio duration).
    case chatterbox
    /// Azure Neural TTS over REST. Optional; needs Keychain API key + region.
    case azure

    /// Human-readable label for menus.
    public var displayName: String {
        switch self {
        case .system:     return "System Voice"
        case .kokoro:     return "Kokoro (Local)"
        case .chatterbox: return "Chatterbox (Local)"
        case .azure:      return "Azure Neural"
        }
    }
}

// MARK: - Playback State

/// Coarse playback state emitted by every engine via `onStateChange`. The HUD
/// and menu reflect this. Engines must always reach a terminal state
/// (`.finished` via `onFinish` or `.idle` after `onError`/`stop()`).
public enum TTSPlaybackState: String, Sendable {
    /// Nothing playing; ready to accept `speak`.
    case idle
    /// `speak` accepted; synthesizing/fetching audio but not yet audible.
    /// File-based engines sit here during the network/decoding phase.
    case preparing
    /// Audio is audible and word callbacks are firing.
    case speaking
    /// Paused mid-utterance (audio stopped, position retained). Optional —
    /// engines that cannot pause may treat pause as stop.
    case paused
    /// Reached the end of the utterance normally.
    case finished
}

// MARK: - Errors

/// Errors any engine may surface through `onError`. Always actionable: the
/// manager/HUD maps these to user-facing guidance (e.g. offer System voice when
/// Kokoro is unreachable). Engines must NEVER fail silently.
public enum TTSError: LocalizedError, Sendable {
    /// The text passed to `speak` was empty after tokenization.
    case emptyText
    /// A local/remote TTS server could not be reached.
    case engineUnavailable(EngineKind, underlying: String)
    /// The server responded but the payload was malformed (bad base64, missing
    /// timestamps, non-2xx, etc.).
    case badResponse(EngineKind, detail: String)
    /// Returned audio bytes could not be decoded / played.
    case audioPlaybackFailed(detail: String)
    /// A required credential (e.g. Azure key) is missing from the Keychain.
    case missingCredential(EngineKind)
    /// Catch-all for anything else; carries a message safe to show the user.
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            return "There's no text to read."
        case .engineUnavailable(let kind, let underlying):
            return "\(kind.displayName) is unavailable: \(underlying)"
        case .badResponse(let kind, let detail):
            return "\(kind.displayName) returned an unexpected response: \(detail)"
        case .audioPlaybackFailed(let detail):
            return "Couldn't play the audio: \(detail)"
        case .missingCredential(let kind):
            return "\(kind.displayName) needs an API key. Add it in Settings."
        case .other(let message):
            return message
        }
    }
}

// MARK: - The TTS Engine Protocol

/// The ONE protocol behind which all three engines hide. Each engine OWNS its
/// own playback (no shared audio file in the manager). Callbacks may be invoked
/// from background threads by file-based engines; engines are responsible for
/// hopping to the main thread for `onWord`/`onStateChange`/`onFinish`/`onError`
/// so UI consumers never have to. (Implementations: dispatch all four callbacks
/// on `DispatchQueue.main`.)
///
/// Lifecycle contract:
///   * `prewarm()` — optional warm-up (load voices, ping server). Idempotent,
///     non-blocking, safe to call repeatedly. Must never crash if the backend
///     is down.
///   * `speak(...)` — begin a NEW utterance. If something is already playing,
///     the engine stops it first. Emits `.preparing` → `.speaking`, one
///     `onWord(index)` per word as it is spoken (indices into the shared
///     tokenization the manager computed from the SAME `text`), then exactly
///     one of `onFinish()` (natural end) OR `onError(_)` (failure). After a
///     successful `speak`, the engine ends in `.finished`.
///   * `stop()` — halt immediately, release audio, return to `.idle`. Must NOT
///     fire `onFinish`. Safe to call when already idle.
///
/// `rate` is a normalized speed multiplier where 1.0 == the engine's natural
/// default rate. Range clamped by the engine to a sane band (≈0.5...2.0).
public protocol TTSEngine: AnyObject {
    /// Which concrete engine this is.
    var kind: EngineKind { get }

    /// Optional warm-up. Idempotent and non-blocking; never throws/crashes.
    func prewarm()

    /// Speak `text`. See protocol doc for the full callback contract.
    /// - Parameters:
    ///   - text: The exact string that was tokenized by the manager.
    ///   - rate: Normalized speed multiplier (1.0 == natural).
    ///   - onWord: Called once per word with its index in the shared
    ///     tokenization. Delivered on the main thread.
    ///   - onStateChange: Called on every `TTSPlaybackState` transition.
    ///     Delivered on the main thread.
    ///   - onFinish: Called exactly once on natural completion. Delivered on
    ///     the main thread. Not called after `stop()`.
    ///   - onError: Called exactly once on failure with an actionable error.
    ///     Delivered on the main thread.
    func speak(text: String,
               rate: Double,
               onWord: @escaping (Int) -> Void,
               onStateChange: @escaping (TTSPlaybackState) -> Void,
               onFinish: @escaping () -> Void,
               onError: @escaping (TTSError) -> Void)

    /// Stop immediately and return to `.idle`. Does not fire `onFinish`.
    func stop()

    /// Change the playback speed of the CURRENT utterance live, without
    /// re-synthesizing. Engines that bake rate at synthesis time (System, Azure)
    /// ignore this (default no-op); file-based players (Kokoro) apply it instantly
    /// via the audio player's rate, so changing speed never reloads the audio.
    func updateRate(_ rate: Double)
}

public extension TTSEngine {
    /// Default: rate only takes effect on the next `speak`.
    func updateRate(_ rate: Double) {}
}

// MARK: - Notifications

/// Cross-component signals. Posted on the main thread.
public extension Notification.Name {
    /// Posted when the user requests a read of the current selection (hotkey or
    /// menu). `object` is `nil`; capture happens in the handler.
    static let readFlowReadSelection = Notification.Name("readflow.readSelection")
    /// Posted to stop any in-progress reading. `object` is `nil`.
    static let readFlowStop = Notification.Name("readflow.stop")
    /// Posted when the user toggles play/pause from the HUD.
    static let readFlowTogglePlayPause = Notification.Name("readflow.togglePlayPause")
    /// Posted when settings that affect playback change (engine/rate/voice).
    static let readFlowSettingsChanged = Notification.Name("readflow.settingsChanged")
    /// Posted with `object` == the text (String) when an EXTERNAL source (the
    /// browser extension via the local listener) asks Koe to read something.
    static let readFlowReadExternalText = Notification.Name("readflow.readExternalText")
}

// MARK: - Settings Keys

/// Centralized UserDefaults keys and the Keychain identity for the Azure key.
/// `Settings` (Core/Settings.swift) is the only type that should READ/WRITE
/// these; everything else goes through the `Settings` object.
public enum SettingsKey {
    public static let engineKind        = "readflow.engineKind"        // String (EngineKind.rawValue)
    public static let rate              = "readflow.rate"              // Double (0.5...2.0)
    public static let systemVoiceID     = "readflow.systemVoiceID"     // String (AVSpeechSynthesisVoice.identifier)
    public static let kokoroVoice       = "readflow.kokoroVoice"       // String (e.g. "af_sky")
    public static let azureVoice        = "readflow.azureVoice"        // String (e.g. "en-US-JennyNeural")
    public static let azureRegion       = "readflow.azureRegion"       // String (e.g. "eastus")
    public static let fontName          = "readflow.fontName"          // String ("" => system; "OpenDyslexic")
    public static let fontSize          = "readflow.fontSize"          // Double (pt)
    public static let lineHeight        = "readflow.lineHeight"        // Double (multiplier)
    public static let letterSpacing     = "readflow.letterSpacing"     // Double (pt)
    public static let kokoroBaseURL     = "readflow.kokoroBaseURL"     // String (default http://localhost:8880)
    public static let chatterboxBaseURL = "readflow.chatterboxBaseURL" // String (default http://192.168.4.176:8004)
    public static let chatterboxVoice   = "readflow.chatterboxVoice"   // String (predefined voice, e.g. "Abigail")

    /// Keychain service + account under which the Azure subscription key is
    /// stored. The key is NEVER written to UserDefaults or logged.
    public static let azureKeychainService = "com.readflow.azure"
    public static let azureKeychainAccount = "subscriptionKey"
}
