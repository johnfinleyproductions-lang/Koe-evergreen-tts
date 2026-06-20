//
//  AzureNeuralEngine.swift
//  ReadFlow
//
//  Optional cloud upgrade: Azure Cognitive Services Neural TTS over REST.
//  Strategy (per SPEC §3.10): ONE network call synthesizes the audio (SSML →
//  audio bytes) and a SECOND parallel call requests the same SSML with the
//  `WordBoundary` metadata stream so we get per-word timing. Azure reports word
//  boundaries in 100-nanosecond ticks; we convert ticks → seconds
//  (audioOffset / 10_000_000.0) and align each boundary positionally to the
//  shared `[Word]` tokenization the manager computed from the SAME `text`.
//
//  The subscription key is read ONLY from the Keychain via the injected
//  `keyProvider` (Settings.loadAzureKey). It is NEVER hardcoded and NEVER logged
//  — not in os_log, not in print, not in error strings handed back to the UI.
//
//  Playback is owned by this engine: an internal AVAudioPlayer plays the bytes,
//  and a high-frequency timer compares player.currentTime against each word's
//  start time to fire onWord — identical clock-driven approach to KokoroEngine.
//

import Foundation
import AVFoundation

/// Azure Neural TTS engine. Conforms to the shared `TTSEngine` contract from
/// Contracts.swift and owns its own AVAudioPlayer-based playback.
///
/// `@unchecked Sendable`: every piece of mutable state is touched ONLY on the
/// main thread. `speak`/`stop`/`prewarm` are called by the `@MainActor`
/// `TTSEngineManager`; the URLSession completion and AVAudioPlayer delegate hop
/// back to the main thread (capturing only `[weak self]`) before touching any
/// stored property. The unchecked conformance lets this nonisolated engine
/// satisfy the nonisolated `TTSEngine` protocol (matching the System/Kokoro
/// engines) while it drives UI safely.
final class AzureNeuralEngine: NSObject, TTSEngine, AVAudioPlayerDelegate, @unchecked Sendable {

    // MARK: TTSEngine identity

    var kind: EngineKind { .azure }

    // MARK: Configuration

    private let region: String
    private let voice: String
    /// Returns the Azure subscription key from the Keychain, or nil. Injected so
    /// the engine never touches the Keychain or holds the secret beyond a call.
    private let keyProvider: () -> String?

    // MARK: Playback state

    private var player: AVAudioPlayer?
    private var wordTimer: Timer?
    private var timestamps: [WordTimestamp] = []
    /// Index of the next timestamp whose `start` we are waiting to cross.
    private var nextTimestampCursor: Int = 0
    private var currentTask: URLSessionDataTask?

    /// Monotonically increasing identity for the in-flight utterance. Captured by
    /// value in the URLSession completion closure so a superseded request (one
    /// whose task was cancelled and whose callbacks were replaced by a newer
    /// `speak`) is detected and dropped before it can clobber the live state.
    /// Bumped on every `speak` and `stop`. The `onStateChange != nil` check is
    /// insufficient because a superseding `speak()` reinstalls callbacks.
    private var requestToken: Int = 0

    // Retained callbacks for the in-flight utterance.
    private var onWord: ((Int) -> Void)?
    private var onStateChange: ((TTSPlaybackState) -> Void)?
    private var onFinish: (() -> Void)?
    private var onError: ((TTSError) -> Void)?

    /// Guards against double-terminal callbacks (finish/error both firing).
    private var hasFinished = false

    private let session: URLSession

    // MARK: Init

    /// - Parameters:
    ///   - region: Azure resource region, e.g. "eastus".
    ///   - voice: Neural voice short name, e.g. "en-US-JennyNeural".
    ///   - keyProvider: Supplies the subscription key from the Keychain. This is
    ///     `Settings.shared.loadAzureKey`. The engine calls it lazily per request
    ///     and never stores the returned key.
    init(region: String, voice: String, keyProvider: @escaping () -> String?) {
        self.region = region
        self.voice = voice
        self.keyProvider = keyProvider
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        self.session = URLSession(configuration: config)
        super.init()
    }

    deinit {
        // A URLSession created via `URLSession(configuration:)` retains internal
        // resources (and its delegate/operation queue) until it is explicitly
        // invalidated; relying on deinit of the session alone does not release
        // them. Cancel any in-flight task and tear down the session so its
        // backing resources are reclaimed instead of leaking.
        currentTask?.cancel()
        wordTimer?.invalidate()
        player?.stop()
        session.invalidateAndCancel()
    }

    // MARK: - Endpoints

    private var ttsEndpoint: URL? {
        URL(string: "https://\(region).tts.speech.microsoft.com/cognitiveservices/v1")
    }

    private var tokenEndpoint: URL? {
        URL(string: "https://\(region).api.cognitive.microsoft.com/sts/v1.0/issueToken")
    }

    // MARK: - Prewarm

    /// Idempotent, non-blocking warm-up. We just validate that a key is present
    /// and kick a lightweight token request to warm DNS/TLS. Never blocks, never
    /// crashes if Azure is unreachable, never surfaces errors here.
    func prewarm() {
        guard let key = keyProvider(), !key.isEmpty, let url = tokenEndpoint else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        // Fire-and-forget. Result is intentionally ignored; this is only a warm-up.
        let task = session.dataTask(with: request) { _, _, _ in }
        task.resume()
    }

    // MARK: - Speak

    func speak(text: String,
               rate: Double,
               onWord: @escaping (Int) -> Void,
               onStateChange: @escaping (TTSPlaybackState) -> Void,
               onFinish: @escaping () -> Void,
               onError: @escaping (TTSError) -> Void) {

        // Begin a new utterance: stop anything already playing (no onFinish).
        stop()

        // Claim a fresh identity for THIS utterance. The completion closure below
        // captures it by value; if a later speak()/stop() bumps `requestToken`,
        // this request's completion is recognized as stale and dropped.
        requestToken &+= 1
        let token = requestToken

        self.onWord = onWord
        self.onStateChange = onStateChange
        self.onFinish = onFinish
        self.onError = onError
        self.hasFinished = false

        // Tokenize the EXACT string we will speak so word indices match the HUD.
        let words = WordTokenizer.tokenize(text)
        guard !words.isEmpty else {
            fail(.emptyText)
            return
        }

        // Key must come from the Keychain. No key => actionable error BEFORE any
        // network call. The key value itself is never logged or echoed.
        guard let key = keyProvider(), !key.isEmpty else {
            fail(.missingCredential(.azure))
            return
        }
        guard let endpoint = ttsEndpoint else {
            fail(.engineUnavailable(.azure, underlying: "Invalid region \"\(region)\"."))
            return
        }

        emitState(.preparing)

        let ssml = Self.makeSSML(text: text, voice: voice, rate: rate)
        guard let ssmlData = ssml.data(using: .utf8) else {
            fail(.other("Couldn't encode the text for Azure."))
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = ssmlData
        request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
        // MP3 is broadly decodable by AVAudioPlayer on macOS.
        request.setValue("audio-24khz-96kbitrate-mono-mp3",
                         forHTTPHeaderField: "X-Microsoft-OutputFormat")
        // Request the WordBoundary metadata stream alongside the audio so the
        // SAME synthesis run yields word timing (avoids a second synth that could
        // drift). Boundaries arrive as multipart/metadata when supported.
        request.setValue("true", forHTTPHeaderField: "X-Microsoft-OutputFormat-Metadata")
        request.setValue("ReadFlow", forHTTPHeaderField: "User-Agent")

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            // Drop this completion entirely if a later speak()/stop() has
            // superseded us. URLSessionDataTask.cancel() is asynchronous and does
            // NOT guarantee the completion won't fire, so without this check a
            // cancelled request could still clobber the live utterance's state.
            // (Reading `requestToken` here off the main thread is a best-effort
            // early-out; the authoritative check happens on the main-thread hop in
            // `startPlayback`/`fail`, which also compares the token.)
            guard self.requestToken == token else { return }

            if let error = error {
                // error.localizedDescription is from URLSession and carries no secret.
                self.fail(.engineUnavailable(.azure, underlying: error.localizedDescription), token: token)
                return
            }

            guard let http = response as? HTTPURLResponse else {
                self.fail(.badResponse(.azure, detail: "No HTTP response."), token: token)
                return
            }

            guard (200...299).contains(http.statusCode) else {
                // Map common Azure status codes to actionable guidance. Do NOT
                // include the request body or key in any message.
                let detail: String
                switch http.statusCode {
                case 401, 403:
                    self.fail(.missingCredential(.azure), token: token)
                    return
                case 429:
                    detail = "Rate limit reached (HTTP 429). Try again shortly."
                default:
                    detail = "HTTP \(http.statusCode)."
                }
                self.fail(.badResponse(.azure, detail: detail), token: token)
                return
            }

            guard let data = data, !data.isEmpty else {
                self.fail(.badResponse(.azure, detail: "Empty audio payload."), token: token)
                return
            }

            // The response may be raw audio OR a multipart body containing both
            // the audio part and WordBoundary metadata parts. Split them.
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
            let parsed = AzureResponseParser.parse(data: data, contentType: contentType)

            // Align boundaries → shared word indices.
            let aligned = Self.alignBoundaries(parsed.boundaries, to: words)

            // If Azure returned no usable boundaries (e.g. an HD voice — see note
            // below), synthesize an even time spread so the highlight still moves
            // rather than freezing. Never leave the user with a dead highlight.
            let finalTimestamps: [WordTimestamp]
            if aligned.isEmpty {
                finalTimestamps = Self.evenlySpacedTimestamps(wordCount: words.count,
                                                              audioData: parsed.audio)
            } else {
                finalTimestamps = aligned
            }

            self.startPlayback(audioData: parsed.audio, timestamps: finalTimestamps, token: token)
        }

        self.currentTask = task
        task.resume()
    }

    // MARK: - Playback

    private func startPlayback(audioData: Data, timestamps: [WordTimestamp], token: Int) {
        // Hop to main: AVAudioPlayer + all callbacks/UI must be on the main thread.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // AUTHORITATIVE stale check: if a later speak()/stop() superseded this
            // request, our captured `token` no longer matches the live one. Bail
            // BEFORE touching player/timestamps/cursor so we never play stale audio
            // wired to a newer utterance's callbacks. The `onStateChange != nil`
            // check is insufficient because a superseding speak() reinstalls it.
            guard self.requestToken == token else { return }
            // If stop() was called while the request was in flight, bail silently.
            guard self.onStateChange != nil else { return }

            let newPlayer: AVAudioPlayer
            do {
                newPlayer = try AVAudioPlayer(data: audioData)
            } catch {
                self.fail(.audioPlaybackFailed(detail: error.localizedDescription))
                return
            }
            newPlayer.delegate = self
            guard newPlayer.prepareToPlay(), newPlayer.play() else {
                self.fail(.audioPlaybackFailed(detail: "AVAudioPlayer refused to start."))
                return
            }

            self.player = newPlayer
            self.timestamps = timestamps.sorted { $0.start < $1.start }
            self.nextTimestampCursor = 0
            self.emitState(.speaking)
            self.startWordTimer()
        }
    }

    /// High-frequency timer (~50 Hz) that compares the player clock to each
    /// pending word's `start` and fires the next due `onWord`. Mirrors Kokoro.
    private func startWordTimer() {
        wordTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 50.0, repeats: true) { [weak self] _ in
            guard let self = self, let player = self.player else { return }
            let now = player.currentTime
            // Fire every timestamp whose start time we've now reached. Several may
            // be due in one tick if words are short.
            while self.nextTimestampCursor < self.timestamps.count,
                  self.timestamps[self.nextTimestampCursor].start <= now {
                let ts = self.timestamps[self.nextTimestampCursor]
                self.onWord?(ts.wordIndex)
                self.nextTimestampCursor += 1
            }
        }
        // Common run-loop mode so it keeps firing during menu tracking, etc.
        RunLoop.main.add(timer, forMode: .common)
        wordTimer = timer
    }

    // MARK: - Stop

    func stop() {
        // Idempotent. Must NOT fire onFinish.
        // Bump the identity so any in-flight request's completion (already
        // dispatched on a background queue before cancel() took effect) is
        // recognized as stale and dropped on its main-thread hop.
        requestToken &+= 1
        currentTask?.cancel()
        currentTask = nil

        wordTimer?.invalidate()
        wordTimer = nil

        player?.stop()
        player?.delegate = nil
        player = nil

        timestamps = []
        nextTimestampCursor = 0

        // Only emit .idle if we were actually doing something.
        let wasActive = (onStateChange != nil)
        // Stash the state callback on `self` (it stays nonisolated mutable state
        // we only touch on main) so the main-thread hop reads it via `[weak self]`
        // rather than capturing the non-Sendable closure into the async block.
        // `hasFinished`/`pendingIdleState` guard against re-entrancy.
        pendingIdleState = onStateChange
        // Clear the live callbacks BEFORE emitting so a late timer can't re-enter.
        onWord = nil
        onStateChange = nil
        onFinish = nil
        onError = nil
        hasFinished = true

        if wasActive {
            // Deliver terminal idle on the main thread.
            if Thread.isMainThread {
                flushPendingIdle()
            } else {
                DispatchQueue.main.async { [weak self] in self?.flushPendingIdle() }
            }
        }
    }

    /// State callback held only across the `stop()` main-thread hop so the async
    /// block captures `[weak self]` instead of a non-Sendable closure.
    private var pendingIdleState: ((TTSPlaybackState) -> Void)?

    private func flushPendingIdle() {
        let cb = pendingIdleState
        pendingIdleState = nil
        cb?(.idle)
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            guard !self.hasFinished else { return }

            if flag {
                // Flush any words whose start we hadn't crossed yet (short tail).
                while self.nextTimestampCursor < self.timestamps.count {
                    self.onWord?(self.timestamps[self.nextTimestampCursor].wordIndex)
                    self.nextTimestampCursor += 1
                }
                self.finishNaturally()
            } else {
                self.fail(.audioPlaybackFailed(detail: "Playback ended unexpectedly."))
            }
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.fail(.audioPlaybackFailed(detail: error?.localizedDescription ?? "Decode error."))
        }
    }

    // MARK: - Terminal helpers (main-thread, single-shot)

    private func finishNaturally() {
        guard !hasFinished else { return }
        hasFinished = true

        wordTimer?.invalidate()
        wordTimer = nil
        player?.delegate = nil
        player = nil

        let stateCB = onStateChange
        let finishCB = onFinish
        clearCallbacks()

        deliverOnMain {
            stateCB?(.finished)
            finishCB?()
        }
    }

    /// Token-checked failure used from the URLSession completion. Drops the error
    /// if a later speak()/stop() superseded this request (so a stale network
    /// failure can't tear down a newer utterance). The token is re-checked on the
    /// main thread because `requestToken` is only authoritative there.
    private func fail(_ error: TTSError, token: Int) {
        deliverOnMain { [weak self] in
            guard let self = self else { return }
            guard self.requestToken == token else { return }
            self.failOnMain(error)
        }
    }

    /// Surface an error to the user (never silently fail) and return to idle.
    private func fail(_ error: TTSError) {
        deliverOnMain { [weak self] in
            guard let self = self else { return }
            self.failOnMain(error)
        }
    }

    /// The actual main-thread failure body. Single-shot via `hasFinished`.
    private func failOnMain(_ error: TTSError) {
        guard !self.hasFinished else { return }
        self.hasFinished = true

        self.currentTask?.cancel()
        self.currentTask = nil
        self.wordTimer?.invalidate()
        self.wordTimer = nil
        self.player?.stop()
        self.player?.delegate = nil
        self.player = nil

        let stateCB = self.onStateChange
        let errorCB = self.onError
        self.clearCallbacks()

        errorCB?(error)
        stateCB?(.idle)
    }

    private func clearCallbacks() {
        onWord = nil
        onStateChange = nil
        onFinish = nil
        onError = nil
        timestamps = []
        nextTimestampCursor = 0
    }

    private func emitState(_ state: TTSPlaybackState) {
        let cb = onStateChange
        deliverOnMain { cb?(state) }
    }

    /// Run `work` on the main thread without double-dispatching if already there.
    private func deliverOnMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }

    // MARK: - SSML

    /// Build SSML for one utterance. `rate` (1.0 == natural) is expressed as a
    /// percentage delta Azure understands. Text is XML-escaped so punctuation
    /// can't break the markup.
    static func makeSSML(text: String, voice: String, rate: Double) -> String {
        // Map normalized rate (0.5...2.0) to a prosody percentage. 1.0 -> +0%,
        // 1.5 -> +50%, 0.5 -> -50%. Clamp to a sane band.
        let clamped = min(max(rate, 0.5), 2.0)
        let percent = Int(((clamped - 1.0) * 100).rounded())
        let ratePercent = percent >= 0 ? "+\(percent)%" : "\(percent)%"

        // Derive xml:lang from the voice name's locale prefix (e.g. "en-US").
        let lang = Self.locale(fromVoice: voice)
        let escaped = Self.xmlEscape(text)

        return """
        <speak version="1.0" xmlns="http://www.w3.org/2001/10/synthesis" xml:lang="\(lang)">
          <voice name="\(voice)">
            <prosody rate="\(ratePercent)">\(escaped)</prosody>
          </voice>
        </speak>
        """
    }

    /// Extract "language-REGION" (first two hyphenated components) from a voice
    /// short name like "en-US-JennyNeural". Falls back to "en-US".
    static func locale(fromVoice voice: String) -> String {
        let parts = voice.split(separator: "-")
        if parts.count >= 2 {
            return "\(parts[0])-\(parts[1])"
        }
        return "en-US"
    }

    static func xmlEscape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }

    // MARK: - Boundary alignment

    /// Align Azure WordBoundary events to the shared `[Word]` tokenization.
    ///
    /// Azure emits one WordBoundary per spoken token in spoken order — INCLUDING a
    /// separate boundary for punctuation (",", ".", etc.). Our shared tokenizer
    /// splits on whitespace and keeps punctuation GLUED to its word ("Hello," is
    /// ONE word). So for normal multi-sentence prose Azure's boundary count `n`
    /// exceeds the shared word count `m`, and a count-ratio map would skip/double
    /// words and desync almost immediately.
    ///
    /// We therefore align by TEXT with a monotonic two-pointer walk: we advance a
    /// shared-word cursor and consume/merge consecutive boundary tokens whose
    /// concatenated (normalized) text matches the next shared word's text. Each
    /// shared word receives the start time of its FIRST contributing boundary.
    /// When text matching can't make progress we fall back to a clamped 1:1
    /// positional step (`min(i, m-1)`) — a real prefix correspondence, never a
    /// proportional scatter.
    static func alignBoundaries(_ boundaries: [AzureWordBoundary],
                                to words: [Word]) -> [WordTimestamp] {
        guard !boundaries.isEmpty, !words.isEmpty else { return [] }

        let sorted = boundaries.sorted { $0.offsetTicks < $1.offsetTicks }
        let n = sorted.count
        let m = words.count

        // Precompute each boundary's start (seconds). End is filled later from the
        // next boundary / duration so highlights have a sane span.
        func startSeconds(_ b: AzureWordBoundary) -> TimeInterval {
            Double(b.offsetTicks) / 10_000_000.0
        }
        func endSeconds(forIndex i: Int) -> TimeInterval {
            let b = sorted[i]
            let start = startSeconds(b)
            if b.durationTicks > 0 {
                return start + Double(b.durationTicks) / 10_000_000.0
            } else if i + 1 < n {
                return startSeconds(sorted[i + 1])
            } else {
                return start + 0.25
            }
        }

        var result: [WordTimestamp] = []
        result.reserveCapacity(m)

        var wi = 0   // shared-word cursor
        var bi = 0   // boundary cursor
        while wi < m && bi < n {
            let targetNorm = Self.normalizeForMatch(words[wi].text)
            // The shared word's first contributing boundary's start time.
            let wordStart = startSeconds(sorted[bi])
            var wordEnd = endSeconds(forIndex: bi)

            // Greedily merge boundary tokens until their concatenation matches the
            // shared word (handles punctuation boundaries glued in the shared
            // token, and Azure splitting a hyphenated/numeric word).
            var merged = Self.normalizeForMatch(sorted[bi].text)
            wordEnd = endSeconds(forIndex: bi)
            bi += 1
            var matched = !targetNorm.isEmpty && merged == targetNorm

            // Keep consuming boundaries while the running concatenation is still a
            // strict prefix of the target (more boundary tokens needed) and we
            // haven't matched yet.
            while !matched, bi < n,
                  !targetNorm.isEmpty,
                  targetNorm.hasPrefix(merged),
                  merged.count < targetNorm.count {
                merged += Self.normalizeForMatch(sorted[bi].text)
                wordEnd = endSeconds(forIndex: bi)
                bi += 1
                matched = (merged == targetNorm)
            }

            result.append(WordTimestamp(wordIndex: wi,
                                        start: wordStart,
                                        end: max(wordEnd, wordStart)))
            wi += 1

            // If text matching stalled (couldn't match this word from the
            // boundary stream), fall back to a clamped 1:1 step for the REMAINDER
            // so we keep a real prefix correspondence instead of scattering.
            if !matched && !targetNorm.isEmpty {
                return Self.positionalFallback(sorted: sorted,
                                               wordCount: m,
                                               startOfTail: result,
                                               startSeconds: startSeconds,
                                               endSeconds: endSeconds)
            }
        }

        // Any shared words left without a boundary (Azure emitted fewer than we
        // expected): give them the last known end time so the highlight reaches
        // the end rather than stalling.
        if wi < m {
            let tailStart = result.last.map { $0.end } ?? 0
            let lastEnd = n > 0 ? endSeconds(forIndex: n - 1) : tailStart
            while wi < m {
                result.append(WordTimestamp(wordIndex: wi,
                                            start: tailStart,
                                            end: max(lastEnd, tailStart)))
                wi += 1
            }
        }

        return result
    }

    /// Clamped 1:1 positional mapping (`min(i, m-1)`) used only when text matching
    /// is impossible. Maps the i-th boundary to the i-th shared word, clamping the
    /// tail — a real prefix correspondence, never a proportional ratio.
    private static func positionalFallback(
        sorted: [AzureWordBoundary],
        wordCount m: Int,
        startOfTail prefix: [WordTimestamp],
        startSeconds: (AzureWordBoundary) -> TimeInterval,
        endSeconds: (Int) -> TimeInterval
    ) -> [WordTimestamp] {
        var result: [WordTimestamp] = []
        result.reserveCapacity(sorted.count)
        for (i, b) in sorted.enumerated() {
            let start = startSeconds(b)
            let end = endSeconds(i)
            let mapped = min(i, m - 1)
            result.append(WordTimestamp(wordIndex: mapped, start: start, end: max(end, start)))
        }
        return result
    }

    /// Normalize a token for text comparison: lowercase, strip surrounding
    /// punctuation/whitespace so "Hello," and the boundary tokens "Hello" + ","
    /// concatenate to the same comparable string.
    static func normalizeForMatch(_ s: String) -> String {
        let lowered = s.lowercased()
        let kept = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(kept))
    }

    /// Fallback timing when Azure provides NO word boundaries.
    ///
    /// NOTE ON HD VOICES: Azure's newer "HD"/turbo neural voices (e.g.
    /// "en-US-Ava:DragonHDLatestNeural") frequently DO NOT emit WordBoundary
    /// events, or emit them incompletely, over the v1 REST endpoint — the
    /// boundary stream is reliable on the STANDARD neural voices (e.g.
    /// "en-US-JennyNeural", "en-US-AriaNeural"). When boundaries are missing we
    /// spread word onsets evenly across the audio duration so the highlight still
    /// glides instead of freezing. For tight word-accurate highlighting, prefer a
    /// standard neural voice in Settings.
    static func evenlySpacedTimestamps(wordCount: Int, audioData: Data) -> [WordTimestamp] {
        guard wordCount > 0 else { return [] }
        // Estimate duration from the decoded player; if it can't decode here we
        // fall back to a per-word heuristic (~0.4s/word).
        let duration: TimeInterval
        if let probe = try? AVAudioPlayer(data: audioData), probe.duration > 0 {
            duration = probe.duration
        } else {
            duration = Double(wordCount) * 0.4
        }
        let per = duration / Double(wordCount)
        return (0..<wordCount).map { i in
            let start = Double(i) * per
            return WordTimestamp(wordIndex: i, start: start, end: start + per)
        }
    }
}

// MARK: - Azure WordBoundary model

/// One Azure WordBoundary event. Offsets/durations are in 100-nanosecond ticks
/// as Azure reports them; conversion to seconds happens in `alignBoundaries`.
struct AzureWordBoundary {
    let text: String
    let offsetTicks: Int64
    let durationTicks: Int64
}

// MARK: - Response parsing

/// Splits an Azure synthesis response into audio bytes + WordBoundary events.
///
/// With `X-Microsoft-OutputFormat-Metadata: true` the response is a
/// `multipart/mixed` body: one part is the audio, the other parts carry JSON
/// metadata of `Type: "WordBoundary"` with `{ Data: { Offset, Duration, text } }`
/// (offset/duration in 100ns ticks). When the endpoint instead returns plain
/// audio (no multipart — common when metadata isn't honored), we return the
/// whole body as audio and an empty boundary list, letting the caller fall back
/// to evenly-spaced timing.
enum AzureResponseParser {

    struct Parsed {
        let audio: Data
        let boundaries: [AzureWordBoundary]
    }

    static func parse(data: Data, contentType: String) -> Parsed {
        let lower = contentType.lowercased()
        guard lower.contains("multipart"), let boundary = multipartBoundary(from: contentType) else {
            // Plain audio response.
            return Parsed(audio: data, boundaries: [])
        }

        let parts = splitMultipart(data: data, boundary: boundary)
        var audio = Data()
        var boundaries: [AzureWordBoundary] = []

        for part in parts {
            let headerLower = String(decoding: part.headers, as: UTF8.self).lowercased()
            if headerLower.contains("application/json") || headerLower.contains("metadata") {
                boundaries.append(contentsOf: parseBoundaries(from: part.body))
            } else if headerLower.contains("audio") || audio.isEmpty {
                // Treat any audio part (or the first non-JSON part) as the audio.
                if headerLower.contains("audio") || !headerLower.contains("json") {
                    audio.append(part.body)
                }
            }
        }

        // Safety: if we somehow found no audio part, use the largest part.
        if audio.isEmpty {
            audio = parts.map { $0.body }.max(by: { $0.count < $1.count }) ?? data
        }
        return Parsed(audio: audio, boundaries: boundaries)
    }

    // MARK: Multipart helpers

    private static func multipartBoundary(from contentType: String) -> String? {
        // e.g. multipart/mixed; boundary=ABCD1234
        guard let range = contentType.range(of: "boundary=", options: .caseInsensitive) else {
            return nil
        }
        var value = String(contentType[range.upperBound...])
        if let semi = value.firstIndex(of: ";") {
            value = String(value[..<semi])
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        return value.isEmpty ? nil : value
    }

    private struct RawPart { let headers: Data; let body: Data }

    private static func splitMultipart(data: Data, boundary: String) -> [RawPart] {
        guard let delimiter = "--\(boundary)".data(using: .utf8) else { return [] }
        let ranges = data.ranges(of: delimiter)
        guard !ranges.isEmpty else { return [] }

        var parts: [RawPart] = []
        for i in 0..<ranges.count {
            let segmentStart = ranges[i].upperBound
            let segmentEnd = (i + 1 < ranges.count) ? ranges[i + 1].lowerBound : data.endIndex
            guard segmentStart < segmentEnd else { continue }
            var segment = data.subdata(in: segmentStart..<segmentEnd)

            // A trailing "--" marks the final boundary; skip empty/terminal chunks.
            if segment.starts(with: Array("--".utf8)) { continue }

            // Strip a leading CRLF/LF left after the boundary line.
            segment = trimLeadingNewlines(segment)

            // Headers and body are separated by a blank line (CRLF CRLF or LF LF).
            if let (headers, body) = splitHeadersAndBody(segment) {
                parts.append(RawPart(headers: headers, body: trimTrailingNewlines(body)))
            }
        }
        return parts
    }

    private static func splitHeadersAndBody(_ segment: Data) -> (Data, Data)? {
        let crlfcrlf = Data("\r\n\r\n".utf8)
        let lflf = Data("\n\n".utf8)
        if let r = segment.firstRange(of: crlfcrlf) {
            return (segment.subdata(in: segment.startIndex..<r.lowerBound),
                    segment.subdata(in: r.upperBound..<segment.endIndex))
        }
        if let r = segment.firstRange(of: lflf) {
            return (segment.subdata(in: segment.startIndex..<r.lowerBound),
                    segment.subdata(in: r.upperBound..<segment.endIndex))
        }
        // No body separator: treat whole thing as headers (no body).
        return (segment, Data())
    }

    private static func trimLeadingNewlines(_ data: Data) -> Data {
        var d = data
        while let first = d.first, first == 0x0D || first == 0x0A {
            d = d.subdata(in: (d.startIndex + 1)..<d.endIndex)
        }
        return d
    }

    private static func trimTrailingNewlines(_ data: Data) -> Data {
        var d = data
        while let last = d.last, last == 0x0D || last == 0x0A {
            d = d.subdata(in: d.startIndex..<(d.endIndex - 1))
        }
        return d
    }

    // MARK: WordBoundary JSON

    /// Parse a metadata part body into WordBoundary events. The body may be a
    /// single JSON object or a sequence of JSON objects (one per line / streamed).
    /// We accept both shapes. Only `Type == "WordBoundary"` entries are kept.
    static func parseBoundaries(from body: Data) -> [AzureWordBoundary] {
        var results: [AzureWordBoundary] = []

        // Try whole-body JSON first (object or array).
        if let obj = try? JSONSerialization.jsonObject(with: body) {
            collectBoundaries(from: obj, into: &results)
            if !results.isEmpty { return results }
        }

        // Fall back to line-delimited JSON objects.
        let text = String(decoding: body, as: UTF8.self)
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            if let obj = try? JSONSerialization.jsonObject(with: data) {
                collectBoundaries(from: obj, into: &results)
            }
        }
        return results
    }

    /// Recursively pull WordBoundary entries out of a decoded JSON value. Azure's
    /// metadata shape is:
    ///   { "Metadata": [ { "Type": "WordBoundary",
    ///                     "Data": { "Offset": <ticks>, "Duration": <ticks>,
    ///                               "text": { "Text": "word" } } } ] }
    /// but field casing has varied across SDK/REST versions, so we read keys
    /// case-insensitively and tolerate both flat and nested text.
    private static func collectBoundaries(from json: Any, into out: inout [AzureWordBoundary]) {
        if let array = json as? [Any] {
            for item in array { collectBoundaries(from: item, into: &out) }
            return
        }
        guard let dict = json as? [String: Any] else { return }
        let ci = caseInsensitive(dict)

        // Descend into a "Metadata" array if present.
        if let metadata = ci["metadata"] {
            collectBoundaries(from: metadata, into: &out)
        }

        let type = (ci["type"] as? String)?.lowercased()
        if type == "wordboundary" {
            // The payload lives under "Data" (sometimes inlined).
            let payload: [String: Any]
            if let data = ci["data"] as? [String: Any] {
                payload = caseInsensitive(data)
            } else {
                payload = ci
            }

            let offset = intValue(payload["offset"] ?? payload["audiooffset"])
            let duration = intValue(payload["duration"])
            let wordText = extractText(payload["text"]) ?? (payload["text"] as? String) ?? ""

            if offset != nil {
                out.append(AzureWordBoundary(text: wordText,
                                             offsetTicks: offset ?? 0,
                                             durationTicks: duration ?? 0))
            }
        }
    }

    private static func extractText(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let d = value as? [String: Any] {
            let ci = caseInsensitive(d)
            return ci["text"] as? String
        }
        return nil
    }

    private static func caseInsensitive(_ dict: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in dict { out[k.lowercased()] = v }
        return out
    }

    private static func intValue(_ value: Any?) -> Int64? {
        if let i = value as? Int64 { return i }
        if let i = value as? Int { return Int64(i) }
        if let d = value as? Double { return Int64(d) }
        if let n = value as? NSNumber { return n.int64Value }
        if let s = value as? String { return Int64(s) }
        return nil
    }
}

// MARK: - Data search shims

private extension Data {
    /// All non-overlapping ranges where `pattern` occurs.
    func ranges(of pattern: Data) -> [Range<Index>] {
        guard !pattern.isEmpty else { return [] }
        var result: [Range<Index>] = []
        var searchStart = startIndex
        while searchStart < endIndex,
              let r = range(of: pattern, options: [], in: searchStart..<endIndex) {
            result.append(r)
            searchStart = r.upperBound
        }
        return result
    }

    /// First range where `pattern` occurs.
    func firstRange(of pattern: Data) -> Range<Index>? {
        guard !pattern.isEmpty else { return nil }
        return range(of: pattern, options: [], in: startIndex..<endIndex)
    }
}
