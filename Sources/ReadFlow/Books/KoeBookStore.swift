import Foundation
import Combine
import PDFKit

@MainActor
final class KoeBookStore: ObservableObject {
    static let shared = KoeBookStore()
    @Published var books: [KoeBook] = []
    @Published var selectedBookID: String?
    @Published var message: String?
    @Published var syncing = false
    let player: KoeBookPlayer
    let connection = KoeBookConnection()
    let root: URL
    private var places: [String: KoeBookPlace] = [:]
    private var refreshClock: Timer?

    init(root: URL? = nil, settings: Settings? = nil) {
        player = KoeBookPlayer(settings: settings)
        self.root = root ?? Self.defaultRoot
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? Data(contentsOf: self.root.appendingPathComponent("places.json")),
           let stored = try? JSONDecoder().decode([String: KoeBookPlace].self, from: data) { places = stored }
        reload()
        player.onSave = { [weak self] bookID, place in self?.save(bookID, place: place) }
        player.onFinished = { [weak self] in self?.continueChapter() }
    }
    static var defaultRoot: URL {
        if let path = ProcessInfo.processInfo.environment["KOE_BOOKS_DIRECTORY"], path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Koe/Books", isDirectory: true)
    }
    var selectedBook: KoeBook? { books.first { $0.id == selectedBookID } }
    func directory(_ book: KoeBook) -> URL { root.appendingPathComponent(book.id + ".koebook", isDirectory: true) }
    func reload() {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        books = entries.filter { $0.pathExtension == "koebook" }.compactMap { url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("book.json")), data.count <= 16 * 1024 * 1024,
                  let book = try? JSONDecoder().decode(KoeBook.self, from: data), (try? book.validate()) != nil,
                  url.lastPathComponent == book.id + ".koebook" else { return nil }
            return book
        }.sorted { $0.title < $1.title }
    }
    func open(_ book: KoeBook, chapterID: String? = nil) {
        let source = selectedBookID == book.id && chapterID != nil ? player.voiceSource : nil
        player.saveAndPause()
        selectedBookID = book.id
        let place = places[book.id]
        guard let chapter = book.chapters.first(where: { $0.id == (chapterID ?? place?.chapterId) }) ?? book.chapters.first else { return }
        let restore = chapterID == nil || chapterID == place?.chapterId ? place : nil
        player.load(book: book, chapter: chapter, folder: directory(book), place: restore, source: source)
        message = nil
    }
    func back() { player.saveAndPause(); selectedBookID = nil }
    func watchForFinishedChapters() {
        guard refreshClock == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor in await self?.refresh() } }
        RunLoop.main.add(timer, forMode: .common); refreshClock = timer
    }
    func stopWatching() { refreshClock?.invalidate(); refreshClock = nil }
    func save(_ id: String, place: KoeBookPlace) {
        guard place.seconds.isFinite, place.zoom.isFinite, place.rate.isFinite else { return }
        places[id] = place
        do { try JSONEncoder().encode(places).write(to: root.appendingPathComponent("places.json"), options: .atomic) }
        catch { message = "Koe could not save your place. Check the book folder's permissions." }
    }
    private func continueChapter() {
        guard let book = selectedBook, let current = player.chapter,
              let next = book.chapters.first(where: { $0.position == current.position + 1 }),
              player.voiceSource == .kokoro || next.audioFile != nil else { return }
        open(book, chapterID: next.id); player.play()
    }
    func importPackage(_ source: URL) throws {
        let data = try Data(contentsOf: source.appendingPathComponent("book.json"))
        guard data.count <= 16 * 1024 * 1024 else { throw KoeBookError.tooLarge }
        let book = try JSONDecoder().decode(KoeBook.self, from: data); try book.validate()
        let pdf = source.appendingPathComponent("source.pdf")
        guard (try pdf.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 128 * 1024 * 1024 else { throw KoeBookError.tooLarge }
        guard KoeBook.hash(try Data(contentsOf: pdf)) == book.sourceSha256,
              PDFDocument(url: pdf)?.pageCount == book.pageCount else { throw KoeBookError.invalidPackage }
        let target = directory(book)
        if FileManager.default.fileExists(atPath: target.path) { reload(); return }
        let staging = root.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: pdf, to: staging.appendingPathComponent("source.pdf"))
        try FileManager.default.createDirectory(at: staging.appendingPathComponent("audio"), withIntermediateDirectories: false)
        for chapter in book.chapters {
            if let name = chapter.audioFile {
                let file = source.appendingPathComponent("audio").appendingPathComponent(name)
                guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 256 * 1024 * 1024 else { throw KoeBookError.tooLarge }
                let bytes = try Data(contentsOf: file)
                guard bytes.count <= 256 * 1024 * 1024, chapter.audioSha256 == KoeBook.hash(bytes) else { throw KoeBookError.invalidPackage }
                try FileManager.default.copyItem(at: file, to: staging.appendingPathComponent("audio").appendingPathComponent(name))
            }
        }
        try data.write(to: staging.appendingPathComponent("book.json"), options: .atomic)
        try FileManager.default.moveItem(at: staging, to: target); reload()
    }
    func refresh() async {
        guard !syncing else { return }; syncing = true; message = nil
        defer { syncing = false }
        do {
            for initial in books {
                var book = initial
                let remote = try await connection.metadata(book)
                guard remote.book.contentHash == book.contentHash, remote.book.sourceSha256 == book.sourceSha256 else { throw KoeBookError.identityChanged }
                var added = 0
                for chapterIndex in book.chapters.indices {
                    guard let status = remote.chapters.first(where: { $0.id == book.chapters[chapterIndex].id }) else { continue }
                    book.chapters[chapterIndex].status = status.status
                    let cachedName = book.chapters[chapterIndex].audioFile
                    let missing = cachedName.map { !FileManager.default.fileExists(atPath: directory(book).appendingPathComponent("audio").appendingPathComponent($0).path) } ?? true
                    if status.status == "completed", missing {
                        let detail = try await connection.metadata(book, chapter: status.id)
                        guard let reading = detail.reading, reading.id == book.chapters[chapterIndex].readingId,
                              reading.textHash == book.chapters[chapterIndex].textHash,
                              let path = reading.audioUrl else { throw KoeBookError.identityChanged }
                        let file = try await connection.download(path: path, book: book)
                        defer { try? FileManager.default.removeItem(at: file) }
                        let bytes = try Data(contentsOf: file)
                        let name = reading.id + ".mp3", destination = directory(book).appendingPathComponent("audio").appendingPathComponent(name)
                        if FileManager.default.fileExists(atPath: destination.path) {
                            // Recover an audio rename committed before its JSON
                            // receipt. Never discard a differing old recording.
                            guard KoeBook.hash(try Data(contentsOf: destination)) == KoeBook.hash(bytes) else { throw KoeBookError.identityChanged }
                        } else { try FileManager.default.moveItem(at: file, to: destination) }
                        book.chapters[chapterIndex].audioFile = name
                        book.chapters[chapterIndex].audioSha256 = KoeBook.hash(bytes)
                        book.chapters[chapterIndex].tokens = reading.tokens
                        book.chapters[chapterIndex].durationSeconds = reading.durationSeconds
                        added += 1
                    }
                }
                try book.validate()
                try JSONEncoder().encode(book).write(to: directory(book).appendingPathComponent("book.json"), options: .atomic)
                if let index = books.firstIndex(where: { $0.id == book.id }) { books[index] = book }
                if selectedBookID == book.id, player.chapter?.audioFile == nil,
                   let updated = book.chapters.first(where: { $0.id == player.chapter?.id }), updated.audioFile != nil {
                    player.refreshRecording(updated)
                }
                if added > 0 { message = "New chapters are ready to listen." }
            }
            if message == nil { message = "Your cached chapters are up to date." }
        } catch { message = error.localizedDescription }
    }
}
