import SwiftUI
import PDFKit

struct KoePDFPageView: NSViewRepresentable {
    let url: URL
    let page: Int
    let zoom: Double
    @ObservedObject var highlights: KoeBookHighlights
    func makeCoordinator() -> Coordinator { Coordinator(highlights) }
    func makeNSView(context: Context) -> KoeBookPDFContainer {
        let container = KoeBookPDFContainer()
        let view = container.pdf
        view.displayMode = .singlePage
        view.displayDirection = .vertical
        view.backgroundColor = .windowBackgroundColor
        view.document = PDFDocument(url: url)
        view.autoScales = false
        view.minScaleFactor = 0.1; view.maxScaleFactor = 10
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.selectionChanged(_:)), name: .PDFViewSelectionChanged, object: view)
        container.area.onMark = { [weak view, weak highlights] page, rect in
            guard let view, let document = view.document, let highlights else { return }
            let mark = KoeBookHighlight(page: document.index(for: page) + 1, rects: [KoeBookMarkRect(rect)], text: page.selection(for: rect)?.string ?? "", color: highlights.color)
            _ = highlights.add([mark])
        }
        return container
    }
    func updateNSView(_ container: KoeBookPDFContainer, context: Context) {
        let view = container.pdf
        if view.document?.documentURL != url { view.document = PDFDocument(url: url); context.coordinator.drawn = nil }
        if let target = view.document?.page(at: max(0, page - 1)), view.currentPage != target { view.clearSelection(); view.go(to: target) }
        container.area.active = highlights.areaMode
        container.area.color = highlights.color.bookColor
        if context.coordinator.drawn != highlights.marks, let document = view.document {
            for index in 0..<document.pageCount {
                guard let pdfPage = document.page(at: index) else { continue }
                for annotation in pdfPage.annotations where annotation.userName == "Koe book highlight" { pdfPage.removeAnnotation(annotation) }
            }
            for mark in highlights.marks {
                guard let pdfPage = document.page(at: mark.page - 1) else { continue }
                for rect in mark.rects {
                    let bounds = rect.cgRect.intersection(pdfPage.bounds(for: .cropBox))
                    guard !bounds.isNull, !bounds.isEmpty else { continue }
                    let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                    annotation.color = mark.color.bookColor.withAlphaComponent(0.45)
                    annotation.userName = "Koe book highlight"
                    annotation.contents = mark.text
                    pdfPage.addAnnotation(annotation)
                }
            }
            context.coordinator.drawn = highlights.marks
        }
        DispatchQueue.main.async {
            let fit = view.scaleFactorForSizeToFit
            if fit.isFinite && fit > 0 { view.scaleFactor = fit * zoom }
        }
    }
    @MainActor final class Coordinator: NSObject {
        let highlights: KoeBookHighlights
        var drawn: [KoeBookHighlight]?
        init(_ highlights: KoeBookHighlights) { self.highlights = highlights }
        deinit { NotificationCenter.default.removeObserver(self) }
        @objc func selectionChanged(_ notification: Notification) {
            guard let view = notification.object as? PDFView, let selection = view.currentSelection, let document = view.document else {
                highlights.selection = []; return
            }
            highlights.selection = selection.pages.compactMap { page in
                let lines = selection.selectionsByLine().filter { $0.pages.contains(page) }
                let rects = lines.map { $0.bounds(for: page).intersection(page.bounds(for: .cropBox)) }.filter { !$0.isNull && !$0.isEmpty }.map(KoeBookMarkRect.init)
                guard !rects.isEmpty else { return nil }
                return KoeBookHighlight(page: document.index(for: page) + 1, rects: rects, text: lines.compactMap(\.string).joined(separator: "\n"), color: highlights.color)
            }
        }
    }
}

@MainActor final class KoeBookPDFContainer: NSView {
    let pdf = PDFView()
    let area = KoeBookAreaOverlay()
    override init(frame: NSRect) {
        super.init(frame: frame)
        for child in [pdf, area] as [NSView] { child.frame = bounds; child.autoresizingMask = [.width, .height]; addSubview(child) }
        area.pdf = pdf
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor final class KoeBookAreaOverlay: NSView {
    weak var pdf: PDFView?
    var active = false { didSet { if !active { start = nil; end = nil; needsDisplay = true } } }
    var color = NSColor.systemYellow
    var onMark: ((PDFPage, CGRect) -> Void)?
    private var start: CGPoint?
    private var end: CGPoint?
    private var startPage: PDFPage?
    override func hitTest(_ point: NSPoint) -> NSView? { active ? super.hitTest(point) : nil }
    override func mouseDown(with event: NSEvent) {
        guard let pdf else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let page = pdf.page(for: pdf.convert(point, from: self), nearest: false) else { return }
        start = point; end = point; startPage = page; needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) { guard start != nil else { return }; end = convert(event.locationInWindow, from: nil); needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        defer { start = nil; end = nil; startPage = nil; needsDisplay = true }
        guard let start, let page = startPage, let pdf else { return }
        let end = convert(event.locationInWindow, from: nil)
        let a = pdf.convert(pdf.convert(start, from: self), to: page)
        let b = pdf.convert(pdf.convert(end, from: self), to: page)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).intersection(page.bounds(for: .cropBox))
        guard !rect.isNull, rect.width >= 2, rect.height >= 2 else { return }
        onMark?(page, rect)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let start, let end else { return }
        color.withAlphaComponent(0.3).setFill()
        NSBezierPath(rect: CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))).fill()
    }
}
