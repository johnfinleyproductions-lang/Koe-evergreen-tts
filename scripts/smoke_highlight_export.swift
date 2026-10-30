// Compile this with ReadingHighlights.swift, HighlightingTextView.swift, and
// KoeHighlightExporter.swift. It intentionally uses no test framework so the
// smoke check works with a Command Line Tools-only Swift installation.

import AppKit
import Foundation
import PDFKit

@main
struct KoeHighlightExportSmoke {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("koe-highlight-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: output) }

        let paragraph = "Koe keeps the reading calm, editable, and easy to revisit. The highlighted idea should survive both exports.\n\n"
        let text = String(repeating: paragraph, count: 180)
        let highlightedPhrase = "highlighted idea"
        let range = (text as NSString).range(of: highlightedPhrase)
        let pdfURL = output.appendingPathComponent("Koe highlighted reading.pdf")
        let result = try KoeHighlightExporter.writeExport(
            title: "Highlight export smoke check",
            text: text,
            highlights: [KoeTextHighlight(range: range, color: .yellow)],
            fontName: "",
            pdfURL: pdfURL
        )

        guard let pdf = PDFDocument(url: result.pdfURL), pdf.pageCount >= 2 else {
            throw SmokeError("PDF was not readable or did not paginate")
        }
        let pdfBytes = try Data(contentsOf: result.pdfURL)
        guard pdfBytes.starts(with: Data("%PDF".utf8)) else {
            throw SmokeError("PDF header is missing")
        }

        let editable = try NSAttributedString(
            url: result.editableURL,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
        let editableRange = (editable.string as NSString).range(of: highlightedPhrase)
        guard editableRange.location != NSNotFound,
              editable.attribute(.backgroundColor, at: editableRange.location, effectiveRange: nil) != nil
        else {
            throw SmokeError("RTF text or highlight was not preserved")
        }

        let split = KoeHighlightOperations.applying(
            color: .blue,
            to: NSRange(location: 4, length: 3),
            in: [KoeTextHighlight(range: NSRange(location: 2, length: 8), color: .yellow)],
            textLength: 20
        )
        guard split.map(\.range) == [
            NSRange(location: 2, length: 2),
            NSRange(location: 4, length: 3),
            NSRange(location: 7, length: 3),
        ] else {
            throw SmokeError("Overlapping highlight ranges were not split correctly")
        }

        print("PASS: \(pdf.pageCount)-page PDF + editable highlighted RTF")
    }

    private struct SmokeError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
