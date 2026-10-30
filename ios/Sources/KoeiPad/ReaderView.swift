import PDFKit
import PencilKit
import SwiftUI
import UIKit

struct ReaderView: View {
    @EnvironmentObject var client: CoreClient
    @EnvironmentObject var docs: MacDocuments
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var player = ChapterPlayer()
    @State private var savedToast: String?
    let book: BookInfo
    let chapters: [Chapter]
    let chapter: Chapter
    let place: Place?
    @State private var pdfURL: URL?
    @State private var pdfError: String?
    @State private var showPDF = true
    @State private var inking = false
    @State private var markMode = false
    @State private var showMarks = false
    @AppStorage("koe.readingPen2") private var readingPen = false
    @AppStorage("koe.markColor") private var markColorRaw = KoeHighlightColor.yellow.rawValue
    private var markColor: KoeHighlightColor { KoeHighlightColor(rawValue: markColorRaw) ?? .yellow }

    var body: some View {
        VStack(spacing: 0) {
            content
            TransportBar(player: player, book: book, chapter: chapter, showPDF: $showPDF, inking: $inking,
                         markMode: $markMode, markColorRaw: $markColorRaw, showMarks: $showMarks)
        }
        .background(Koe.readerBg)
        .modifier(PencilGestures { player.toggle() })
        .navigationTitle(chapter.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $readingPen) { Label("Reading pen (drag speaks words)", systemImage: "pencil.and.outline") }
                    Toggle(isOn: Binding(get: { showPDF }, set: { v in withAnimation { showPDF = v } })) { Label("Show pages", systemImage: "doc.text.image") }
                } label: { Image(systemName: "slider.horizontal.3") }
                .tint(Koe.ink2)
            }
        }
        .task {
            async let load: Void = player.load(client: client, book: book, chapters: chapters, chapter: chapter, place: place)
            async let pdf: Void = loadPDF()
            _ = await (load, pdf)
        }
        .onDisappear { player.stop() }
        .sheet(isPresented: $showMarks) { MarksSheet(player: player, boards: docs.boards.map { ($0.id, $0.name) }) { range, boardId in saveToBoard(range, boardId) } }
        .overlay(alignment: .bottom) {
            if let savedToast {
                Text(savedToast).font(.footnote.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Koe.ink.opacity(0.9), in: Capsule()).foregroundStyle(Koe.paper).padding(.bottom, 120)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private func saveToBoard(_ range: NSRange, _ boardId: UUID) {
        guard let text = player.reading?.sourceText, let r = Range(range, in: text) else { return }
        let passage = String(text[r])
        let ok = BoardWriter.save(text: passage, source: "\(book.title) · \(chapter.title)", to: boardId)
        let name = docs.boards.first(where: { $0.id == boardId })?.name ?? "board"
        withAnimation { savedToast = ok ? "Saved to \(name)" : "Couldn't save to \(name)" }
        Task { try? await Task.sleep(for: .seconds(2)); withAnimation { savedToast = nil } }
    }

    @ViewBuilder private var content: some View {
        if let reading = player.reading {
            if showPDF && sizeClass == .regular {
                HStack(spacing: 0) {
                    pdfPane.frame(maxWidth: .infinity)
                    Divider()
                    textPane(reading).frame(maxWidth: .infinity)
                }
            } else if showPDF {
                VStack(spacing: 0) { pdfPane.frame(maxHeight: .infinity); Divider(); textPane(reading).frame(maxHeight: .infinity) }
            } else {
                textPane(reading)
            }
        } else {
            VStack(spacing: 14) {
                if let error = player.error {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(Koe.shu)
                    Text(error).font(Koe.serif(17)).foregroundStyle(Koe.ink).multilineTextAlignment(.center)
                } else {
                    ProgressView().tint(Koe.shu)
                    Text(player.status).font(Koe.serif(17)).foregroundStyle(Koe.ink2)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        }
    }

    @ViewBuilder private var pdfPane: some View {
        if let pdfURL {
            PDFPageView(url: pdfURL, page: player.page, bookId: book.id, inking: inking) { manualPage in
                player.setPage(manualPage, manual: true)
            }
            .background(Koe.readerBg)
        } else if let pdfError {
            VStack(spacing: 8) {
                Image(systemName: "doc.questionmark").font(.largeTitle).foregroundStyle(Koe.faint)
                Text(pdfError).font(.footnote).foregroundStyle(Koe.faint).multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        } else {
            VStack(spacing: 8) { ProgressView().tint(Koe.shu); Text("Fetching the book's pages…").font(.footnote).foregroundStyle(Koe.faint) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func textPane(_ reading: Reading) -> some View {
        HighlightTextView(text: reading.sourceText, ranges: player.highlightRanges, currentIndex: player.highlightIndex,
                          readingPen: readingPen, marks: player.marks, markMode: markMode, markColor: markColor,
                          boards: docs.boards.map { ($0.id, $0.name) },
                          onMark: { range, color in player.mark(range, color: color); markColorRaw = color.rawValue },
                          onUnmark: { range in player.unmark(range) },
                          onSaveToBoard: { range, boardId in saveToBoard(range, boardId) },
                          onTapWord: { index in
            player.seek(toWord: index)
        }, onPenWord: { index in
            // The reading pen: pause the voice and speak the word under the tip.
            if player.isPlaying { player.pause() }
            let range = player.highlightRanges[index]
            if let r = Range(range, in: reading.sourceText) { PenVoice.shared.speak(String(reading.sourceText[r])) }
            player.seek(toWord: index)
        })
        .background(Koe.paper)
        .overlay(alignment: .top) {
            if player.preparing {
                HStack(spacing: 8) { ProgressView().tint(Koe.shu); Text("Kokoro is preparing…").font(.footnote) }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Koe.paper2, in: Capsule()).padding(.top, 10)
            } else if let error = player.error, player.ready {
                Text(error).font(.footnote).foregroundStyle(Koe.shu).multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Koe.paper2, in: RoundedRectangle(cornerRadius: 10)).padding(10)
            }
        }
    }

    private func loadPDF() async {
        let path = book.sourceUrl ?? "/api/reader/books/\(book.id)/source/source.pdf"
        do {
            pdfURL = try await client.cachedFile(path: path, name: "books/\(book.id)/source.pdf", mimePrefix: "application/pdf", maxBytes: 300 * 1024 * 1024)
        } catch {
            pdfError = "Pages unavailable: \(error.localizedDescription)"
        }
    }
}

// MARK: - Transport

struct TransportBar: View {
    @ObservedObject var player: ChapterPlayer
    let book: BookInfo
    let chapter: Chapter
    @Binding var showPDF: Bool
    @Binding var inking: Bool
    @Binding var markMode: Bool
    @Binding var markColorRaw: String
    @Binding var showMarks: Bool
    @State private var scrubbing = false
    @State private var scrub: Double = 0

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                if player.voiceSource == .kokoro {
                    Text("word \(Int(scrubbing ? scrub : Double(player.kokoroWord)) + 1)")
                        .font(.system(.footnote, design: .monospaced)).foregroundStyle(Koe.ink2).frame(width: 96, alignment: .trailing)
                    Slider(value: Binding(get: { scrubbing ? scrub : Double(player.kokoroWord) }, set: { scrub = $0 }),
                           in: 0...Double(max(1, player.wordCount - 1))) { editing in
                        scrubbing = editing
                        if !editing { player.seek(toWord: Int(scrub.rounded())) }
                    }
                    .tint(Koe.shu).disabled(!player.ready)
                    Text("of \(player.wordCount)").font(.system(.footnote, design: .monospaced)).foregroundStyle(Koe.ink2).frame(width: 96, alignment: .leading)
                } else {
                    Text(clock(scrubbing ? scrub : player.seconds)).font(.system(.footnote, design: .monospaced)).foregroundStyle(Koe.ink2).frame(width: 56, alignment: .trailing)
                    Slider(value: Binding(get: { scrubbing ? scrub : player.seconds }, set: { scrub = $0 }),
                           in: 0...max(1, player.duration)) { editing in
                        scrubbing = editing
                        if !editing { player.seek(scrub) }
                    }
                    .tint(Koe.shu).disabled(!player.ready)
                    Text(clock(player.duration)).font(.system(.footnote, design: .monospaced)).foregroundStyle(Koe.ink2).frame(width: 56, alignment: .leading)
                }
            }
            HStack(spacing: 18) {
                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { r in
                        Button { player.rate = Float(r) } label: {
                            if abs(Double(player.rate) - r) < 0.01 { Label(String(format: "%g×", r), systemImage: "checkmark") } else { Text(String(format: "%g×", r)) }
                        }
                    }
                } label: {
                    Text(String(format: "%g×", player.rate)).font(.system(.subheadline, design: .monospaced).weight(.medium))
                        .frame(width: 54, height: 34).background(Koe.paper2, in: Capsule())
                }
                .tint(Koe.ink)
                // Highlighter: Pencil drag marks text in the chosen colour; tap a mark to remove it.
                HStack(spacing: 4) {
                    Button { markMode.toggle() } label: {
                        Image(systemName: markMode ? "highlighter" : "highlighter")
                            .foregroundStyle(markMode ? (KoeHighlightColor(rawValue: markColorRaw) ?? .yellow).swatch : Koe.ink)
                            .frame(width: 34, height: 34)
                            .background(markMode ? Koe.paper : Color.clear, in: Circle())
                    }
                    Menu {
                        ForEach(KoeHighlightColor.allCases) { c in
                            Button { markColorRaw = c.rawValue; markMode = true } label: {
                                if c.rawValue == markColorRaw { Label(c.label, systemImage: "checkmark") } else { Text(c.label) }
                            }
                        }
                        Divider()
                        Button { showMarks = true } label: { Label("Highlights…", systemImage: "list.bullet.rectangle") }
                    } label: {
                        Circle().fill((KoeHighlightColor(rawValue: markColorRaw) ?? .yellow).swatch).frame(width: 16, height: 16)
                            .overlay(Circle().stroke(Koe.line, lineWidth: 1))
                            .frame(width: 28, height: 34)
                    }
                }
                .tint(Koe.ink)
                Menu {
                    Button {
                        player.selectVoice(.recorded)
                    } label: {
                        if player.voiceSource == .recorded { Label("Audiobook Narrator", systemImage: "checkmark") } else { Text("Audiobook Narrator") }
                    }
                    .disabled(!player.hasRecording)
                    Button {
                        player.selectVoice(.kokoro)
                    } label: {
                        if player.voiceSource == .kokoro { Label("Kokoro · \(player.kokoroVoiceName)", systemImage: "checkmark") } else { Text("Kokoro · \(player.kokoroVoiceName)") }
                    }
                } label: {
                    Label(player.voiceSource == .kokoro ? "Kokoro" : "Narrator", systemImage: "waveform")
                        .font(.subheadline.weight(.medium)).padding(.horizontal, 12).frame(height: 34)
                        .background(Koe.paper2, in: Capsule())
                }
                .tint(Koe.ink)
                Spacer()
                Button { player.skipBack() } label: {
                    Image(systemName: player.voiceSource == .kokoro ? "arrow.uturn.backward" : "gobackward.15").font(.title2)
                }.disabled(!player.ready)
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 54))
                }
                .disabled(!player.ready)
                Button { player.skipForward() } label: {
                    Image(systemName: player.voiceSource == .kokoro ? "arrow.uturn.forward" : "goforward.15").font(.title2)
                }.disabled(!player.ready)
                Spacer()
                if showPDF {
                    HStack(spacing: 6) {
                        Button { player.turnPage(-1) } label: { Image(systemName: "chevron.left") }
                        Text("p. \(player.page)\(book.pageCount.map { " / \($0)" } ?? "")")
                            .font(.system(.subheadline, design: .monospaced)).foregroundStyle(Koe.ink2).frame(minWidth: 86)
                        Button { player.turnPage(1) } label: { Image(systemName: "chevron.right") }
                        Button { player.resumeFollowing() } label: {
                            Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                .foregroundStyle(player.followPages ? Koe.shu : Koe.faint)
                        }
                        .help("Follow the narration")
                        Button { inking.toggle() } label: {
                            Image(systemName: inking ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                                .foregroundStyle(inking ? Koe.shu : Koe.ink)
                        }
                        .help("Ink on the page with the Pencil")
                    }
                    .tint(Koe.ink)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Koe.paper2)
        .overlay(alignment: .top) { Rectangle().fill(Koe.line).frame(height: 1) }
    }
}

// MARK: - PDF page

struct PDFPageView: UIViewRepresentable {
    let url: URL
    let page: Int
    let bookId: String
    let inking: Bool
    let onManualPage: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(bookId: bookId, onManualPage: onManualPage) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.autoScales = true
        view.usePageViewController(false)        // before the document, or touches scroll instead of draw
        view.backgroundColor = .clear
        view.pageOverlayViewProvider = context.coordinator
        view.document = PDFDocument(url: url)
        context.coordinator.attach(view)
        context.coordinator.show(page, in: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
        context.coordinator.show(page, in: view)
        context.coordinator.setInking(inking, in: view)
    }

    final class Coordinator: NSObject, PDFPageOverlayViewProvider, PKCanvasViewDelegate {
        let bookId: String
        let onManualPage: (Int) -> Void
        private var programmatic = false
        private var observer: NSObjectProtocol?
        private var canvases: [Int: PKCanvasView] = [:]
        private var pageOf: [ObjectIdentifier: Int] = [:]
        private var inking = false
        private let toolPicker = PKToolPicker()
        init(bookId: String, onManualPage: @escaping (Int) -> Void) { self.bookId = bookId; self.onManualPage = onManualPage }

        // One PencilKit canvas per page, pencil-only so fingers keep scrolling/zooming.
        func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
            guard let doc = view.document else { return nil }
            let index = doc.index(for: page) + 1
            if let existing = canvases[index] { return existing }
            let canvas = PKCanvasView()
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            canvas.drawingPolicy = .pencilOnly
            canvas.delegate = self
            canvas.drawing = InkStore.load(bookId, page: index)
            canvas.isUserInteractionEnabled = inking
            canvases[index] = canvas
            pageOf[ObjectIdentifier(canvas)] = index
            if inking { toolPicker.addObserver(canvas) }
            return canvas
        }

        func pdfView(_ view: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
            guard let canvas = overlayView as? PKCanvasView, let index = pageOf[ObjectIdentifier(canvas)] else { return }
            InkStore.save(canvas.drawing, bookId, page: index)
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard let index = pageOf[ObjectIdentifier(canvasView)] else { return }
            InkStore.save(canvasView.drawing, bookId, page: index)
        }

        func setInking(_ on: Bool, in view: PDFView) {
            guard on != inking else { return }
            inking = on
            for canvas in canvases.values {
                canvas.isUserInteractionEnabled = on
                if on { toolPicker.addObserver(canvas) } else { toolPicker.removeObserver(canvas) }
            }
            if on, let doc = view.document, let current = view.currentPage, let canvas = canvases[doc.index(for: current) + 1] {
                toolPicker.setVisible(true, forFirstResponder: canvas)
                canvas.becomeFirstResponder()
            } else {
                for canvas in canvases.values { toolPicker.setVisible(false, forFirstResponder: canvas); canvas.resignFirstResponder() }
            }
        }
        func attach(_ view: PDFView) {
            observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self, weak view] _ in
                guard let self, let view, !self.programmatic, let doc = view.document, let current = view.currentPage else { return }
                self.onManualPage(doc.index(for: current) + 1)
            }
        }
        func show(_ page: Int, in view: PDFView) {
            guard let doc = view.document, doc.pageCount > 0 else { return }
            let index = min(max(0, page - 1), doc.pageCount - 1)
            if let current = view.currentPage, doc.index(for: current) == index { return }
            guard let target = doc.page(at: index) else { return }
            programmatic = true
            view.go(to: target)
            programmatic = false
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

// MARK: - Highlighted text

/// The chapter text with the spoken word washed in vermilion. One UITextView,
/// attributes edited in place, so long chapters stay cheap. Tap a word to read
/// from there.
struct HighlightTextView: UIViewRepresentable {
    let text: String
    let ranges: [NSRange]
    let currentIndex: Int
    var readingPen = true
    var marks: [KoeTextHighlight] = []
    var markMode = false
    var markColor: KoeHighlightColor = .yellow
    var boards: [(UUID, String)] = []
    var onMark: ((NSRange, KoeHighlightColor) -> Void)? = nil
    var onUnmark: ((NSRange) -> Void)? = nil
    var onSaveToBoard: ((NSRange, UUID) -> Void)? = nil
    let onTapWord: (Int) -> Void
    var onPenWord: ((Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onTapWord: onTapWord, onPenWord: onPenWord) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = false
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 28, left: 28, bottom: 120, right: 28)
        view.alwaysBounceVertical = true
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        // Fingers scroll; the Pencil is a reading pen. Pencil drags never scroll.
        view.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                                       NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        let pen = PencilDragRecognizer(target: context.coordinator, action: #selector(Coordinator.penDragged(_:)))
        view.addGestureRecognizer(pen)
        context.coordinator.haptics = PencilHaptics(view: view)
        let hover = UIHoverGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hovered(_:)))
        view.addGestureRecognizer(hover)
        let editMenu = UIEditMenuInteraction(delegate: context.coordinator)
        view.addInteraction(editMenu)
        context.coordinator.editMenu = editMenu
        let band = UIView()
        band.backgroundColor = Koe.highlightFill.withAlphaComponent(0.45)
        band.layer.cornerRadius = 6
        band.isUserInteractionEnabled = false
        band.isHidden = true
        view.addSubview(band)
        context.coordinator.band = band
        context.coordinator.readingPen = readingPen
        context.coordinator.ranges = ranges
        context.coordinator.configure(markMode: markMode, markColor: markColor, onMark: onMark, onUnmark: onUnmark)
        context.coordinator.boards = boards; context.coordinator.onSaveToBoard = onSaveToBoard
        context.coordinator.apply(text: text, to: view)
        context.coordinator.setMarks(marks, in: view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.readingPen = readingPen
        context.coordinator.configure(markMode: markMode, markColor: markColor, onMark: onMark, onUnmark: onUnmark)
        context.coordinator.boards = boards; context.coordinator.onSaveToBoard = onSaveToBoard
        if context.coordinator.ranges != ranges { context.coordinator.ranges = ranges; context.coordinator.resetHighlight(in: view) }
        if context.coordinator.text != text { context.coordinator.apply(text: text, to: view); context.coordinator.setMarks(marks, in: view, force: true) }
        else { context.coordinator.setMarks(marks, in: view) }
        context.coordinator.highlight(index: currentIndex, in: view)
    }

    final class Coordinator: NSObject, UIEditMenuInteractionDelegate {
        let onTapWord: (Int) -> Void
        let onPenWord: ((Int) -> Void)?
        weak var editMenu: UIEditMenuInteraction?
        private var pendingSelection: NSRange?
        private weak var pendingView: UITextView?
        var ranges: [NSRange] = []
        var text = ""
        var readingPen = true
        weak var band: UIView?
        private var lastRange: NSRange?
        private var lastIndex = -1
        private var lastPenIndex = -1
        private var marks: [KoeTextHighlight] = []
        private var markMode = false
        private var markColor: KoeHighlightColor = .yellow
        private var onMark: ((NSRange, KoeHighlightColor) -> Void)?
        private var onUnmark: ((NSRange) -> Void)?
        var boards: [(UUID, String)] = []
        var onSaveToBoard: ((NSRange, UUID) -> Void)?
        private var anchorOffset: Int?
        private var preview: NSRange?
        var haptics: PencilHaptics?
        private var rollBase: CGFloat = 0
        private var rollSteps = 0
        private var rolled = false
        private var dragColor: KoeHighlightColor = .yellow
        private static let rollStep: CGFloat = .pi / 6     // 30° per colour
        init(onTapWord: @escaping (Int) -> Void, onPenWord: ((Int) -> Void)?) { self.onTapWord = onTapWord; self.onPenWord = onPenWord }

        func configure(markMode: Bool, markColor: KoeHighlightColor, onMark: ((NSRange, KoeHighlightColor) -> Void)?, onUnmark: ((NSRange) -> Void)?) {
            self.markMode = markMode; self.markColor = markColor; self.onMark = onMark; self.onUnmark = onUnmark
        }

        /// Paint every mark. Cheap enough to redo whenever the set changes.
        func setMarks(_ next: [KoeTextHighlight], in view: UITextView, force: Bool = false) {
            guard force || next != marks else { return }
            marks = next
            let storage = view.textStorage
            let all = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: all)
            for m in marks where NSMaxRange(m.range) <= storage.length { storage.addAttribute(.backgroundColor, value: m.color.ui, range: m.range) }
            if let current = lastRange, NSMaxRange(current) <= storage.length { storage.addAttribute(.backgroundColor, value: Koe.highlightFill, range: current) }
            storage.endEditing()
        }

        /// Put a range back to its mark colour (or nothing) after a wash leaves it.
        private func restoreBackground(_ range: NSRange, in view: UITextView) {
            let storage = view.textStorage
            guard NSMaxRange(range) <= storage.length, range.length > 0 else { return }
            storage.removeAttribute(.backgroundColor, range: range)
            for m in marks {
                let overlap = NSIntersectionRange(m.range, range)
                if overlap.length > 0 { storage.addAttribute(.backgroundColor, value: m.color.ui, range: overlap) }
            }
        }

        private func offset(at point: CGPoint, in view: UITextView) -> Int? {
            guard let position = view.closestPosition(to: point) else { return nil }
            return view.offset(from: view.beginningOfDocument, to: position)
        }

        /// Snap a raw pencil span to whole words.
        private func snapped(_ a: Int, _ b: Int) -> NSRange {
            let lo = min(a, b), hi = max(a, b)
            let start = ranges.first(where: { NSMaxRange($0) > lo })?.location ?? lo
            let end = ranges.last(where: { $0.location < hi }).map { NSMaxRange($0) } ?? hi
            return NSRange(location: min(start, end), length: max(0, end - start))
        }

        private func wordIndex(at point: CGPoint, in view: UITextView) -> Int? {
            guard let position = view.closestPosition(to: point) else { return nil }
            let offset = view.offset(from: view.beginningOfDocument, to: position)
            if let hit = ranges.firstIndex(where: { $0.location <= offset && offset < NSMaxRange($0) }) { return hit }
            return nil
        }

        /// A soft band on the line under the pen tip (hover on the M2 iPad Air,
        /// or while dragging): the reading ruler.
        private func moveBand(to point: CGPoint, in view: UITextView) {
            guard let band else { return }
            let layout = view.layoutManager
            let inset = view.textContainerInset
            let local = CGPoint(x: point.x - inset.left, y: point.y - inset.top)
            let glyph = layout.glyphIndex(for: local, in: view.textContainer)
            var line = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            line.origin.y += inset.top
            line.origin.x = inset.left - 6
            line.size.width = view.bounds.width - inset.left - inset.right + 12
            band.frame = line.insetBy(dx: 0, dy: -2)
            band.isHidden = false
        }

        @objc func hovered(_ gesture: UIHoverGestureRecognizer) {
            guard let view = gesture.view as? UITextView, readingPen else { band?.isHidden = true; return }
            switch gesture.state {
            case .began, .changed: moveBand(to: gesture.location(in: view), in: view)
            default: band?.isHidden = true
            }
        }

        @objc func penDragged(_ gesture: PencilDragRecognizer) {
            guard let view = gesture.view as? UITextView else { return }
            let point = gesture.point
            if !readingPen || markMode {
                // Drag = select whole words. Quick mode lays the colour down on lift;
                // a barrel roll (Pencil Pro) picks the colour and skips the menu;
                // otherwise a menu offers the colours, Read from here, Remove.
                switch gesture.state {
                case .began:
                    clearPendingSelection(in: view)
                    anchorOffset = offset(at: point, in: view); preview = nil
                    rollBase = gesture.rollAngle; rollSteps = 0; rolled = false; dragColor = markColor
                case .changed:
                    guard let anchor = anchorOffset, let now = offset(at: point, in: view) else { return }
                    // Barrel roll: every 30° steps the colour; the wash shows it live.
                    var delta = gesture.rollAngle - rollBase
                    while delta > .pi { delta -= 2 * .pi }
                    while delta < -.pi { delta += 2 * .pi }
                    let steps = Int((delta / Self.rollStep).rounded(.towardZero))
                    var recolour = false
                    if steps != rollSteps {
                        rollSteps = steps; rolled = true; recolour = true
                        let all = KoeHighlightColor.allCases
                        let base = all.firstIndex(of: markColor) ?? 0
                        dragColor = all[((base + steps) % all.count + all.count) % all.count]
                        haptics?.tick(at: point)
                    }
                    let next = snapped(anchor, now)
                    guard next != preview || recolour else { return }
                    if next != preview { haptics?.tick(at: point) }
                    let wash = (markMode || rolled) ? dragColor.ui.withAlphaComponent(0.7) : Koe.highlightFill.withAlphaComponent(0.5)
                    if let old = preview { restoreBackground(old, in: view) }
                    if next.length > 0, NSMaxRange(next) <= view.textStorage.length {
                        view.textStorage.addAttribute(.backgroundColor, value: wash, range: next)
                    }
                    preview = next
                case .ended:
                    guard let done = preview, done.length > 0 else { anchorOffset = nil; preview = nil; return }
                    if markMode || rolled {
                        restoreBackground(done, in: view); onMark?(done, dragColor); haptics?.done(at: point)
                    } else {
                        pendingSelection = done; pendingView = view
                        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
                    }
                    anchorOffset = nil; preview = nil
                default:
                    if let old = preview { restoreBackground(old, in: view) }
                    anchorOffset = nil; preview = nil
                }
                return
            }
            switch gesture.state {
            case .began, .changed:
                moveBand(to: point, in: view)
                if let index = wordIndex(at: point, in: view), index != lastPenIndex {
                    lastPenIndex = index
                    onPenWord?(index)
                }
            default:
                lastPenIndex = -1
                band?.isHidden = true
            }
        }

        func apply(text: String, to view: UITextView) {
            self.text = text
            lastRange = nil; lastIndex = -1
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 7
            paragraph.paragraphSpacing = 10
            view.attributedText = NSAttributedString(string: text, attributes: [
                .font: Koe.readerFont(21), .foregroundColor: Koe.inkUI, .paragraphStyle: paragraph,
            ])
        }

        func resetHighlight(in view: UITextView) {
            if let old = lastRange, NSMaxRange(old) <= view.textStorage.length { restoreBackground(old, in: view) }
            lastRange = nil; lastIndex = -1
        }

        func highlight(index: Int, in view: UITextView) {
            guard index != lastIndex else { return }
            lastIndex = index
            let storage = view.textStorage
            let length = storage.length
            if let old = lastRange, NSMaxRange(old) <= length { restoreBackground(old, in: view) }
            lastRange = nil
            guard index >= 0, index < ranges.count else { return }
            let range = ranges[index]
            guard range.location >= 0, NSMaxRange(range) <= length, range.length > 0 else { return }
            storage.addAttribute(.backgroundColor, value: Koe.highlightFill, range: range)
            lastRange = range
            keepVisible(range, in: view)
        }

        private func keepVisible(_ range: NSRange, in view: UITextView) {
            let layout = view.layoutManager
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: view.textContainer)
            rect.origin.y += view.textContainerInset.top
            let visible = CGRect(origin: view.contentOffset, size: view.bounds.size).insetBy(dx: 0, dy: 90)
            guard !visible.contains(rect) else { return }
            let target = max(0, rect.midY - view.bounds.height * 0.4)
            view.setContentOffset(CGPoint(x: 0, y: min(target, max(0, view.contentSize.height - view.bounds.height))), animated: true)
        }

        private func clearPendingSelection(in view: UITextView) {
            if let sel = pendingSelection { restoreBackground(sel, in: view) }
            pendingSelection = nil
        }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                                 suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let sel = pendingSelection, let view = pendingView else { return nil }
            var children: [UIMenuElement] = KoeHighlightColor.allCases.map { color in
                UIAction(title: color.label, image: UIImage(systemName: "circle.fill")?
                    .withTintColor(color.ui.withAlphaComponent(1), renderingMode: .alwaysOriginal)) { [weak self] _ in
                    guard let self else { return }
                    self.restoreBackground(sel, in: view); self.pendingSelection = nil
                    self.onMark?(sel, color)
                }
            }
            if boards.isEmpty {
                children.append(UIAction(title: "Save to Board", image: UIImage(systemName: "rectangle.stack.badge.plus"), attributes: .disabled) { _ in })
            } else {
                children.append(UIMenu(title: "Save to Board", image: UIImage(systemName: "rectangle.stack.badge.plus"),
                                       children: boards.map { board in
                    UIAction(title: board.1) { [weak self] _ in
                        guard let self else { return }
                        self.restoreBackground(sel, in: view); self.pendingSelection = nil
                        self.onSaveToBoard?(sel, board.0)
                    }
                }))
            }
            children.append(UIAction(title: "Read from here", image: UIImage(systemName: "play.fill")) { [weak self] _ in
                guard let self else { return }
                self.restoreBackground(sel, in: view); self.pendingSelection = nil
                if let i = self.ranges.firstIndex(where: { NSMaxRange($0) > sel.location }) { self.onTapWord(i) }
            })
            if marks.contains(where: { NSIntersectionRange($0.range, sel).length > 0 }) {
                children.append(UIAction(title: "Remove", image: UIImage(systemName: "eraser"), attributes: .destructive) { [weak self] _ in
                    guard let self else { return }
                    self.restoreBackground(sel, in: view); self.pendingSelection = nil
                    self.onUnmark?(sel)
                })
            }
            return UIMenu(options: .displayInline, children: children)
        }

        func editMenuInteraction(_ interaction: UIEditMenuInteraction, willDismissMenuFor configuration: UIEditMenuConfiguration,
                                 animator: UIEditMenuInteractionAnimating) {
            // Tapped away without choosing: drop the selection wash.
            if let view = pendingView { animator.addCompletion { [weak self] in self?.clearPendingSelection(in: view) } }
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? UITextView else { return }
            let point = gesture.location(in: view)
            guard let position = view.closestPosition(to: point) else { return }
            let offset = view.offset(from: view.beginningOfDocument, to: position)
            if markMode, let hit = marks.first(where: { $0.location <= offset && offset < $0.upperBound }) { onUnmark?(hit.range); return }
            if let hit = ranges.firstIndex(where: { $0.location <= offset && offset < NSMaxRange($0) }) { onTapWord(hit); return }
            if let next = ranges.firstIndex(where: { $0.location >= offset }) { onTapWord(next) }
        }
    }
}


// MARK: - Pencil gestures

/// Double-tap (Pencil 2 / Pro) and squeeze (Pencil Pro) toggle play/pause.
/// The USB-C Pencil has neither; the on-screen button still works.
struct PencilGestures: ViewModifier {
    let action: () -> Void
    func body(content: Content) -> some View {
        if #available(iOS 17.5, *) {
            content
                .onPencilDoubleTap { _ in action() }
                .onPencilSqueeze { phase in if case .ended = phase { action() } }
        } else {
            content
        }
    }
}


// MARK: - Highlights list

struct MarksSheet: View {
    @ObservedObject var player: ChapterPlayer
    var boards: [(UUID, String)] = []
    var onSaveToBoard: ((NSRange, UUID) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if player.marks.isEmpty {
                    ContentUnavailableView("No highlights yet", systemImage: "highlighter",
                                           description: Text("Turn on the highlighter and drag the Pencil across the text."))
                } else {
                    List {
                        ForEach(player.marks) { mark in
                            Button {
                                player.seek(toMark: mark); dismiss()
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    RoundedRectangle(cornerRadius: 3).fill(mark.color.swatch).frame(width: 6).padding(.vertical, 2)
                                    Text(player.excerpt(mark)).font(Koe.serif(16)).foregroundStyle(Koe.ink).multilineTextAlignment(.leading)
                                }
                            }
                            .contextMenu {
                                if boards.isEmpty { Text("No boards yet") } else {
                                    ForEach(boards, id: \.0) { board in
                                        Button { onSaveToBoard?(mark.range, board.0) } label: { Label("Save to \(board.1)", systemImage: "rectangle.stack.badge.plus") }
                                    }
                                }
                            }
                        }
                        .onDelete { offsets in
                            for i in offsets.sorted(by: >) where i < player.marks.count { player.unmark(player.marks[i].range) }
                        }
                    }
                }
            }
            .navigationTitle("Highlights")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
