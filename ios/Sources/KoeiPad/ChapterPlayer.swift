import AVFoundation
import Combine
import Foundation
import MediaPlayer

/// Plays a chapter with either the narrator recording from Core or the Kokoro
/// voice on the LAN, drives the word highlight, estimates the PDF page, and
/// saves the place. Two voices, one highlight index space per voice:
/// recorded = Core's word tokens, Kokoro = the shared WordTokenizer words.
@MainActor
final class ChapterPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var status = "Loading…"
    @Published var error: String?
    @Published var ready = false
    @Published var isPlaying = false
    @Published var preparing = false
    @Published var seconds: Double = 0
    @Published var duration: Double = 0
    @Published var highlightIndex: Int = -1
    @Published var page: Int = 1
    @Published var followPages = true
    @Published var voiceSource: VoiceSource = .recorded
    @Published var hasRecording = false
    @Published var kokoroWord = 0
    @Published var rate: Float = 1 {
        didSet { audio?.rate = rate; kokoro?.updateRate(Double(rate)); save(); updateNowPlaying() }
    }
    @Published var reading: Reading?
    /// Colour marks on this chapter's text, same model and fingerprint store as the Mac.
    @Published var marks: [KoeTextHighlight] = []
    private var documentID = ""

    private(set) var book: BookInfo?
    private(set) var chapter: Chapter?
    private(set) var tokenRanges: [NSRange] = []
    private(set) var wordRanges: [NSRange] = []
    private(set) var words: [Word] = []
    var highlightRanges: [NSRange] { voiceSource == .kokoro ? wordRanges : tokenRanges }
    var wordCount: Int { words.count }
    var kokoroVoiceName: String { KokoroSettings.voiceName(KokoroSettings.voice) }

    private var client: CoreClient?
    private var audio: AVAudioPlayer?
    private var audioPath: String?
    private var audioLoaded = false
    private var kokoro: KokoroEngine?
    private var generation = 0
    private var clock: Timer?
    private var timed: [(index: Int, start: Double)] = []
    private var textLength = 1
    private var lastCoreSave = Date.distantPast
    private var lastLocalSave = Date.distantPast
    private var remoteCommandsInstalled = false

    // MARK: Load

    func load(client: CoreClient, book: BookInfo, chapters: [Chapter], chapter: Chapter, place: Place?) async {
        self.client = client; self.book = book; self.chapter = chapter
        page = place?.page ?? chapter.firstPage
        followPages = place?.followPages ?? true
        rate = place?.rate ?? 1
        status = "Fetching chapter…"
        do {
            let detail = try await client.chapter(bookId: book.id, chapterId: chapter.id)
            guard let reading = detail.reading else { throw KoeError.missingAudio }
            self.reading = reading
            let text = reading.sourceText
            textLength = max(1, text.utf16.count)
            tokenRanges = reading.tokens.map { NSRange(location: $0.charStart, length: max(0, $0.charEnd - $0.charStart)) }
            timed = reading.tokens.enumerated().compactMap { i, t in t.audioStart.map { (i, $0) } }.sorted { $0.start < $1.start }
            words = WordTokenizer.tokenize(text)
            wordRanges = words.map {
                let start = $0.range.lowerBound.utf16Offset(in: text)
                return NSRange(location: start, length: max(0, $0.range.upperBound.utf16Offset(in: text) - start))
            }
            documentID = KoeHighlightStore.documentID(for: text)
            marks = KoeHighlightStore.load(documentID: documentID, textLength: textLength)
            hasRecording = reading.audioUrl != nil && !timed.isEmpty
            audioPath = reading.audioUrl
            kokoroWord = min(max(0, place?.kokoroWord ?? 0), max(0, words.count - 1))
            seconds = place?.seconds ?? 0
            voiceSource = hasRecording ? (place?.voiceSource ?? .recorded) : .kokoro
            if voiceSource == .recorded { try await loadAudio() }
            configureSession()
            installRemoteCommands()
            updateHighlight()
            ready = true
            status = "Ready"
            updateNowPlaying()
        } catch {
            self.error = error.localizedDescription
            status = "Couldn't load"
        }
    }

    private func loadAudio() async throws {
        guard !audioLoaded, let client, let audioPath, let reading else { return }
        status = "Fetching narration…"
        let file = try await client.cachedFile(path: audioPath, name: "audio/\(reading.id).mp3", mimePrefix: "audio/", maxBytes: 256 * 1024 * 1024)
        let player = try AVAudioPlayer(contentsOf: file)
        player.delegate = self
        player.enableRate = true
        player.rate = rate
        player.prepareToPlay()
        duration = player.duration
        if seconds > 0, seconds < player.duration - 1 { player.currentTime = seconds } else { seconds = 0 }
        audio = player
        audioLoaded = true
    }

    // MARK: Transport

    func play() {
        guard ready else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if voiceSource == .kokoro { playKokoro(); return }
        guard let audio else { return }
        audio.play()
        isPlaying = true
        startClock()
        updateNowPlaying()
    }

    func pause() {
        if voiceSource == .kokoro {
            generation &+= 1
            kokoro?.stop(); kokoro = nil
            preparing = false
        } else {
            audio?.pause()
            stopClock()
            tick()
        }
        isPlaying = false
        save(force: true)
        updateNowPlaying()
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(_ time: Double) {
        guard voiceSource == .recorded, let audio else { return }
        audio.currentTime = min(max(0, time), max(0, audio.duration - 0.05))
        tick()
        save()
        updateNowPlaying()
    }

    /// `index` is into `highlightRanges` for the current voice.
    func seek(toWord index: Int) {
        if voiceSource == .kokoro {
            guard !words.isEmpty else { return }
            kokoroWord = min(max(0, index), words.count - 1)
            highlightIndex = kokoroWord
            updatePage()
            if isPlaying { playKokoro() } else { save() }
            return
        }
        guard let reading, index >= 0, index < reading.tokens.count else { return }
        if let start = reading.tokens[index].audioStart { seek(start); return }
        if let next = timed.first(where: { $0.index >= index }) { seek(next.start) }
    }

    func skipBack() { voiceSource == .kokoro ? seek(toWord: kokoroWord - 20) : seek(seconds - 15) }
    func skipForward() { voiceSource == .kokoro ? seek(toWord: kokoroWord + 20) : seek(seconds + 15) }

    /// Switch voices and carry the position across through the shared text,
    /// never applying narrator seconds to Kokoro or vice versa.
    func selectVoice(_ source: VoiceSource) {
        guard source != voiceSource, let reading else { return }
        let wasPlaying = isPlaying
        if wasPlaying { pause() }
        error = nil
        let text = reading.sourceText
        if source == .kokoro {
            if let token = reading.tokens.last(where: { ($0.audioStart ?? .infinity) <= seconds }),
               let index = WordTokenizer.wordIndex(forUTF16Offset: token.charStart, in: text, words: words) {
                kokoroWord = index
            }
            voiceSource = .kokoro
            updateHighlight(); updatePage(); save(force: true)
            if wasPlaying { play() }
        } else {
            guard hasRecording else { return }
            if words.indices.contains(kokoroWord) {
                let offset = words[kokoroWord].range.lowerBound.utf16Offset(in: text)
                if let time = reading.tokens.last(where: { $0.charStart <= offset && $0.audioStart != nil })?.audioStart { seconds = time }
            }
            voiceSource = .recorded
            Task { @MainActor in
                do {
                    try await loadAudio()
                    if let audio { audio.currentTime = min(seconds, max(0, audio.duration - 0.05)) }
                    status = "Ready"
                    updateHighlight(); updatePage(); save(force: true)
                    if wasPlaying { play() }
                } catch {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    func turnPage(_ delta: Int) {
        let count = book?.pageCount ?? max(page + delta, 1)
        page = min(max(1, page + delta), max(1, count))
        followPages = false
        save()
    }

    func setPage(_ value: Int, manual: Bool) {
        let count = book?.pageCount ?? value
        page = min(max(1, value), max(1, count))
        if manual { followPages = false; save() }
    }

    func resumeFollowing() {
        followPages = true
        updatePage()
        save()
    }

    func stop() {
        generation &+= 1
        kokoro?.stop(); kokoro = nil
        stopClock()
        if isPlaying { audio?.pause(); isPlaying = false }
        preparing = false
        save(force: true)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Marks

    func mark(_ range: NSRange, color: KoeHighlightColor) {
        marks = KoeHighlightOperations.applying(color: color, to: range, in: marks, textLength: textLength)
        KoeHighlightStore.save(marks, documentID: documentID, textLength: textLength)
    }

    func unmark(_ range: NSRange) {
        marks = KoeHighlightOperations.applying(color: nil, to: range, in: marks, textLength: textLength)
        KoeHighlightStore.save(marks, documentID: documentID, textLength: textLength)
    }

    func excerpt(_ mark: KoeTextHighlight) -> String {
        guard let text = reading?.sourceText, let r = Range(mark.range, in: text) else { return "" }
        let s = String(text[r]).replacingOccurrences(of: "\n", with: " ")
        return s.count > 140 ? String(s.prefix(140)) + "…" : s
    }

    /// Jump the voice to the first word of a mark.
    func seek(toMark mark: KoeTextHighlight) {
        let ranges = highlightRanges
        if let i = ranges.firstIndex(where: { NSMaxRange($0) > mark.location }) { seek(toWord: i) }
    }

    // MARK: Kokoro

    private func playKokoro() {
        guard let reading, !words.isEmpty else { return }
        generation &+= 1
        let token = generation
        let cache = CoreClient.cacheRoot.appendingPathComponent("kokoro/\(reading.id)", isDirectory: true)
        let engine = KokoroEngine(baseURL: KokoroSettings.baseURL, voice: KokoroSettings.voice, bookCache: cache, stopOnFailure: true)
        kokoro?.stop(); kokoro = engine
        error = nil; preparing = true; isPlaying = true
        updateNowPlaying()
        engine.speakFromWord(text: reading.sourceText, startingAt: kokoroWord, rate: Double(rate),
            onWord: { [weak self] index in
                guard let self, self.generation == token else { return }
                self.kokoroWord = min(max(0, index), max(0, self.words.count - 1))
                self.highlightIndex = self.kokoroWord
                self.updatePage()
                if Date().timeIntervalSince(self.lastLocalSave) >= 5 { self.save() }
            },
            onStateChange: { [weak self] state in
                guard let self, self.generation == token else { return }
                self.preparing = state == .preparing
            },
            onFinish: { [weak self] in
                guard let self, self.generation == token else { return }
                self.kokoroWord = max(0, self.words.count - 1)
                self.highlightIndex = self.kokoroWord
                self.isPlaying = false; self.preparing = false; self.kokoro = nil
                self.save(force: true); self.updateNowPlaying()
            },
            onError: { [weak self] problem in
                guard let self, self.generation == token else { return }
                self.isPlaying = false; self.preparing = false; self.kokoro = nil
                self.error = problem.localizedDescription + (self.hasRecording ? " Retry, or choose Audiobook Narrator." : " Retry when Kokoro is reachable.")
                self.save(force: true); self.updateNowPlaying()
            })
    }

    // MARK: Clock (recorded voice)

    private func startClock() {
        stopClock()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    private func stopClock() { clock?.invalidate(); clock = nil }

    private func tick() {
        guard voiceSource == .recorded, let audio else { return }
        seconds = audio.currentTime
        updateHighlight()
        if isPlaying, Date().timeIntervalSince(lastCoreSave) > 10 { save() }
    }

    private func updateHighlight() {
        if voiceSource == .kokoro {
            highlightIndex = words.isEmpty ? -1 : kokoroWord
            updatePage()
            return
        }
        guard !timed.isEmpty else { highlightIndex = -1; return }
        var low = 0, high = timed.count
        while low < high { let mid = (low + high) / 2; if timed[mid].start <= seconds + 0.02 { low = mid + 1 } else { high = mid } }
        let next = low > 0 ? timed[low - 1].index : -1
        if next != highlightIndex { highlightIndex = next; updatePage() }
    }

    /// Core knows which pages a chapter spans, not where each word sits, so the
    /// page follows the chapter proportionally by character offset. Approximate
    /// until per-word page spans sync through Core.
    private func updatePage() {
        guard followPages, let chapter, !chapter.sourcePages.isEmpty else { return }
        let ranges = highlightRanges
        guard highlightIndex >= 0, highlightIndex < ranges.count else { return }
        let pages = chapter.sourcePages.sorted()
        let fraction = min(0.999, max(0, Double(ranges[highlightIndex].location) / Double(textLength)))
        let next = pages[Int(fraction * Double(pages.count))]
        if next != page { page = next }
    }

    // MARK: Save

    func save(force: Bool = false) {
        guard let book, let chapter else { return }
        lastLocalSave = Date()
        PlaceStore.save(book.id, Place(chapterId: chapter.id, seconds: seconds, page: page, rate: rate, followPages: followPages,
                                       updatedAt: Date(), voiceSource: voiceSource, kokoroWord: kokoroWord))
        guard voiceSource == .recorded, force || Date().timeIntervalSince(lastCoreSave) > 10 else { return }
        lastCoreSave = Date()
        let bookId = book.id, chapterId = chapter.id, at = seconds
        Task { await client?.saveProgress(bookId: bookId, chapterId: chapterId, seconds: at) }
    }

    // MARK: Audio session, lock screen

    private func configureSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
    }

    private func installRemoteCommands() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        center.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
        center.skipBackwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skipBack() }; return .success }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skipForward() }; return .success }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(e.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let book, let chapter else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: chapter.title,
            MPMediaItemPropertyArtist: book.title,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
        ]
        if voiceSource == .recorded {
            info[MPMediaItemPropertyPlaybackDuration] = duration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = seconds
        }
        if !book.author.isEmpty { info[MPMediaItemPropertyAlbumTitle] = book.author }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.stopClock()
            self.seconds = self.duration
            self.save(force: true)
            self.updateNowPlaying()
        }
    }
}
