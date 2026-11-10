import SwiftUI
import AppKit

@MainActor
struct KoeBooksView: View {
    @StateObject private var store = KoeBookStore.shared
    @ObservedObject var model: ReaderHUDModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if store.selectedBook != nil { Button("Bookshelf") { store.back() } }
                Text(store.selectedBook?.title ?? "Books").font(KoeFont.mincho(25, bold: true)).lineLimit(1)
                Spacer()
                Button("Import book…") { importBook() }
                if let book = store.selectedBook ?? store.books.first {
                    Button("Connect Evergreen") {
                        store.connection.onConnected = { Task { await store.refresh() } }
                        do { try store.connection.connect(book) } catch { store.message = error.localizedDescription }
                    }
                    Button(store.syncing ? "Refreshing…" : "Refresh chapters") { Task { await store.refresh() } }.disabled(store.syncing)
                }
            }.padding(16)
            if let message = store.message { Text(message).font(.caption).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom, 8) }
            Divider()
            if let book = store.selectedBook {
                KoeBookReadingView(book: book, store: store, player: store.player)
                    .id(book.id)
            } else if store.books.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "book.closed").font(.system(size: 42))
                    Text("Your original book pages, with narration.").font(.title3)
                    Text("Import a prepared Koe book to start. Existing recordings are reused.").foregroundStyle(.secondary)
                    Button("Import book…") { importBook() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 18)], spacing: 18) {
                        ForEach(store.books) { book in
                            Button { store.open(book) } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    Image(systemName: "book.closed.fill").font(.system(size: 36)).foregroundStyle(model.palette.shu)
                                    Text(book.title).font(KoeFont.mincho(22, bold: true)).multilineTextAlignment(.leading)
                                    Text(book.author).foregroundStyle(.secondary)
                                    Text("\(book.chapters.filter { $0.audioFile != nil }.count) of \(book.chapters.count) chapters cached · \(book.pageCount) pages").font(.caption).foregroundStyle(.secondary)
                                    Text("Open book →").font(.headline)
                                }.padding(22).frame(maxWidth: .infinity, minHeight: 210, alignment: .leading)
                                .background(model.palette.s2, in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                        }
                    }.padding(22)
                }
            }
        }
        .onAppear { store.watchForFinishedChapters() }
        .onDisappear { store.player.saveAndPause(); store.stopWatching() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in store.player.saveAndPause() }
    }
    private func importBook() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.title = "Import a prepared Koe book"; panel.prompt = "Import"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try store.importPackage(url) } catch { store.message = error.localizedDescription }
        }
    }
}

@MainActor
private struct KoeBookReadingView: View {
    let book: KoeBook
    @ObservedObject var store: KoeBookStore
    @ObservedObject var player: KoeBookPlayer
    @ObservedObject private var settings = Settings.shared
    @StateObject private var highlights: KoeBookHighlights
    @State private var pageEntry = ""
    @State private var showAsk = false
    init(book: KoeBook, store: KoeBookStore, player: KoeBookPlayer) {
        self.book = book; self.store = store; self.player = player
        _highlights = StateObject(wrappedValue: KoeBookHighlights(folder: store.directory(book), sourceHash: book.sourceSha256, pageCount: book.pageCount))
    }
    var body: some View {
        HSplitView {
            List(book.chapters, selection: Binding(get: { player.chapter?.id }, set: { id in if let id { store.open(book, chapterID: id) } })) { chapter in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(chapter.position). \(chapter.title)").font(.callout)
                    Text(player.voiceSource == .kokoro ? "Read with Kokoro" : chapter.audioFile != nil ? "Ready to listen" : chapter.status == "failed" ? "Needs retry in Evergreen" : "Audio being prepared")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 3).tag(chapter.id)
            }.listStyle(.sidebar).frame(minWidth: 150, idealWidth: 195, maxWidth: 260)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button { player.turnPage(player.page - 1) } label: { Image(systemName: "chevron.left") }.help("Previous page").accessibilityLabel("Previous page").disabled(player.page <= 1)
                    TextField("Page", text: $pageEntry).accessibilityLabel("PDF page number").frame(width: 45).onSubmit { if let value = Int(pageEntry) { player.turnPage(value) } }
                    Text("of \(book.pageCount)").font(.caption)
                    Button { player.turnPage(player.page + 1) } label: { Image(systemName: "chevron.right") }.help("Next page").accessibilityLabel("Next page").disabled(player.page >= book.pageCount)
                    Spacer()
                    Button { player.zoom = max(0.5, player.zoom - 0.25); player.save() } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out").accessibilityLabel("Zoom out")
                    Button("Fit") { player.zoom = 1; player.save() }
                    Button { player.zoom = min(3, player.zoom + 0.25); player.save() } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in").accessibilityLabel("Zoom in")
                    Text("\(Int(player.zoom * 100))%").font(.caption).monospacedDigit().frame(width: 40)
                }.padding(10)
                KoeBookHighlightControls(highlights: highlights, onPage: { player.turnPage($0) })
                KoePDFPageView(url: store.directory(book).appendingPathComponent("source.pdf"), page: player.page, zoom: player.zoom, highlights: highlights)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(player.chapter?.title ?? "Chapter").font(.headline).lineLimit(1)
                        Spacer()
                        Button { if player.isPlaying { player.toggle() }; showAsk = true } label: { Label("Ask the book…", systemImage: "questionmark.bubble") }
                            .help("Ask a question about this chapter or the whole book; Evergreen answers from the book's text.")
                        Picker("Voice", selection: Binding(get: { player.voiceSource }, set: { player.selectVoice($0) })) {
                            Text("Audiobook Narrator").tag(KoeBookVoiceSource.recorded)
                            Text("Kokoro · \(KoeBookVoiceSource.kokoroVoiceName(settings.kokoroVoice))").tag(KoeBookVoiceSource.kokoro)
                        }.frame(width: 210).accessibilityLabel("Book voice").help("Kokoro uses the voice and server in Koe's settings.")
                    }
                    if player.preparing { Text("Preparing Kokoro…").font(.caption).foregroundStyle(.secondary) }
                    if let error = player.error { Text(error).font(.caption).foregroundStyle(.red) }
                    HStack {
                        Button { player.rewind() } label: { Image(systemName: player.voiceSource == .kokoro ? "backward.end.fill" : "gobackward.15") }.help(player.voiceSource == .kokoro ? "Back 20 words" : "Back 15 seconds").accessibilityLabel(player.voiceSource == .kokoro ? "Back 20 words" : "Back 15 seconds")
                        Button { player.toggle() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }.help(player.isPlaying ? "Pause chapter" : "Play chapter").accessibilityLabel(player.isPlaying ? "Pause chapter" : "Play chapter").disabled(!player.canPlay)
                        Slider(value: Binding(get: { player.position }, set: { player.seek($0) }), in: 0...player.positionLimit).accessibilityLabel(player.voiceSource == .kokoro ? "Kokoro word position" : "Chapter position").disabled(!player.canPlay)
                        Text(player.voiceSource == .kokoro ? "Word \(min(player.wordCount, player.kokoroWord + 1)) / \(player.wordCount)" : "\(time(player.seconds)) / \(time(player.duration))").font(.caption).monospacedDigit()
                        Picker("Speed", selection: $player.rate) { ForEach([Float(0.75),1,1.25,1.5,2], id: \.self) { Text("\(Double($0), specifier: "%g")×").tag($0) } }.frame(width: 100)
                    }
                    HStack {
                        Toggle("Follow pages", isOn: Binding(get: { player.followPages }, set: { value in value ? player.resumeFollowing() : { player.followPages = false; player.save() }() }))
                            .disabled(!player.canFollowPages)
                        Spacer()
                        Text("PDF page \(player.page) · \(player.voiceSource == .kokoro ? "Kokoro follows spoken words." : "Page following uses approximate narration timing.")").font(.caption).foregroundStyle(.secondary)
                    }
                    DisclosureGroup("Original source and conversion notes") { Text(book.reviewPolicy).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                }.padding(12)
            }.frame(minWidth: 400)
        }
        .onAppear { pageEntry = String(player.page) }
        .sheet(isPresented: $showAsk) { KoeAskBookView(book: book, chapter: player.chapter, connection: store.connection) }
        .onChange(of: player.page) { pageEntry = String($0) }
        .onChange(of: player.rate) { _ in player.save() }
    }
    private func time(_ seconds: Double) -> String { let value = Int(max(0, seconds.isFinite ? seconds : 0)); return String(format: "%d:%02d", value / 60, value % 60) }
}
