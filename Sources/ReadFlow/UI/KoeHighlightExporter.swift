//
//  KoeHighlightExporter.swift
//  ReadFlow / Koe
//
//  Exports one styled reading as a clean, selectable-text PDF plus a matching
//  editable RTF. The two files share a base name and are written side by side.
//

import AppKit
import UniformTypeIdentifiers

struct KoeHighlightExportResult {
    let pdfURL: URL
    let editableURL: URL
}

enum KoeHighlightExportError: LocalizedError {
    case emptyDocument
    case pdfCreationFailed

    var errorDescription: String? {
        switch self {
        case .emptyDocument:
            return "There is no reading text to export."
        case .pdfCreationFailed:
            return "Koe could not create the highlighted PDF."
        }
    }
}

@MainActor
enum KoeHighlightExporter {
    static func export(
        title: String,
        text: String,
        highlights: [KoeTextHighlight],
        fontName: String
    ) throws -> KoeHighlightExportResult? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KoeHighlightExportError.emptyDocument
        }

        let panel = NSSavePanel()
        panel.title = "Export Koe Highlights"
        panel.message = "Koe will save a clean PDF and an editable RTF beside it."
        panel.prompt = "Export PDF + RTF"
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(safeFilename(title)) - highlighted.pdf"
        guard panel.runModal() == .OK, let chosenURL = panel.url else { return nil }

        let pdfURL = chosenURL.pathExtension.lowercased() == "pdf"
            ? chosenURL
            : chosenURL.appendingPathExtension("pdf")
        return try writeExport(
            title: title,
            text: text,
            highlights: highlights,
            fontName: fontName,
            pdfURL: pdfURL
        )
    }

    static func writeExport(
        title: String,
        text: String,
        highlights: [KoeTextHighlight],
        fontName: String,
        pdfURL: URL
    ) throws -> KoeHighlightExportResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KoeHighlightExportError.emptyDocument
        }

        let editableURL = pdfURL.deletingPathExtension().appendingPathExtension("rtf")
        let attributed = exportDocument(
            title: title,
            text: text,
            highlights: highlights,
            fontName: fontName
        )

        let fullRange = NSRange(location: 0, length: attributed.length)
        let rtfData = try attributed.data(
            from: fullRange,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )

        try writePDF(attributed, to: pdfURL)
        try rtfData.write(to: editableURL, options: .atomic)
        return KoeHighlightExportResult(pdfURL: pdfURL, editableURL: editableURL)
    }

    static func showCompletion(_ result: KoeHighlightExportResult) {
        let alert = NSAlert()
        alert.messageText = "Highlighted reading exported"
        alert.informativeText = "Saved a clean PDF and an editable RTF:\n\n\(result.pdfURL.lastPathComponent)\n\(result.editableURL.lastPathComponent)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }

    static func showError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "Couldn’t export this reading"
        alert.runModal()
    }

    private static func exportDocument(
        title: String,
        text: String,
        highlights: [KoeTextHighlight],
        fontName: String
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.paragraphSpacing = 18
        result.append(NSAttributedString(
            string: title.trimmingCharacters(in: .whitespacesAndNewlines) + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 23, weight: .semibold),
                .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
                .paragraphStyle: titleParagraph,
            ]
        ))

        let bodyOffset = result.length
        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 6
        bodyParagraph.paragraphSpacing = 9
        let bodyFont = (!fontName.isEmpty ? NSFont(name: fontName, size: 13.5) : nil)
            ?? NSFont.systemFont(ofSize: 13.5)
        result.append(NSAttributedString(
            string: text,
            attributes: [
                .font: bodyFont,
                .foregroundColor: NSColor(calibratedWhite: 0.16, alpha: 1),
                .paragraphStyle: bodyParagraph,
            ]
        ))

        let textLength = (text as NSString).length
        for highlight in KoeHighlightOperations.sanitized(highlights, textLength: textLength) {
            let shifted = NSRange(location: bodyOffset + highlight.location, length: highlight.length)
            result.addAttribute(.backgroundColor, value: highlight.color.nsColor, range: shifted)
        }
        return result
    }

    private static func writePDF(_ attributed: NSAttributedString, to url: URL) throws {
        let paperSize = NSSize(width: 612, height: 792) // US Letter at 72 dpi
        let margin: CGFloat = 54
        let contentWidth = paperSize.width - (margin * 2)

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: paperSize.height))
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.containerSize = NSSize(width: contentWidth, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textStorage?.setAttributedString(attributed)

        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container)
            textView.frame.size.height = max(paperSize.height - (margin * 2), ceil(used.height) + 4)
        }

        let printInfo = NSPrintInfo()
        printInfo.paperSize = paperSize
        printInfo.orientation = .portrait
        printInfo.leftMargin = margin
        printInfo.rightMargin = margin
        printInfo.topMargin = margin
        printInfo.bottomMargin = margin
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { throw KoeHighlightExportError.pdfCreationFailed }
    }

    private static func safeFilename(_ title: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = title
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Koe reading" : String(cleaned.prefix(80))
    }
}
