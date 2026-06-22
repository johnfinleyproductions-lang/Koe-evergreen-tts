//
//  ChatterboxEngine.swift
//  ReadFlow
//
//  Optional higher-fidelity voice via a LOCAL Chatterbox-TTS-Server (Resemble
//  "Chatterbox Turbo"), reached over its OpenAI-compatible endpoint:
//
//      POST {base}/v1/audio/speech
//      { "model": "chatterbox", "input": <text>,
//        "voice": "<Name>.wav", "response_format": "mp3" }
//      -> raw MP3 audio bytes (HTTP 200)
//
//  This is NOT the default engine — Kokoro stays default because it's instant
//  and ships native per-word timestamps. Chatterbox trades that for more
//  expressive voices: the server returns ONLY audio (no word timing), so the
//  moving highlight is ESTIMATED by distributing each chunk's measured audio
//  duration across its words (weighted by length). The highlight is therefore
//  approximate, not frame-accurate — fine for following along, not perfect.
//
//  Architecture mirrors KokoroEngine: split the text into sentence chunks and
//  pipeline them (small first chunk for a fast start, larger later chunks),
//  pre-loading each chunk's AVAudioPlayer so handoffs are gapless. All mutable
//  state is touched on the main thread only; network completions hop to main
//  before touching anything. `@unchecked Sendable` is sound for that reason.
//
//  Apple frameworks only. All four engine callbacks are delivered on main.
//

import Foundation
import AVFoundation

final class ChatterboxEngine: NSObject, TTSEngine, AVAudioPlayerDelegate, @unchecked Sendable {

    let kind: EngineKind = .chatterbox

    // MARK: Configuration
    private let baseURL: URL
    private let voice: String        // server filename, e.g. "Abigail.wav"
    private let session: URLSession

    // MARK: Chunking
    private struct Chunk { let text: String; let words: [Word] }
    /// A chunk whose audio has been fetched AND its AVAudioPlayer pre-loaded, with
    /// estimated word timings derived from the (now known) audio duration.
    private struct Ready { let player: AVAudioPlayer; let url: URL; let timestamps: [WordTimestamp] }

    private var chunks: [Chunk] = []
    private var ready: [Int: Ready] = [:]
    private var inFlight: [Int: URLSessionDataTask] = [:]
    private var failed: Set<Int> = []
    private var retries: [Int: Int] = [:]
    private var playIndex = 0
    private var generation = 0
    private var startedSpeaking = false
    // Chatterbox synthesizes one request at a time on the GPU; keep a small
    // pipeline so we stay ahead of playback without piling requests on it.
    private static let maxConcurrent = 2
    private static let maxLead = 5
    private static let maxRetries = 1

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
        // Settings store the bare display name ("Abigail"); the server resolves the
        // voice param as a filename, so append ".wav" if it isn't already present.
        let trimmed = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        self.voice = trimmed.lowercased().hasSuffix(".wav") ? trimmed : trimmed + ".wav"
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
        ready.values.forEach { $0.player.stop(); try? FileManager.default.removeItem(at: $0.url) }
        session.invalidateAndCancel()
    }

    private func clearReady() {
        ready.values.forEach { $0.player.stop(); try? FileManager.default.removeItem(at: $0.url) }
        ready = [:]
    }

    // MARK: prewarm
    /// Cheap connection warm-up: ping the server root. (The MODEL itself stays
    /// loaded in the container, so the first real synthesis is fast in practice;
    /// the only slow case is right after a container restart.)
    func prewarm() {
        var request = URLRequest(url: baseURL)
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

        stop()

        self.onWord = onWord
        self.onStateChange = onStateChange
        self.onFinish = onFinish
        self.onError = onError
        self.currentRate = min(max(rate, 0.5), 2.0)

        let words = WordTokenizer.tokenize(text)
        guard !words.isEmpty else { deliverError(.emptyText); return }

        chunks = Self.makeChunks(text: text, words: words)
        guard !chunks.isEmpty else { deliverError(.emptyText); return }
        failed = []; retries = [:]
        KoeLog.d("chatterbox: speak — \(chunks.count) chunks, voice \(voice)")

        let gen = generation
        playIndex = 0
        startedSpeaking = false
        deliverState(.preparing)
        pump(gen: gen)
    }

    private func pump(gen: Int) {
        guard gen == generation else { return }
        let start = playIndex + (player != nil ? 1 : 0)
        let upper = min(chunks.count, playIndex + Self.maxLead + 1)
        guard start < upper else { return }
        while inFlight.count < Self.maxConcurrent {
            guard let i = (start..<upper).first(where: { ready[$0] == nil && !failed.contains($0) && inFlight[$0] == nil }) else { break }
            request(i, gen: gen)
        }
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
        clearReady()
        chunks = []
        failed = []
        retries = [:]
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
        guard inFlight[i] == nil, ready[i] == nil else { return }

        guard let body = makeRequestBody(text: chunks[i].text) else {
            deliverError(.other("Couldn't encode the Chatterbox request.")); return
        }
        var req = URLRequest(url: speechEndpoint())
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
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
        KoeLog.d("chatterbox: request chunk \(i) (\(chunks[i].words.count)w)")
    }

    private func handleChunkResponse(_ i: Int, data: Data?, httpStatus: Int?, hasResponse: Bool,
                                     errorInfo: (code: Int, message: String)?, words: [Word], gen: Int) {
        if let errorInfo {
            if errorInfo.code == NSURLErrorCancelled { return }
            failChunk(i, gen: gen, detail: friendlyURLError(code: errorInfo.code, fallback: errorInfo.message)); return
        }
        guard hasResponse, let status = httpStatus else { failChunk(i, gen: gen, detail: "no response"); return }
        guard (200...299).contains(status) else { failChunk(i, gen: gen, detail: "HTTP \(status)"); return }
        guard let audioData = data, !audioData.isEmpty else { failChunk(i, gen: gen, detail: "empty audio"); return }

        // Response is raw MP3 bytes. Stage + pre-load the player, then estimate the
        // per-word timing from the player's measured duration.
        guard let prepared = prepare(audio: audioData, words: words) else {
            failChunk(i, gen: gen, detail: "prepare failed"); return
        }
        ready[i] = prepared
        KoeLog.d("chatterbox: chunk \(i) READY (ts=\(prepared.timestamps.count)) playIndex=\(playIndex) player=\(player != nil)")

        if i == playIndex && player == nil { playOrAdvance(gen: gen) }
        pump(gen: gen)
    }

    /// Write the MP3 to a temp file, pre-load an AVAudioPlayer, and distribute the
    /// resulting duration across the chunk's words to build estimated timings.
    private func prepare(audio: Data, words: [Word]) -> Ready? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("readflow-chatterbox-\(UUID().uuidString).mp3")
        do { try audio.write(to: url, options: .atomic) } catch { return nil }
        guard let p = try? AVAudioPlayer(contentsOf: url) else {
            try? FileManager.default.removeItem(at: url); return nil
        }
        p.enableRate = true
        p.prepareToPlay()
        let ts = Self.estimateTimestamps(words: words, duration: p.duration)
        return Ready(player: p, url: url, timestamps: ts)
    }

    /// Estimate per-word onsets by spreading `duration` across `words`, weighting
    /// each word by its character count (longer words take longer to say). This is
    /// the best we can do without server timestamps; it keeps the highlight moving
    /// in step with the audio even if it isn't frame-accurate.
    private static func estimateTimestamps(words: [Word], duration: TimeInterval) -> [WordTimestamp] {
        guard !words.isEmpty, duration > 0 else {
            return words.map { WordTimestamp(wordIndex: $0.index, start: 0, end: 0) }
        }
        let weights = words.map { Double(max(1, $0.text.count)) }
        let total = weights.reduce(0, +)
        guard total > 0 else {
            return words.map { WordTimestamp(wordIndex: $0.index, start: 0, end: duration) }
        }
        var result: [WordTimestamp] = []; result.reserveCapacity(words.count)
        var cursor = 0.0
        for (n, w) in words.enumerated() {
            let start = duration * (cursor / total)
            cursor += weights[n]
            let end = duration * (cursor / total)
            result.append(WordTimestamp(wordIndex: w.index, start: start, end: end))
        }
        return result
    }

    private func failChunk(_ i: Int, gen: Int, detail: String) {
        guard gen == generation else { return }
        let attempts = retries[i] ?? 0
        if attempts < Self.maxRetries {
            retries[i] = attempts + 1
            KoeLog.d("chatterbox: chunk \(i) failed (\(detail)) — retry \(attempts + 1)")
            request(i, gen: gen)
            return
        }
        KoeLog.d("chatterbox: chunk \(i) PERMANENTLY failed (\(detail)) — skipping")
        failed.insert(i)
        inFlight[i] = nil
        if i == playIndex && player == nil { playOrAdvance(gen: gen) }
        pump(gen: gen)
    }

    private func playOrAdvance(gen: Int) {
        guard gen == generation, player == nil else { return }
        while playIndex < chunks.count {
            if ready[playIndex] != nil { beginPlay(playIndex, gen: gen); return }
            if failed.contains(playIndex) { KoeLog.d("chatterbox: skip failed chunk \(playIndex)"); playIndex += 1; continue }
            request(playIndex, gen: gen)
            return
        }
        if startedSpeaking { KoeLog.d("chatterbox: done (\(failed.count) chunk(s) skipped)"); finishAll() }
        else { KoeLog.d("chatterbox: every chunk failed"); deliverError(.engineUnavailable(.chatterbox, underlying: "Couldn't synthesize the text.")) }
    }

    // MARK: - Playback of a chunk

    private func beginPlay(_ i: Int, gen: Int) {
        guard gen == generation, let r = ready[i] else { return }
        ready[i] = nil

        let p = r.player
        p.delegate = self
        p.rate = Float(min(max(currentRate, 0.5), 2.0))
        guard p.play() else {
            try? FileManager.default.removeItem(at: r.url)
            skipCurrentChunk(gen: gen, detail: "play refused"); return
        }

        player = p
        tempAudioURL = r.url
        timestamps = r.timestamps
        nextTimestamp = 0

        if !startedSpeaking { deliverState(.speaking); startedSpeaking = true }
        startWordTimer()
        KoeLog.d("chatterbox: PLAY chunk \(i) (dur=\(String(format: "%.1f", p.duration))s)")

        pump(gen: gen)
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
            self.advanceToNextChunk()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let playerID = ObjectIdentifier(player)
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == playerID else { return }
            self.skipCurrentChunk(gen: self.generation, detail: "decode error")
        }
    }

    private func advanceToNextChunk() {
        while nextTimestamp < timestamps.count { onWord?(timestamps[nextTimestamp].wordIndex); nextTimestamp += 1 }

        wordTimer?.invalidate(); wordTimer = nil
        player?.delegate = nil; player?.stop(); player = nil
        if let url = tempAudioURL { try? FileManager.default.removeItem(at: url); tempAudioURL = nil }
        timestamps = []; nextTimestamp = 0

        let gen = generation
        playIndex += 1
        KoeLog.d("chatterbox: advance -> chunk \(playIndex)")
        playOrAdvance(gen: gen)
    }

    private func skipCurrentChunk(gen: Int, detail: String) {
        guard gen == generation else { return }
        KoeLog.d("chatterbox: skip chunk \(playIndex) at playback (\(detail))")
        failed.insert(playIndex)
        if let r = ready[playIndex] { r.player.stop(); try? FileManager.default.removeItem(at: r.url); ready[playIndex] = nil }
        wordTimer?.invalidate(); wordTimer = nil
        player?.delegate = nil; player?.stop(); player = nil
        if let url = tempAudioURL { try? FileManager.default.removeItem(at: url); tempAudioURL = nil }
        timestamps = []; nextTimestamp = 0
        playIndex += 1
        playOrAdvance(gen: gen)
    }

    private func finishAll() {
        let finish = onFinish
        wordTimer?.invalidate(); wordTimer = nil
        player?.delegate = nil; player?.stop(); player = nil
        if let url = tempAudioURL { try? FileManager.default.removeItem(at: url); tempAudioURL = nil }
        chunks = []; clearReady(); timestamps = []; nextTimestamp = 0
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
        KoeLog.d("chatterbox ERROR: \(error.errorDescription ?? "?")")
        let handler = onError
        generation &+= 1
        wordTimer?.invalidate(); wordTimer = nil
        inFlight.values.forEach { $0.cancel() }; inFlight = [:]
        clearReady(); chunks = []
        player?.delegate = nil; player?.stop(); player = nil
        if let url = tempAudioURL { try? FileManager.default.removeItem(at: url); tempAudioURL = nil }
        timestamps = []; nextTimestamp = 0
        onStateChange?(.idle)
        handler?(error)
        onWord = nil; onStateChange = nil; onFinish = nil; onError = nil
    }

    // MARK: - Chunking (same sentence-boundary ramp as Kokoro)

    private static func makeChunks(text: String, words: [Word]) -> [Chunk] {
        var chunks: [Chunk] = []
        var current: [Word] = []
        func target(_ chunkIndex: Int) -> Int {
            switch chunkIndex { case 0: return 14; case 1: return 22; case 2: return 34; case 3: return 52; default: return 78 }
        }
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

    // MARK: - Request modeling

    private func speechEndpoint() -> URL {
        baseURL.appendingPathComponent("v1").appendingPathComponent("audio").appendingPathComponent("speech")
    }

    private func makeRequestBody(text: String) -> Data? {
        let payload: [String: Any] = [
            "model": "chatterbox", "input": text, "voice": voice, "response_format": "mp3"
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [])
    }

    private func friendlyURLError(code: Int, fallback: String) -> String {
        switch code {
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost:
            return "Couldn't reach the Chatterbox server. Is it running on \(baseURL.absoluteString)?"
        case NSURLErrorTimedOut: return "The Chatterbox server timed out."
        case NSURLErrorNetworkConnectionLost: return "Connection to the Chatterbox server was lost."
        default: return fallback
        }
    }
}
