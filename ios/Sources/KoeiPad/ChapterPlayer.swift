import AVFoundation
import Combine
import Foundation
import MediaPlayer

/// Plays a chapter's recorded narration and turns its word timings into a
/// moving highlight, an estimated PDF page, and a saved place.
@MainActor
final class ChapterPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var status = "Loading…"
    @Published var error: String?
    @Published var ready = false
    @Published var isPlaying = false
    @Published var seconds: Double = 0
    @Published var duration: Double = 0
    @Published var wordIndex: Int = -1
    @Published var page: Int = 1
    @Published var followPages = true
    @Published var rate: Float = 1 { didSet { audio?.rate = rate; save(); updateNowPlaying() } }
    @Published var reading: Reading?

    private(set) var book: BookInfo?
    private(set) var chapter: Chapter?
    private var client: CoreClient?
    private var audio: AVAudioPlayer?
    private var clock: Timer?
    /// (token index, audioStart) for the tokens that carry timing, in time order.
    private var timed: [(index: Int, start: Double)] = []
    private var textLength = 1
    private var lastCoreSave = Date.distantPast
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
            guard let reading = detail.reading, let audioPath = reading.audioUrl else { throw KoeError.missingAudio }
            self.reading = reading
            textLength = max(1, reading.sourceText.utf16.count)
            timed = reading.tokens.enumerated().compactMap { i, t in t.audioStart.map { (i, $0) } }.sorted { $0.start < $1.start }
            status = "Fetching narration…"
            let file = try await client.cachedFile(path: audioPath, name: "audio/\(reading.id).mp3", mimePrefix: "audio/", maxBytes: 256 * 1024 * 1024)
            let player = try AVAudioPlayer(contentsOf: file)
            player.delegate = self
            player.enableRate = true
            player.rate = rate
            player.prepareToPlay()
            duration = player.duration
            if let place, place.chapterId == chapter.id, place.seconds < player.duration - 1 {
                player.currentTime = place.seconds
                seconds = place.seconds
            }
            audio = player
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

    // MARK: Transport

    func play() {
        guard let audio else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        audio.play()
        isPlaying = true
        startClock()
        updateNowPlaying()
    }

    func pause() {
        audio?.pause()
        isPlaying = false
        stopClock()
        tick()
        save(force: true)
        updateNowPlaying()
    }

    func toggle() { isPlaying ? pause() : play() }

    func seek(_ time: Double) {
        guard let audio else { return }
        audio.currentTime = min(max(0, time), max(0, audio.duration - 0.05))
        tick()
        save()
        updateNowPlaying()
    }

    func seek(toWord index: Int) {
        guard let reading, index >= 0, index < reading.tokens.count else { return }
        if let start = reading.tokens[index].audioStart { seek(start); return }
        if let next = timed.first(where: { $0.index >= index }) { seek(next.start) }
    }

    func skipBack() { seek(seconds - 15) }

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
        stopClock()
        if isPlaying { audio?.pause(); isPlaying = false }
        save(force: true)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: Clock

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
        guard let audio else { return }
        seconds = audio.currentTime
        updateHighlight()
        if isPlaying, Date().timeIntervalSince(lastCoreSave) > 10 { save() }
    }

    private func updateHighlight() {
        guard !timed.isEmpty else { wordIndex = -1; return }
        // Last timed token whose start <= now.
        var low = 0, high = timed.count
        while low < high { let mid = (low + high) / 2; if timed[mid].start <= seconds + 0.02 { low = mid + 1 } else { high = mid } }
        let next = low > 0 ? timed[low - 1].index : -1
        if next != wordIndex { wordIndex = next; updatePage() }
    }

    /// Core knows which pages a chapter spans, not where each word sits, so the
    /// page follows the chapter proportionally by character offset. Approximate
    /// until the Mac's per-word page spans sync through Core.
    private func updatePage() {
        guard followPages, let chapter, let reading, wordIndex >= 0, !chapter.sourcePages.isEmpty else { return }
        let pages = chapter.sourcePages.sorted()
        let offset = Double(reading.tokens[wordIndex].charStart)
        let fraction = min(0.999, max(0, offset / Double(textLength)))
        let next = pages[Int(fraction * Double(pages.count))]
        if next != page { page = next }
    }

    // MARK: Save

    func save(force: Bool = false) {
        guard let book, let chapter else { return }
        PlaceStore.save(book.id, Place(chapterId: chapter.id, seconds: seconds, page: page, rate: rate, followPages: followPages, updatedAt: Date()))
        guard force || Date().timeIntervalSince(lastCoreSave) > 10 else { return }
        lastCoreSave = Date()
        let bookId = book.id, chapterId = chapter.id, at = seconds
        Task { await client?.saveProgress(bookId: bookId, chapterId: chapterId, seconds: at) }
    }

    // MARK: Audio session, lock screen

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
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
        center.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.seek((self?.seconds ?? 0) + 15) }; return .success }
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
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: seconds,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
        ]
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
