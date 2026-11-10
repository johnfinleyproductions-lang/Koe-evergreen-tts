import Foundation
import PDFKit

@main struct KoeBookHighlightSmoke {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("koe-highlight-smoke-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        for folder in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where folder.pathExtension == "koebook" {
            let book = try JSONDecoder().decode(KoeBook.self, from: Data(contentsOf: folder.appendingPathComponent("book.json")))
            let destination = root.appendingPathComponent(book.id)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let originalPDF = try Data(contentsOf: folder.appendingPathComponent("source.pdf"))
            let pdf = PDFDocument(data: originalPDF)!
            let store = KoeBookHighlights(folder: destination, sourceHash: book.sourceSha256, pageCount: book.pageCount)
            let page = pdf.page(at: min(8, pdf.pageCount - 1))!
            let rect = page.bounds(for: .cropBox).insetBy(dx: 50, dy: 50)
            let area = KoeBookHighlight(page: min(9, pdf.pageCount), rects: [KoeBookMarkRect(rect)], text: "", color: .yellow)
            precondition(store.add([area]))
            precondition(store.add([area]) && store.marks.count == 1)
            if let selected = page.selection(for: rect) {
                let lines = selected.selectionsByLine().map { $0.bounds(for: page) }.filter { !$0.isNull && !$0.isEmpty }
                if !lines.isEmpty {
                    let text = KoeBookHighlight(page: area.page, rects: lines.map(KoeBookMarkRect.init), text: selected.string ?? "", color: .blue)
                    precondition(store.add([text]))
                }
            }
            let restored = KoeBookHighlights(folder: destination, sourceHash: book.sourceSha256, pageCount: book.pageCount)
            precondition(restored.marks == store.marks && restored.error == nil)
            var invalid = area; invalid.page = book.pageCount + 1
            precondition(!restored.add([invalid]))
            invalid.page = 1; invalid.rects = [KoeBookMarkRect(CGRect(x: 0, y: 0, width: -1, height: 10))]
            // CGRect standardizes a negative width, so reject non-finite geometry explicitly.
            invalid.rects[0].width = .infinity
            precondition(!restored.add([invalid]))
            let file = destination.appendingPathComponent("highlights.json")
            let saved = try Data(contentsOf: file)
            let wrongSource = KoeBookHighlights(folder: destination, sourceHash: String(repeating: "f", count: 64), pageCount: book.pageCount)
            precondition(wrongSource.error != nil && !wrongSource.add([area]))
            let preserved = try Data(contentsOf: file); precondition(preserved == saved)
            precondition(restored.remove(area.id))
            precondition(!KoeBookHighlights(folder: destination, sourceHash: book.sourceSha256, pageCount: book.pageCount).marks.contains { $0.id == area.id })
            try Data("damaged archive".utf8).write(to: file)
            let damaged = KoeBookHighlights(folder: destination, sourceHash: book.sourceSha256, pageCount: book.pageCount)
            precondition(damaged.error != nil && !damaged.add([area]))
            let damagedBytes = try String(contentsOf: file, encoding: .utf8); precondition(damagedBytes == "damaged archive")
            let missing = KoeBookHighlights(folder: destination.appendingPathComponent("missing"), sourceHash: book.sourceSha256, pageCount: book.pageCount)
            precondition(!missing.add([area]) && missing.marks.isEmpty && missing.error != nil)
            let unchangedPDF = try Data(contentsOf: folder.appendingPathComponent("source.pdf")); precondition(KoeBook.hash(unchangedPDF) == KoeBook.hash(originalPDF))
        }
        print("PASS: both books, text/area geometry, saved highlight restore/removal, duplicate protection, source identity, invalid archives preserved, visible write errors and unchanged PDFs.")
    }
}
