import Combine
import Foundation

/// "Keep on this iPad": pulls a whole book (PDF, every chapter's text and
/// timings, every narrator recording) into the app's cache ahead of time.
@MainActor
final class Keeper: ObservableObject {
    static let shared = Keeper()
    @Published private(set) var kept: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "koe.kept") ?? [])
    @Published var progress: [String: (done: Int, total: Int)] = [:]
    @Published var errors: [String: String] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    func isKept(_ bookId: String) -> Bool { kept.contains(bookId) }
    func isWorking(_ bookId: String) -> Bool { tasks[bookId] != nil }

    func keep(_ detail: BookDetailResponse, client: CoreClient) {
        let bookId = detail.book.id
        guard tasks[bookId] == nil else { return }
        kept.insert(bookId); persist()
        errors[bookId] = nil
        let steps = 1 + detail.chapters.count + detail.chapters.filter(\.isReady).count
        progress[bookId] = (0, steps)
        tasks[bookId] = Task { @MainActor [weak self] in
            var done = 0
            func step() { done += 1; self?.progress[bookId] = (done, steps) }
            do {
                let pdfPath = detail.book.sourceUrl ?? "/api/reader/books/\(bookId)/source/source.pdf"
                _ = try await client.cachedFile(path: pdfPath, name: "books/\(bookId)/source.pdf", mimePrefix: "application/pdf", maxBytes: 300 * 1024 * 1024)
                step()
                for chapter in detail.chapters {
                    try Task.checkCancellation()
                    let full = try await client.chapter(bookId: bookId, chapterId: chapter.id)   // writes the chapter copy
                    step()
                    if chapter.isReady, let reading = full.reading, let audio = reading.audioUrl {
                        _ = try await client.cachedFile(path: audio, name: "audio/\(reading.id).mp3", mimePrefix: "audio/", maxBytes: 256 * 1024 * 1024)
                        step()
                    }
                }
            } catch is CancellationError {
                // unkeep() cleans up
            } catch {
                self?.errors[bookId] = error.localizedDescription
            }
            self?.tasks[bookId] = nil
            self?.progress[bookId] = nil
        }
    }

    func unkeep(_ detail: BookDetailResponse) {
        let bookId = detail.book.id
        tasks[bookId]?.cancel(); tasks[bookId] = nil
        kept.remove(bookId); persist()
        progress[bookId] = nil
        let root = CoreClient.cacheRoot
        try? FileManager.default.removeItem(at: root.appendingPathComponent("books/\(bookId)"))
        for chapter in detail.chapters {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("audio/\(chapter.readingId).mp3"))
            try? FileManager.default.removeItem(at: root.appendingPathComponent("kokoro/\(chapter.readingId)"))
        }
    }

    /// Bytes on disk for a book: its folder plus its chapters' recordings.
    func sizeOnDisk(_ detail: BookDetailResponse) -> Int64 {
        let root = CoreClient.cacheRoot
        var total: Int64 = folderSize(root.appendingPathComponent("books/\(detail.book.id)"))
        for chapter in detail.chapters {
            total += fileSize(root.appendingPathComponent("audio/\(chapter.readingId).mp3"))
            total += folderSize(root.appendingPathComponent("kokoro/\(chapter.readingId)"))
        }
        return total
    }

    func readyChapters(_ detail: BookDetailResponse) -> Int {
        let root = CoreClient.cacheRoot
        return detail.chapters.filter { chapter in
            let text = FileManager.default.fileExists(atPath: root.appendingPathComponent("books/\(detail.book.id)/chapters/\(chapter.id).json").path)
            let audio = !chapter.isReady || FileManager.default.fileExists(atPath: root.appendingPathComponent("audio/\(chapter.readingId).mp3").path)
            return text && audio
        }.count
    }

    private func persist() { UserDefaults.standard.set(Array(kept), forKey: "koe.kept") }
    private func fileSize(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    private func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e { total += fileSize(f) }
        return total
    }
}

func bytesLabel(_ bytes: Int64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .file
    return f.string(fromByteCount: bytes)
}
