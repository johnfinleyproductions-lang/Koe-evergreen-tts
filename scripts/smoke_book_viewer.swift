import AppKit
import Foundation
import PDFKit

// The standalone harness omits the capture UI; its debug-only logger is a no-op.
enum KoeLog { static func d(_ message: String) {} }

@main struct KoeBookViewerSmoke {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koe-books-smoke-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KoeBookStore(root: root)
        for folder in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where folder.pathExtension == "koebook" { try store.importPackage(folder) }
        precondition(store.books.count == 2)
        precondition(store.books.reduce(0) { $0 + $1.chapters.count } == 56)
        for book in store.books {
            let pdf = PDFDocument(url: store.directory(book).appendingPathComponent("source.pdf"))!
            precondition(pdf.pageCount == book.pageCount)
            let ready = book.chapters.first { $0.audioFile != nil && $0.pages.count > 1 }!
            precondition(ready.canFollowPages)
            store.open(book, chapterID: ready.id)
            precondition(store.player.duration > 0)
            let midpoint = store.player.duration * 0.6
            store.player.seek(midpoint)
            precondition(store.player.page == ready.page(at: midpoint))
            store.player.turnPage(min(book.pageCount, 7));store.player.zoom = 1.5;store.player.rate = 1.25;store.player.save()
            let restored = KoeBookStore(root: root);restored.open(book)
            precondition(restored.player.chapter?.id == ready.id)
            precondition(restored.player.page == min(book.pageCount, 7))
            precondition(abs(restored.player.seconds - midpoint) < 0.1)
            precondition(restored.player.zoom == 1.5 && restored.player.rate == 1.25 && !restored.player.followPages)
            restored.player.saveAndPause();store.player.saveAndPause()
            let legacy = try JSONDecoder().decode(KoeBookPlace.self, from: Data("{\"chapterId\":\"\(ready.id)\",\"page\":1,\"seconds\":12,\"zoom\":1,\"rate\":1,\"followPages\":true}".utf8))
            precondition(legacy.voiceSource == nil && legacy.kokoroWord == nil)
            store.player.selectVoice(.kokoro)
            precondition(store.player.canPlay && store.player.canFollowPages)
            let sourceWords = WordTokenizer.tokenize(ready.sourceText)
            let targetWord = sourceWords.count * 2 / 3
            store.player.seek(Double(targetWord)); store.player.resumeFollowing()
            let offset = sourceWords[targetWord].range.lowerBound.utf16Offset(in: ready.sourceText)
            let expectedPage = ready.pageSpans.last(where: { $0.charStart <= offset && offset < $0.charEnd })?.page
            precondition(store.player.page == expectedPage)
            let kokoroRestored = KoeBookStore(root: root); kokoroRestored.open(book)
            precondition(kokoroRestored.player.voiceSource == .kokoro && kokoroRestored.player.kokoroWord == targetWord)
            precondition(kokoroRestored.player.page == expectedPage)
            precondition(abs(kokoroRestored.player.seconds - midpoint) < 0.1)
            store.player.selectVoice(.recorded)
            precondition(store.player.canPlay && store.player.seconds <= store.player.duration)
            let pending = book.chapters.first(where: { $0.audioFile == nil })!
            store.open(book, chapterID: pending.id)
            precondition(!store.player.canPlay)
            store.player.selectVoice(.kokoro)
            precondition(store.player.canPlay && store.player.canFollowPages)
            store.player.saveAndPause(); kokoroRestored.player.saveAndPause()
            var awaitingRecording = ready
            awaitingRecording.audioFile = nil; awaitingRecording.audioSha256 = nil; awaitingRecording.tokens = []
            let refreshPlayer = KoeBookPlayer()
            refreshPlayer.load(book: book, chapter: awaitingRecording, folder: store.directory(book), place: nil, source: .kokoro)
            refreshPlayer.seek(Double(targetWord))
            refreshPlayer.refreshRecording(ready)
            precondition(refreshPlayer.voiceSource == .kokoro && refreshPlayer.kokoroWord == targetWord)
            refreshPlayer.selectVoice(.recorded)
            precondition(refreshPlayer.canPlay && refreshPlayer.duration > 0)
        }
        var invalid = store.books[0];invalid.chapters[0].audioFile = "../outside.mp3"
        do { try invalid.validate();preconditionFailure("Unsafe package accepted") } catch KoeBookError.invalidPackage {}
        print("PASS: 56 chapters, 388 pages, unchanged recordings, saved place, Kokoro word seek/page follow/restore, legacy places, pending-chapter playback and voice switching; unsafe paths refused.")
    }
}
