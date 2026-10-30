import PDFKit
import SwiftUI
import UIKit

struct ReaderView: View {
    @EnvironmentObject var client: CoreClient
    @Environment(\.horizontalSizeClass) private var sizeClass
    @StateObject private var player = ChapterPlayer()
    let book: BookInfo
    let chapters: [Chapter]
    let chapter: Chapter
    let place: Place?
    @State private var pdfURL: URL?
    @State private var pdfError: String?
    @State private var showPDF = true

    var body: some View {
        VStack(spacing: 0) {
            content
            TransportBar(player: player, book: book, chapter: chapter, showPDF: $showPDF)
        }
        .background(Koe.readerBg)
        .navigationTitle(chapter.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { withAnimation { showPDF.toggle() } } label: {
                    Image(systemName: showPDF ? "doc.text.image" : "doc.plaintext")
                }.tint(Koe.ink2)
            }
        }
        .task {
            async let load: Void = player.load(client: client, book: book, chapters: chapters, chapter: chapter, place: place)
            async let pdf: Void = loadPDF()
            _ = await (load, pdf)
        }
        .onDisappear { player.stop() }
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
            PDFPageView(url: pdfURL, page: player.page) { manualPage in
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
        HighlightTextView(text: reading.sourceText, ranges: player.highlightRanges, currentIndex: player.highlightIndex) { index in
            player.seek(toWord: index)
        }
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
                            Image(systemName: player.followPages ? "text.line.first.and.arrowtriangle.forward" : "text.line.first.and.arrowtriangle.forward")
                                .foregroundStyle(player.followPages ? Koe.shu : Koe.faint)
                        }
                        .help("Follow the narration")
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
    let onManualPage: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onManualPage: onManualPage) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.autoScales = true
        view.usePageViewController(false)        // keep touches available for PencilKit overlays later
        view.backgroundColor = .clear
        view.document = PDFDocument(url: url)
        context.coordinator.attach(view)
        context.coordinator.show(page, in: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
        context.coordinator.show(page, in: view)
    }

    final class Coordinator: NSObject {
        let onManualPage: (Int) -> Void
        private var programmatic = false
        private var observer: NSObjectProtocol?
        init(onManualPage: @escaping (Int) -> Void) { self.onManualPage = onManualPage }
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
    let onTapWord: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTapWord: onTapWord) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = false
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 28, left: 28, bottom: 120, right: 28)
        view.alwaysBounceVertical = true
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.ranges = ranges
        context.coordinator.apply(text: text, to: view)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if context.coordinator.ranges != ranges { context.coordinator.ranges = ranges; context.coordinator.resetHighlight(in: view) }
        if context.coordinator.text != text { context.coordinator.apply(text: text, to: view) }
        context.coordinator.highlight(index: currentIndex, in: view)
    }

    final class Coordinator: NSObject {
        let onTapWord: (Int) -> Void
        var ranges: [NSRange] = []
        var text = ""
        private var lastRange: NSRange?
        private var lastIndex = -1
        init(onTapWord: @escaping (Int) -> Void) { self.onTapWord = onTapWord }

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
            if let old = lastRange, NSMaxRange(old) <= view.textStorage.length {
                view.textStorage.removeAttribute(.backgroundColor, range: old)
            }
            lastRange = nil; lastIndex = -1
        }

        func highlight(index: Int, in view: UITextView) {
            guard index != lastIndex else { return }
            lastIndex = index
            let storage = view.textStorage
            let length = storage.length
            if let old = lastRange, NSMaxRange(old) <= length {
                storage.removeAttribute(.backgroundColor, range: old)
            }
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

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? UITextView else { return }
            let point = gesture.location(in: view)
            guard let position = view.closestPosition(to: point) else { return }
            let offset = view.offset(from: view.beginningOfDocument, to: position)
            if let hit = ranges.firstIndex(where: { $0.location <= offset && offset < NSMaxRange($0) }) { onTapWord(hit); return }
            if let next = ranges.firstIndex(where: { $0.location >= offset }) { onTapWord(next) }
        }
    }
}
