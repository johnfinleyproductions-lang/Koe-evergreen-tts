import AVFoundation
import Foundation
import PencilKit
import UIKit

/// Speaks single words instantly as the reading pen passes over them. The
/// System voice is used here on purpose: zero latency, no network.
@MainActor
final class PenVoice {
    static let shared = PenVoice()
    private let synth = AVSpeechSynthesizer()
    private var last = ""

    func speak(_ word: String) {
        let cleaned = word.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        guard !cleaned.isEmpty, cleaned != last else { return }
        last = cleaned
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: cleaned)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.5
        utterance.prefersAssistiveTechnologySettings = false
        synth.speak(utterance)
    }

    func stop() { synth.stopSpeaking(at: .immediate); last = "" }
}

/// Pencil ink per PDF page, kept beside the book cache in Application Support
/// (never inside the PDF). One PKDrawing per (book, page).
enum InkStore {
    private static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koe/ink", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    private static func url(_ bookId: String, page: Int) -> URL {
        let dir = root.appendingPathComponent(bookId, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("page-\(page).drawing")
    }
    static func load(_ bookId: String, page: Int) -> PKDrawing {
        guard let data = try? Data(contentsOf: url(bookId, page: page)), let drawing = try? PKDrawing(data: data) else { return PKDrawing() }
        return drawing
    }
    static func save(_ drawing: PKDrawing, _ bookId: String, page: Int) {
        let target = url(bookId, page: page)
        if drawing.strokes.isEmpty { try? FileManager.default.removeItem(at: target); return }
        try? drawing.dataRepresentation().write(to: target, options: .atomic)
    }
}
