import Foundation

@main struct KoeNativeBookImport {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw KoeBookError.invalidPackage }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let store = KoeBookStore()
        for file in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where file.pathExtension == "koebook" {
            try store.importPackage(file)
        }
        for book in store.books {
            print("Imported: \(book.title) — \(book.chapters.count) chapters, \(book.chapters.filter { $0.audioFile != nil }.count) cached recordings, \(book.pageCount) original pages")
        }
    }
}
