//
//  PDFReader.swift
//  ReadFlow
//
//  Extracts readable text from PDFs. Primary path is PDFKit's text layer; when a
//  page carries no extractable text (scanned / image-only pages), it falls back
//  to rasterizing the page and running Vision OCR (VNRecognizeTextRequest).
//
//  Public surface (see docs/SPEC.md §3.6 and Contracts.swift):
//      enum PDFReader {
//          static func extractText(from url: URL) -> String?
//          static func extractText(from url: URL, pageIndex: Int) -> String?
//      }
//
//  Consumed contract symbols: none directly — this module returns plain `String`
//  text ready for `WordTokenizer.tokenize` by the caller (TTSEngineManager).
//  Exposed: the `PDFReader` enum and its two static methods above.
//

import Foundation
import PDFKit
import Vision
import CoreGraphics
import ImageIO

/// PDF text extraction with a Vision OCR fallback for scanned pages.
///
/// All work here is synchronous and CPU/IO-bound. Callers should invoke these
/// off the main thread (e.g. from a background queue) and hop back to main for
/// any UI; the methods themselves touch no UI and create no retain cycles
/// (Vision requests are completed synchronously via `VNImageRequestHandler`).
enum PDFReader {

    // MARK: - Public API

    /// Extract the full readable text of the PDF at `url`, page by page, in
    /// reading order. Each page uses its embedded text layer when available and
    /// falls back to OCR when the page yields nothing. Pages are joined with
    /// blank lines so sentence/paragraph boundaries survive tokenization.
    ///
    /// Returns `nil` only when the document can't be opened at all or no page
    /// produced any text (neither embedded nor OCR). An empty/whitespace-only
    /// result is treated as "no text" and reported as `nil` so the caller can
    /// surface a clear message instead of "reading" silence.
    static func extractText(from url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }

        let pageCount = document.pageCount
        guard pageCount > 0 else { return nil }

        var pageTexts: [String] = []
        pageTexts.reserveCapacity(pageCount)

        for pageIndex in 0..<pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            if let text = text(for: page), !text.isEmpty {
                pageTexts.append(text)
            }
        }

        return joinedNonEmpty(pageTexts)
    }

    /// Extract the readable text of a single page (`pageIndex`, 0-based). Uses
    /// the embedded text layer first, then OCR. Returns `nil` if the document or
    /// page can't be opened, the index is out of range, or the page has no text.
    static func extractText(from url: URL, pageIndex: Int) -> String? {
        guard pageIndex >= 0,
              let document = PDFDocument(url: url),
              pageIndex < document.pageCount,
              let page = document.page(at: pageIndex) else {
            return nil
        }

        guard let text = text(for: page), !text.isEmpty else { return nil }
        return text
    }

    // MARK: - Per-page extraction

    /// Returns the trimmed text for a single page, using the embedded text layer
    /// when it carries real content and OCR otherwise. Returns `nil` when both
    /// paths come up empty.
    private static func text(for page: PDFPage) -> String? {
        // 1. Embedded text layer (fast, accurate when present).
        if let embedded = page.string {
            let trimmed = embedded.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        // 2. OCR fallback for scanned / image-only pages.
        if let ocr = ocrText(for: page) {
            let trimmed = ocr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return nil
    }

    // MARK: - OCR fallback

    /// Rasterize `page` and run `VNRecognizeTextRequest` over it. Returns the
    /// recognized text joined into newline-separated lines, or `nil` if the page
    /// can't be rasterized or Vision finds nothing.
    private static func ocrText(for page: PDFPage) -> String? {
        guard let cgImage = rasterize(page: page) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Vision picks sensible defaults; explicit revision keeps behavior stable.
        request.recognitionLanguages = ["en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            // OCR failed for this page; treat as "no text" rather than crashing.
            return nil
        }

        guard let observations = request.results, !observations.isEmpty else {
            return nil
        }

        // Take the top candidate of each recognized line, preserving reading
        // order as Vision returns it (top-to-bottom, left-to-right).
        let lines: [String] = observations.compactMap { observation in
            observation.topCandidates(1).first?.string
        }

        let joined = lines.joined(separator: "\n")
        return joined.isEmpty ? nil : joined
    }

    /// Render a PDF page to a `CGImage` at a resolution high enough for reliable
    /// OCR (~200 dpi). Renders onto an opaque white background so anti-aliased
    /// text has good contrast. Returns `nil` if a context can't be created.
    private static func rasterize(page: PDFPage) -> CGImage? {
        // Use the crop box (what's actually visible) at the page's natural
        // rotation, scaled up for OCR fidelity.
        let pageRect = page.bounds(for: .cropBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return nil }

        // 200 dpi relative to PDF's 72 dpi user space.
        let scale: CGFloat = 200.0 / 72.0
        let pixelWidth = Int((pageRect.width * scale).rounded())
        let pixelHeight = Int((pageRect.height * scale).rounded())
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.noneSkipLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        // Opaque white background for contrast.
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

        // Map PDF user space (origin at page's crop-box origin) into the scaled
        // pixel space. `draw(_:to:)` handles page rotation for us.
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -pageRect.origin.x, y: -pageRect.origin.y)
        page.draw(with: .cropBox, to: context)
        context.restoreGState()

        return context.makeImage()
    }

    // MARK: - Helpers

    /// Join non-empty page texts with a blank line between pages. Returns `nil`
    /// when nothing remains, so "opened but no readable text" is reported as a
    /// failure the caller can act on.
    private static func joinedNonEmpty(_ pageTexts: [String]) -> String? {
        let nonEmpty = pageTexts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return nil }
        return nonEmpty.joined(separator: "\n\n")
    }
}
