//
//  KokoroEngine.swift
//  ReadFlow
//
//  Natural-voice upgrade via a LOCAL Kokoro-FastAPI instance — STREAMING.
//
//  Instead of synthesizing a whole passage in one (slow, timeout-prone) request,
//  this splits the text into small chunks at sentence boundaries and pipelines
//  them: the FIRST chunk is tiny so audio starts in ~1-2s, and later chunks are
//  synthesized in the background while earlier ones play. The result is a long
//  article that begins reading almost immediately and never times out.
//
//  Each chunk is one POST to /dev/captioned_speech (speed 1.0). The per-word
//  timestamps it returns are aligned to the chunk's slice of the SHARED `[Word]`
//  tokenization and carry GLOBAL word indices, so the HUD highlight tracks across
//  chunk boundaries. Speed is applied LIVE via the AVAudioPlayer's rate, so
//  changing speed never re-synthesizes.
//
//  Apple frameworks only. All four engine callbacks are delivered on the main
//  thread. `@unchecked Sendable`: all mutable state is touched on the main thread
//  only (network completions hop to main before touching anything).
//

import Foundation
import AVFoundation

final class KokoroEngine: NSObject, TTSEngine, AVAudioPlayerDelegate, @unchecked Sendable {

    let kind: EngineKind = .kokoro

    // MARK: Configuration
    private let baseURL: URL
    private let voice: String
    private let session: URLSession

    // MARK: Chunking
    private struct Chunk { let text: String; let words: [Word] }
    private struct Synth { let audio: Data; let timestamps: [WordTimestamp] }

    private var chunks: [Chunk] = []
    private var results: [Int: Synth] = [:]          // synthesized chunks by index
    private var inFlight: [Int: URLSessionDataTask] = [:]
    private var playIndex = 0                          // chunk currently playing / awaited
    private var generation = 0                         // bumped on stop to drop stale callbacks
    private var startedSpeaking = false
    private static let prefetchAhead = 2

    // MARK: Current-chunk playback
    private var player: AVAudioPlayer?
    private var wordTimer: Timer?
    private var timestamps: [WordTimestamp] = []
    private var nextTimestamp = 0
    private var tempAudioURL: URL?
    private var currentRate: Double = 1.0

    // MARK: Callbacks for the active utterance
    private var onWord: ((Int) -> Void)?
    private var onStateChange: ((TTSPlaybackState) -> Void)?
    private var onFinish: (() -> Void)?
    private var onError: ((TTSError) -> Void)?

    private static let timerInterval: TimeInterval = 0.02

    // MARK: Init
    init(baseURL: URL, voice: String) {
        self.baseURL = baseURL
        self.voice = voice
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 240
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        super.init()
    }

    deinit {
        wordTimer?.invalidate()
        inFlight.values.forEach { $0.cancel() }
        player?.stop()
        if let url = tempAudioURL { try? FileManager.default.removeItem(at: url) }
        session.invalidateAndCancel()
    }

    // MARK: prewarm
    func prewarm() {
        var request = URLRequest(url: captionedSpeechEndpoint())
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        session.dataTask(with: request) { _, _, _ in }.resume()
    }

    // MARK: speak (streaming)
    func speak(text: String,
               rate: Double,
               onWord: @escaping (Int) -> Void,
               onStateChange: @escaping (TTSPlaybackState) -> Void,
               onFinish: @escaping () -> Void,
               onError: @escaping (TTSError) -> Void) {

        stop()  // supersede anything in flight (bumps generation)

        self.onWord = onWord
        self.onStateChange = onStateChange
        self.onFinish = onFinish
        self.onError = onError
        self.currentRate = min(max(rate, 0.5), 2.0)

        let words = WordTokenizer.tokenize(text)
        guard !words.isEmpty else { deliverError(.emptyText); return }

        chunks = Self.makeChunks(text: text, words: words)
        guard !chunks.isEmpty else { deliverError(.emptyText); return }
        KoeLog.d("kokoro: speak — \(chunks.count) chunks")

        let gen = generation
        playIndex = 0
        startedSpeaking = false
        deliverState(.preparing)

        // Kick off the first couple of chunks; the first is small for a fast start.
        for i in 0..<min(1 + Self.prefetchAhead, chunks.count) { request(i, gen: gen) }
    }

    // MARK: live rate
    func updateRate(_ rate: Double) {
        currentRate = min(max(rate, 0.5), 2.0)
        player?.rate = Float(currentRate)
    }

    // MARK: stop
    func stop() {
        generation &+= 1
        wordTimer?.invalidate(); wordTimer = nil
        inFlight.values.forEach { $0.cancel() }
        inFlight = [:]
        results = [:]
        chunks = []
        playIndex = 0
        startedSpeaking = false

        player?.delegate = nil
        player?.stop()
        player = nil
        if let url = tempAudioURL { try? FileManager.default.removeItem(at: url); tempAudioURL = nil }
        timestamps = []
        nextTimestamp = 0

        onWord = nil; onStateChange = nil; onFinish = nil; onError = nil
    }

    // MARK: - Per-chunk synthesis request

    private func request(_ i: Int, gen: Int) {
        guard i >= 0, i < chunks.count else { return }
        guard inFlight[i] == nil, results[i] == nil else { return }   // no dup work

        guard let body = makeRequestBody(text: chunks[i].text) else {
            deliverError(.other("Couldn't encode the Kokoro request.")); return
        }
        var req = URLRequest(url: captionedSpeechEndpoint())
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = body

        let chunkWords = chunks[i].words
        let task = session.dataTask(with: req) { [weak self] data, response, error in
            let errorInfo: (code: Int, message: String)? = (error as NSError?).map { ($0.code, $0.localizedDescription) }
            let status = (response as? HTTPURLResponse)?.statusCode
            let hasResponse = response != nil
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.inFlight[i] = nil
                self.handleChunkResponse(i, data: data, httpStatus: status, hasResponse: hasResponse,
                                         errorInfo: errorInfo, words: chunkWords, gen: gen)
            }
        }
        inFlight[i] = task
        task.resume()
        KoeLog.d("kokoro: request chunk \(i) (\(chunks[i].words.count)w)")
    }

    private func handleChunkResponse(_ i: Int, data: Data?, httpStatus: Int?, hasResponse: Bool,
                                     errorInfo: (code: Int, message: String)?, words: [Word], gen: Int) {
        if let errorInfo {
            if errorInfo.code == NSURLErrorCancelled { return }
            deliverError(.engineUnavailable(.kokoro, underlying: friendlyURLError(code: errorInfo.code, fallback: errorInfo.message)))
            return
        }
        guard hasResponse, let status = httpStatus else {
            deliverError(.engineUnavailable(.kokoro, underlying: "No response from server.")); return
        }
        guard (200...299).contains(status) else { deliverError(.badResponse(.kokoro, detail: "HTTP \(status)")); return }
        guard let data, !data.isEmpty else { deliverError(.badResponse(.kokoro, detail: "Empty response body.")); return }

        let decoded: DecodedPayload
        do { decoded = try parsePayload(data) }
        catch let e as TTSError { deliverError(e); return }
        catch { deliverError(.badResponse(.kokoro, detail: "Malformed JSON payload.")); return }

        guard let audioData = Data(base64Encoded: decoded.audioBase64) else {
            deliverError(.badResponse(.kokoro, detail: "Audio was not valid base64.")); return
        }
        let aligned = alignTimestamps(decoded.words, to: words)
        results[i] = Synth(audio: audioData, timestamps: aligned)
        KoeLog.d("kokoro: chunk \(i) READY (ts=\(aligned.count)) playIndex=\(playIndex) player=\(player != nil)")

        // If this is the chunk we're waiting to play, start it now.
        if i == playIndex && player == nil { beginPlay(playIndex, gen: gen) }
    }

    // MARK: - Playback of a chunk

    private func beginPlay(_ i: Int, gen: Int) {
        guard gen == generation, let result = results[i] else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("readflow-kokoro-\(UUID().uuidString).wav")
        do { try result.audio.write(to: url, options: .atomic) }
        catch { deliverError(.audioPlaybackFailed(detail: "Couldn't stage audio: \(error.localizedDescription)")); return }
        tempAudioURL = url

        let newPlayer: AVAudioPlayer
        do { newPlayer = try AVAudioPlayer(contentsOf: url) }
        catch {
            try? FileManager.default.removeItem(at: url); tempAudioURL = nil
            deliverError(.audioPlaybackFailed(detail: error.localizedDescription)); return
        }
        newPlayer.delegate = self
        newPlayer.enableRate = true
        newPlayer.rate = Float(min(max(currentRate, 0.5), 2.0))
        newPlayer.prepareToPlay()
        guard newPlayer.play() else {
            try? FileManager.default.removeItem(at: url); tempAudioURL = nil
            deliverError(.audioPlaybackFailed(detail: "AVAudioPlayer refused to start.")); return
        }

        player = newPlayer
        timestamps = result.timestamps.sorted { $0.start < $1.start }
        nextTimestamp = 0
        results[i] = nil   // free the audio data once staged

        if !startedSpeaking { deliverState(.speaking); startedSpeaking = true }
        startWordTimer()
        KoeLog.d("kokoro: PLAY chunk \(i) (dur=\(String(format: "%.1f", player?.duration ?? 0))s)")

        // Keep the pipeline full.
        for j in (i + 1)...(i + Self.prefetchAhead) where j < chunks.count { request(j, gen: gen) }
    }

    private func startWordTimer() {
        wordTimer?.invalidate()
        let timer = Timer(timeInterval: Self.timerInterval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        wordTimer = timer
    }

    private func tick() {
        guard let player else { return }
        let now = player.currentTime
        while nextTimestamp < timestamps.count, timestamps[nextTimestamp].start <= now {
            let idx = timestamps[nextTimestamp].wordIndex
            nextTimestamp += 1
            onWord?(idx)
        }
    }

    // MARK: AVAudioPlayerDelegate
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let playerID = ObjectIdentifier(player)
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == playerID else { return }
            if flag { self.advanceToNextChunk() }
            else { self.deliverError(.audioPlaybackFailed(detail: "Playback ended unexpectedly.")) }
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let detail = error?.localizedDescription ?? "Audio decode error."
        let playerID = ObjectIdentifier(player)
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == playerID else { return }
            self.deliverError(.audioPlaybackFailed(detail: detail))
        }
    }

    /// Current chunk finished: flush its trailing words, then play the next chunk
    /// (or wait for it to finish synthesizing, or end the utterance).
    private func advanceToNextChunk() {
        while nextTimestamp < timestamps.count { onWord?(timestamps[nextTimestamp].wordIndex); nextTimestamp += 1 }

        // Tear down the just-finished player (keep callbacks + pending results).
        wordTimer?.invalidate(); wordTimer = nil
        player?.delegate = nil; player?.stop(); player = nil
        if let url = tempAudioURL { try? FileManager.default.removeItem(at: url); tempAudioURL = nil }
        timestamps = []; nextTimestamp = 0

        let gen = generation
        playIndex += 1
        if playIndex >= chunks.count { KoeLog.d("kokoro: all \(chunks.count) chunks done"); finishAll(); return }

        KoeLog.d("kokoro: advance -> chunk \(playIndex) hasResult=\(results[playIndex] != nil) inflight=\(inFlight[playIndex] != nil)")
        if results[playIndex] != nil {
            beginPlay(playIndex, gen: gen)               // next chunk already synthesized
        } else {
            request(playIndex, gen: gen)                 // not ready — fetch; beginPlay fires on arrival
        }
    }

    private func finishAll() {
        let finish = onFinish
        wordTimer?.invalidate(); wordTimer = nil
        player?.delegate = nil; player?.stop(); player = nil
        if let url = tempAudioURL { try? FileManager.default.removeItem(at: url); tempAudioURL = nil }
        chunks = []; results = [:]; timestamps = []; nextTimestamp = 0
        deliverState(.finished)
        finish?()
        onWord = nil; onStateChange = nil; onFinish = nil; onError = nil
    }

    // MARK: - Callback delivery (main thread)
    private func deliverState(_ state: TTSPlaybackState) {
        if Thread.isMainThread { onStateChange?(state) }
        else { DispatchQueue.main.async { [weak self] in self?.onStateChange?(state) } }
    }

    private func deliverError(_ error: TTSError) {
        if Thread.isMainThread { deliverErrorOnMain(error) }
        else { DispatchQueue.main.async { [weak self] in self?.deliverErrorOnMain(error) } }
    }

    private func deliverErrorOnMain(_ error: TTSError) {
        KoeLog.d("kokoro ERROR: \(error.errorDescription ?? "?")")
        let handler = onError
        generation &+= 1
        wordTimer?.invalidate(); wordTimer = nil
        inFlight.values.forEach { $0.cancel() }; inFlight = [:]
        results = [:]; chunks = []
        player?.delegate = nil; player?.stop(); player = nil
        if let url = tempAudioURL { try? FileManager.default.removeItem(at: url); tempAudioURL = nil }
        timestamps = []; nextTimestamp = 0
        onStateChange?(.idle)
        handler?(error)
        onWord = nil; onStateChange = nil; onFinish = nil; onError = nil
    }

    // MARK: - Chunking

    /// Group words into chunks at sentence boundaries. The FIRST chunk is small
    /// (fast first audio); later chunks are larger (fewer requests). Each chunk's
    /// text is the exact original substring spanning its words.
    private static func makeChunks(text: String, words: [Word]) -> [Chunk] {
        var chunks: [Chunk] = []
        var current: [Word] = []
        func target(_ chunkIndex: Int) -> Int { chunkIndex == 0 ? 12 : 60 }

        for w in words {
            current.append(w)
            let endsSentence = w.text.last.map { ".!?".contains($0) } ?? false
            if endsSentence, current.count >= target(chunks.count) {
                chunks.append(makeChunk(current, in: text)); current = []
            }
        }
        if !current.isEmpty { chunks.append(makeChunk(current, in: text)) }
        return chunks
    }

    private static func makeChunk(_ words: [Word], in text: String) -> Chunk {
        let lo = words.first!.range.lowerBound
        let hi = words.last!.range.upperBound
        return Chunk(text: String(text[lo..<hi]), words: words)
    }

    // MARK: - Request / payload modeling

    private func captionedSpeechEndpoint() -> URL {
        baseURL.appendingPathComponent("dev").appendingPathComponent("captioned_speech")
    }

    private func makeRequestBody(text: String) -> Data? {
        let payload: [String: Any] = [
            "model": "kokoro", "input": text, "voice": voice,
            "response_format": "wav", "speed": 1.0, "stream": false, "return_timestamps": true
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [])
    }

    private struct ServerWord { let text: String; let start: TimeInterval; let end: TimeInterval }
    private struct DecodedPayload { let audioBase64: String; let words: [ServerWord] }

    private func parsePayload(_ data: Data) throws -> DecodedPayload {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TTSError.badResponse(.kokoro, detail: "Top-level JSON was not an object.")
        }
        let audioKeys = ["audio", "audio_base64", "audio_content", "data"]
        guard let audioBase64 = audioKeys.lazy.compactMap({ root[$0] as? String }).first, !audioBase64.isEmpty else {
            throw TTSError.badResponse(.kokoro, detail: "Missing base64 audio field.")
        }
        let tsKeys = ["timestamps", "word_timestamps", "words"]
        let rawList = tsKeys.lazy.compactMap { root[$0] as? [[String: Any]] }.first ?? []
        let words: [ServerWord] = rawList.compactMap { entry in
            let text = (entry["word"] as? String) ?? (entry["text"] as? String) ?? (entry["token"] as? String) ?? ""
            let start = doubleValue(entry["start_time"]) ?? doubleValue(entry["start"]) ?? doubleValue(entry["startTime"])
            let end = doubleValue(entry["end_time"]) ?? doubleValue(entry["end"]) ?? doubleValue(entry["endTime"])
            guard let start else { return nil }
            return ServerWord(text: text, start: start, end: end ?? start)
        }
        return DecodedPayload(audioBase64: audioBase64, words: words)
    }

    private func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }

    // MARK: - Alignment (returns GLOBAL word indices via Word.index)

    private func alignTimestamps(_ serverWords: [ServerWord], to words: [Word]) -> [WordTimestamp] {
        guard !words.isEmpty, !serverWords.isEmpty else { return [] }
        let m = words.count, n = serverWords.count
        var result: [WordTimestamp] = []; result.reserveCapacity(m)
        var wi = 0, si = 0
        while wi < m && si < n {
            let targetNorm = Self.normalizeForMatch(words[wi].text)
            let wordStart = max(0, serverWords[si].start)
            var wordEnd = max(serverWords[si].start, serverWords[si].end)
            var merged = Self.normalizeForMatch(serverWords[si].text)
            si += 1
            var matched = !targetNorm.isEmpty && merged == targetNorm
            while !matched, si < n, !targetNorm.isEmpty, targetNorm.hasPrefix(merged), merged.count < targetNorm.count {
                merged += Self.normalizeForMatch(serverWords[si].text)
                wordEnd = max(wordEnd, max(serverWords[si].start, serverWords[si].end))
                si += 1
                matched = (merged == targetNorm)
            }
            result.append(WordTimestamp(wordIndex: words[wi].index, start: wordStart, end: max(wordEnd, wordStart)))
            wi += 1
            if !matched && !targetNorm.isEmpty { return Self.positionalFallback(serverWords, words: words) }
        }
        if wi < m {
            let tailStart = result.last.map { $0.end } ?? 0
            let lastEnd = serverWords.last.map { max($0.start, $0.end) } ?? tailStart
            while wi < m { result.append(WordTimestamp(wordIndex: words[wi].index, start: tailStart, end: max(lastEnd, tailStart))); wi += 1 }
        }
        return result
    }

    private static func positionalFallback(_ serverWords: [ServerWord], words: [Word]) -> [WordTimestamp] {
        let maxPos = words.count - 1
        return serverWords.enumerated().map { position, sw in
            WordTimestamp(wordIndex: words[min(position, maxPos)].index,
                          start: max(0, sw.start), end: max(sw.start, sw.end))
        }
    }

    private static func normalizeForMatch(_ s: String) -> String {
        let lowered = s.lowercased()
        let kept = lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(kept))
    }

    private func friendlyURLError(code: Int, fallback: String) -> String {
        switch code {
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
            return "Couldn't reach the Kokoro server. Is it running on \(baseURL.absoluteString)?"
        case NSURLErrorTimedOut: return "The Kokoro server timed out."
        case NSURLErrorNetworkConnectionLost: return "Connection to the Kokoro server was lost."
        default: return fallback
        }
    }
}
