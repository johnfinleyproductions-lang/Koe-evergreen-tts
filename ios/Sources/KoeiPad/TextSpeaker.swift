import AVFoundation
import Combine
import Foundation

/// Reads any text (a Board snippet, a notebook page, a canvas card) with the
/// shared engines: Kokoro on the LAN or the System voice, both driving the
/// same word index space from WordTokenizer.
@MainActor
final class TextSpeaker: ObservableObject {
    @Published var isPlaying = false
    @Published var preparing = false
    @Published var wordIndex = -1
    @Published var error: String?
    @Published var useKokoro = true
    @Published var rate: Float = 1 { didSet { engine?.updateRate(Double(rate)) } }
    private(set) var text = ""
    private(set) var words: [Word] = []
    private(set) var ranges: [NSRange] = []
    private var engine: TTSEngine?
    private var generation = 0
    private var resumeWord = 0

    func load(_ text: String) {
        stop()
        self.text = text
        words = WordTokenizer.tokenize(text)
        ranges = words.map {
            let start = $0.range.lowerBound.utf16Offset(in: text)
            return NSRange(location: start, length: max(0, $0.range.upperBound.utf16Offset(in: text) - start))
        }
        wordIndex = -1; resumeWord = 0
    }

    func toggle() { isPlaying ? pause() : play() }

    func play(from start: Int? = nil) {
        guard !words.isEmpty else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        engine?.stop()
        generation &+= 1
        let token = generation
        let first = min(max(0, start ?? resumeWord), words.count - 1)
        // Both engines speak a substring; indices come back relative to it.
        let spoken = String(text[words[first].range.lowerBound...])
        let made: TTSEngine = useKokoro
            ? KokoroEngine(baseURL: KokoroSettings.baseURL, voice: KokoroSettings.voice)
            : SystemAVSpeechEngine(voiceID: nil)
        engine = made
        error = nil; preparing = true; isPlaying = true; wordIndex = first
        made.speak(text: spoken, rate: Double(rate),
            onWord: { [weak self] i in
                guard let self, self.generation == token else { return }
                self.wordIndex = min(first + max(0, i), self.words.count - 1)
                self.resumeWord = self.wordIndex
            },
            onStateChange: { [weak self] state in
                guard let self, self.generation == token else { return }
                self.preparing = state == .preparing
            },
            onFinish: { [weak self] in
                guard let self, self.generation == token else { return }
                self.isPlaying = false; self.preparing = false; self.engine = nil
                self.resumeWord = 0; self.wordIndex = -1
            },
            onError: { [weak self] problem in
                guard let self, self.generation == token else { return }
                self.isPlaying = false; self.preparing = false; self.engine = nil
                self.error = problem.localizedDescription
            })
    }

    func pause() {
        generation &+= 1
        engine?.stop(); engine = nil
        isPlaying = false; preparing = false
        resumeWord = max(0, wordIndex)
    }

    func seek(toWord index: Int) {
        guard !words.isEmpty else { return }
        let clamped = min(max(0, index), words.count - 1)
        resumeWord = clamped; wordIndex = clamped
        if isPlaying { play(from: clamped) }
    }

    func stop() {
        generation &+= 1
        engine?.stop(); engine = nil
        isPlaying = false; preparing = false
    }
}
