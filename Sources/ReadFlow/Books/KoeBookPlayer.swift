import Foundation
import AVFoundation
import Combine

@MainActor
final class KoeBookPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var chapter: KoeBookChapter?
    @Published var page = 1
    @Published var seconds: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = false
    @Published var zoom: Double = 1
    @Published var rate: Float = 1 { didSet { audio?.rate = rate; kokoro?.updateRate(Double(rate)) } }
    @Published var followPages = true
    @Published var error: String?
    @Published private(set) var voiceSource: KoeBookVoiceSource = .recorded
    @Published private(set) var kokoroWord = 0
    @Published private(set) var wordCount = 0
    @Published private(set) var preparing = false
    var onSave: ((String, KoeBookPlace) -> Void)?
    var onFinished: (() -> Void)?
    private var bookID: String?
    private var pageCount = 1
    private var audio: AVAudioPlayer?
    private var clock: Timer?
    private var lastSaved = Date.distantPast
    private var kokoro: KokoroEngine?
    private var words: [Word] = []
    private var folder: URL?
    private var generation = 0
    private let settings: Settings
    private var playingKokoroVoice: String?

    init(settings: Settings? = nil) { self.settings = settings ?? .shared; super.init() }

    var canPlay: Bool { voiceSource == .kokoro ? wordCount > 0 : chapter?.audioFile != nil }
    var canFollowPages: Bool {
        guard let chapter else { return false }
        return voiceSource == .kokoro ? chapter.mappingConfidence >= 0.85 && !chapter.pageSpans.isEmpty : chapter.canFollowPages
    }
    var position: Double { voiceSource == .kokoro ? Double(kokoroWord) : seconds }
    var positionLimit: Double { voiceSource == .kokoro ? Double(max(1, wordCount - 1)) : max(1, duration) }
    var voiceDetail: String { voiceSource == .kokoro ? "Kokoro · \(KoeBookVoiceSource.kokoroVoiceName(playingKokoroVoice ?? settings.kokoroVoice))" : "Audiobook Narrator" }

    func load(book: KoeBook, chapter: KoeBookChapter, folder: URL, place: KoeBookPlace?, source: KoeBookVoiceSource? = nil) {
        saveAndPause(); audio = nil; duration = 0; error = nil
        self.chapter = chapter; bookID = book.id; pageCount = book.pageCount
        self.folder = folder; words = WordTokenizer.tokenize(chapter.sourceText); wordCount = words.count
        voiceSource = source ?? place?.voiceSource ?? .recorded
        kokoroWord = min(max(0, wordCount - 1), max(0, place?.kokoroWord ?? 0))
        page = min(book.pageCount, max(1, place?.page ?? chapter.pages.first ?? 1))
        zoom = min(3, max(0.5, place?.zoom ?? 1)); rate = min(2, max(0.5, place?.rate ?? 1))
        followPages = canFollowPages && (place?.followPages ?? true); seconds = max(0, place?.seconds ?? 0)
        loadRecording(chapter, folder: folder)
        save()
    }
    private func loadRecording(_ chapter: KoeBookChapter, folder: URL) {
        if let filename = chapter.audioFile {
            do {
                let player = try AVAudioPlayer(contentsOf: folder.appendingPathComponent("audio").appendingPathComponent(filename))
                player.delegate = self; player.enableRate = true; player.rate = rate
                duration = player.duration; seconds = min(seconds, duration); player.currentTime = seconds
                player.prepareToPlay(); audio = player
            } catch { self.error = "The cached recording could not be opened. Refresh the book to get it again." }
        } else { seconds = 0 }
    }
    // A narrator recording can finish while Kokoro is playing. Load that option
    // without stopping Kokoro or resetting its source-word position.
    func refreshRecording(_ updated: KoeBookChapter) {
        guard let chapter, chapter.id == updated.id, chapter.textHash == updated.textHash,
              audio == nil, let folder else { return }
        self.chapter = updated; loadRecording(updated, folder: folder); save()
    }
    func play() {
        if voiceSource == .kokoro { playKokoro(); return }
        guard let audio else { error = KoeBookError.missingAudio.localizedDescription; return }
        NotificationCenter.default.post(name: .readFlowStop, object: nil)
        if audio.currentTime >= audio.duration { audio.currentTime = 0; seconds = 0 }
        error = nil; isPlaying = audio.play()
        guard isPlaying else { error = "Koe could not start this recording."; return }
        if clock == nil {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
            RunLoop.main.add(timer, forMode: .common); clock = timer
        }
    }
    func toggle() { isPlaying ? saveAndPause() : play() }
    func saveAndPause() {
        generation &+= 1; kokoro?.stop(); kokoro = nil; preparing = false
        audio?.pause(); isPlaying = false; clock?.invalidate(); clock = nil; save()
    }
    func seek(_ time: Double) {
        guard time.isFinite else { return }
        if voiceSource == .kokoro {
            let resume = isPlaying; saveAndPause()
            kokoroWord = min(max(0, wordCount - 1), max(0, Int(min(Double(wordCount), max(0, time)))))
            updatePage(); save()
            if resume { playKokoro() }
            return
        }
        seconds = min(duration, max(0, time)); audio?.currentTime = seconds
        updatePage(); save()
    }
    func turnPage(_ value: Int) { page = min(pageCount, max(1, value)); followPages = false; save() }
    func resumeFollowing() { followPages = true; updatePage(); save() }
    private func updatePage() {
        guard followPages, let chapter else { return }
        let next: Int?
        if voiceSource == .kokoro, words.indices.contains(kokoroWord) {
            let offset = words[kokoroWord].range.lowerBound.utf16Offset(in: chapter.sourceText)
            next = chapter.pageSpans.last(where: { $0.charStart <= offset && offset < $0.charEnd })?.page
        } else { next = chapter.page(at: seconds) }
        if let next { page = min(pageCount, max(1, next)) }
    }
    func rewind() { seek(voiceSource == .kokoro ? Double(kokoroWord - 20) : seconds - 15) }
    func selectVoice(_ source: KoeBookVoiceSource) {
        guard source != voiceSource else { return }
        saveAndPause(); error = nil
        // Translate by the shared source text, never apply XTTS seconds to Kokoro.
        if source == .kokoro, let chapter,
           let token = chapter.tokens.last(where: { ($0.audioStart ?? .infinity) <= seconds }),
           let index = WordTokenizer.wordIndex(forUTF16Offset: token.charStart, in: chapter.sourceText, words: words) { kokoroWord = index }
        if source == .recorded, let chapter, words.indices.contains(kokoroWord) {
            let offset = words[kokoroWord].range.lowerBound.utf16Offset(in: chapter.sourceText)
            if let time = chapter.tokens.last(where: { $0.charStart <= offset && $0.audioStart != nil })?.audioStart {
                seconds = min(duration, time); audio?.currentTime = seconds
            }
        }
        voiceSource = source; followPages = canFollowPages && followPages
        updatePage(); save()
    }
    private func playKokoro() {
        guard let chapter, let folder, wordCount > 0 else { return }
        NotificationCenter.default.post(name: .readFlowStop, object: nil)
        generation &+= 1; let token = generation
        playingKokoroVoice = settings.kokoroVoice
        let engine = KokoroEngine(baseURL: settings.kokoroBaseURLValue,
                                  voice: settings.kokoroVoice,
                                  bookCache: folder.appendingPathComponent("kokoro-cache"), stopOnFailure: true)
        kokoro?.stop(); kokoro = engine; error = nil; preparing = true; isPlaying = true
        engine.speakFromWord(text: chapter.sourceText, startingAt: kokoroWord, rate: Double(rate),
            onWord: { [weak self] index in Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.kokoroWord = min(max(0, self.wordCount - 1), max(0, index)); self.updatePage()
                if Date().timeIntervalSince(self.lastSaved) >= 5 { self.save() }
            } },
            onStateChange: { [weak self] state in Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.preparing = state == .preparing
            } },
            onFinish: { [weak self] in Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.kokoroWord = max(0, self.wordCount - 1); self.saveAndPause(); self.onFinished?()
            } },
            onError: { [weak self] problem in Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.saveAndPause(); self.error = problem.localizedDescription + " Retry, or choose Audiobook Narrator."
            } })
    }
    private func tick() {
        guard isPlaying, let audio else { return }; seconds = audio.currentTime; updatePage()
        if Date().timeIntervalSince(lastSaved) >= 5 { save() }
    }
    func save() {
        guard let bookID, let chapter else { return }
        onSave?(bookID, KoeBookPlace(chapterId: chapter.id, page: page, seconds: seconds, zoom: zoom, rate: rate, followPages: followPages, voiceSource: voiceSource, kokoroWord: kokoroWord))
        lastSaved = Date()
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.audio.map(ObjectIdentifier.init) == identity else { return }
            self.seconds = self.duration; self.saveAndPause()
            if flag { self.onFinished?() } else { self.error = "The recording stopped unexpectedly." }
        }
    }
}
