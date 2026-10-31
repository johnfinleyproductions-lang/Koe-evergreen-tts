import SwiftUI

/// Ask the book: a question about this chapter (or the whole book) goes to
/// Evergreen, which finds the passages and answers with the house local model.
/// The answer is read aloud, word by word, and can be saved to a Board.
struct AskAnswer: Decodable {
    struct Passage: Decodable, Identifiable {
        var chapterId: String; var chapterTitle: String; var position: Int; var excerpt: String
        var id: String { chapterId + "#" + String(position) + excerpt.prefix(24) }
    }
    var answer: String
    var model: String
    var scope: String
    var passages: [Passage]
    var elapsedMs: Double?
}

@MainActor
final class AskBook: ObservableObject {
    @Published var question = ""
    @Published var wholeBook = false
    @Published var answer: AskAnswer?
    @Published var busy = false
    @Published var error: String?

    func ask(client: CoreClient, bookId: String, chapterId: String?) async {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        busy = true; error = nil; answer = nil
        defer { busy = false }
        var body: [String: Any] = ["question": q, "device": "ipad"]
        if let chapterId, !wholeBook { body["chapterId"] = chapterId }
        do {
            let reply = try await client.rawJSON("POST", "/api/reader/books/\(bookId)/ask", body: body, timeout: 90)
            struct Failure: Decodable { var error: String }
            switch reply.status {
            case 200: answer = try JSONDecoder().decode(AskAnswer.self, from: reply.data)
            case 503: error = (try? JSONDecoder().decode(Failure.self, from: reply.data).error) ?? "Evergreen has no local model set up for Ask the book yet."
            case 504: error = "The model took too long to answer. Try a shorter question."
            case 404: error = "Evergreen doesn't have Ask the book yet (update Core)."
            default: error = (try? JSONDecoder().decode(Failure.self, from: reply.data).error) ?? "Evergreen answered HTTP \(reply.status)."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct AskBookView: View {
    let book: BookInfo
    let chapter: Chapter?
    @EnvironmentObject var client: CoreClient
    @EnvironmentObject var docs: MacDocuments
    @Environment(\.dismiss) private var dismiss
    @StateObject private var ask = AskBook()
    @StateObject private var speaker = TextSpeaker()
    @AppStorage("koe.ask.autoRead") private var autoRead = true
    @State private var showPassages = false
    @State private var savedToast: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(book.title).font(Koe.serif(20, .semibold)).foregroundStyle(Koe.ink)
                        if let chapter { Text("Chapter \(chapter.position) · \(chapter.title)").font(.subheadline).foregroundStyle(Koe.ink2) }
                    }
                    if chapter != nil {
                        Picker("Scope", selection: $ask.wholeBook) {
                            Text("This chapter").tag(false)
                            Text("Whole book").tag(true)
                        }.pickerStyle(.segmented)
                    }
                    HStack(alignment: .bottom, spacing: 10) {
                        TextField("Ask about what you're reading…", text: $ask.question, axis: .vertical)
                            .lineLimit(1...4)
                            .textFieldStyle(.plain)
                            .font(Koe.serif(17))
                            .padding(12)
                            .background(Koe.paper2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .focused($focused)
                            .submitLabel(.send)
                            .onSubmit { send() }
                        Button(action: send) {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 36)).foregroundStyle(Koe.shu)
                        }
                        .disabled(ask.busy || ask.question.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if ask.busy {
                        HStack(spacing: 10) {
                            ProgressView().tint(Koe.shu)
                            Text(ask.wholeBook || chapter == nil ? "Reading the book…" : "Reading the chapter…").font(.footnote).foregroundStyle(Koe.ink2)
                        }
                    }
                    if let error = ask.error {
                        Text(error).font(.footnote).foregroundStyle(Koe.shu).padding(12)
                            .background(Koe.paper2, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if let answer = ask.answer {
                        VStack(alignment: .leading, spacing: 12) {
                            HighlightTextView(text: answer.answer, ranges: speaker.ranges, currentIndex: speaker.wordIndex, readingPen: false,
                                              onTapWord: { speaker.seek(toWord: $0) })
                                .frame(minHeight: 120, maxHeight: 260)
                                .background(Koe.paper)
                            HStack(spacing: 14) {
                                Button { speaker.toggle() } label: {
                                    Label(speaker.isPlaying ? "Pause" : "Read aloud", systemImage: speaker.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.subheadline.weight(.medium)).padding(.horizontal, 12).frame(height: 34).background(Koe.paper2, in: Capsule())
                                }
                                .tint(Koe.shu)
                                Toggle("Read answers automatically", isOn: $autoRead).toggleStyle(.switch).font(.footnote).tint(Koe.shu).fixedSize()
                                Spacer()
                                if !docs.boards.isEmpty {
                                    Menu {
                                        ForEach(docs.boards) { board in
                                            Button { save(answer.answer, to: board) } label: { Label(board.name, systemImage: "rectangle.stack.badge.plus") }
                                        }
                                    } label: {
                                        Label("Save to Board", systemImage: "rectangle.stack.badge.plus")
                                            .font(.subheadline.weight(.medium)).padding(.horizontal, 12).frame(height: 34).background(Koe.paper2, in: Capsule())
                                    }
                                    .tint(Koe.ink)
                                }
                            }
                            if speaker.preparing { Text("Preparing voice…").font(.caption).foregroundStyle(Koe.ink2) }
                            if let e = speaker.error { Text(e).font(.caption).foregroundStyle(Koe.shu) }
                            if !answer.passages.isEmpty {
                                DisclosureGroup(isExpanded: $showPassages) {
                                    VStack(alignment: .leading, spacing: 10) {
                                        ForEach(answer.passages) { p in
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text("Chapter \(p.position) · \(p.chapterTitle)").font(.caption.weight(.semibold)).foregroundStyle(Koe.ink2)
                                                Text(p.excerpt).font(Koe.serif(14)).foregroundStyle(Koe.ink)
                                            }
                                        }
                                    }.padding(.top, 6)
                                } label: {
                                    Text("Where this came from").font(.footnote.weight(.medium)).foregroundStyle(Koe.ink2)
                                }
                            }
                            Text("Answered by \(answer.model) on Evergreen, from the book's own text.").font(.caption2).foregroundStyle(Koe.faint)
                        }
                        .padding(14)
                        .background(Koe.paper, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Koe.line, lineWidth: 1))
                    }
                }
                .padding(18)
            }
            .background(Koe.readerBg)
            .navigationTitle("Ask the book")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { speaker.stop(); dismiss() } } }
            .onAppear { focused = true }
            .onDisappear { speaker.stop() }
            .onChange(of: ask.answer?.answer) { text in
                guard let text else { return }
                speaker.stop(); speaker.load(text)
                if autoRead { speaker.play() }
            }
            .overlay(alignment: .bottom) {
                if let savedToast {
                    Text(savedToast).font(.footnote.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Koe.ink.opacity(0.9), in: Capsule()).foregroundStyle(Koe.paper).padding(.bottom, 24)
                }
            }
        }
    }

    private func send() {
        focused = false
        Task { await ask.ask(client: client, bookId: book.id, chapterId: chapter?.id) }
    }

    private func save(_ text: String, to board: Board) {
        var source = "Ask · \(book.title)"
        if let chapter, !ask.wholeBook { source += " · \(chapter.title)" }
        let q = ask.question.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = BoardWriter.save(text: q.isEmpty ? text : "Q: \(q)\n\(text)", source: source, to: board.id)
        withAnimation { savedToast = saved ? "Saved to \(board.name)" : "Couldn't save" }
        Task { try? await Task.sleep(for: .seconds(2)); withAnimation { savedToast = nil } }
    }
}
