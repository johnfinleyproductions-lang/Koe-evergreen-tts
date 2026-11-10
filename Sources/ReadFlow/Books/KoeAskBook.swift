//
//  KoeAskBook.swift
//  Koe (Mac) — Ask the book: a question about the current chapter (or the whole
//  book) goes to Evergreen, which finds the passages and answers with the house
//  local model. The answer is read aloud by Koe's reading voice and can go to a Board.
//
import SwiftUI
import AppKit

struct KoeAskAnswer: Decodable {
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

enum KoeAskError: LocalizedError {
    case server(String), timeout, notConfigured(String), missing
    var errorDescription: String? {
        switch self {
        case .server(let m): m
        case .timeout: "The model took too long to answer. Try a shorter question."
        case .notConfigured(let m): m
        case .missing: "Evergreen doesn't have Ask the book yet (update Core)."
        }
    }
}

extension KoeBookConnection {
    /// POST /api/reader/books/{id}/ask with Koe's own sign-in session.
    func ask(_ book: KoeBook, question: String, chapterId: String?) async throws -> KoeAskAnswer {
        try await useOwnSignInSession(for: book)
        let url = try endpoint("/api/reader/books/" + book.id + "/ask", book: book)
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 90
        var body: [String: Any] = ["question": question, "device": "mac"]
        if let chapterId { body["chapterId"] = chapterId }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var origin = "\(url.scheme ?? "http")://\(url.host ?? "")"
        if let port = url.port { origin += ":\(port)" }
        request.setValue(origin, forHTTPHeaderField: "Origin")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw KoeAskError.server("No response from Evergreen.") }
        struct Failure: Decodable { var error: String }
        let message = (try? JSONDecoder().decode(Failure.self, from: data))?.error
        switch http.statusCode {
        case 200: return try JSONDecoder().decode(KoeAskAnswer.self, from: data)
        case 401: throw KoeBookError.signIn
        case 404: throw message == nil ? KoeAskError.missing : KoeAskError.server(message!)
        case 503: throw KoeAskError.notConfigured(message ?? "Evergreen has no local model set up for Ask the book yet.")
        case 504: throw KoeAskError.timeout
        default: throw KoeAskError.server(message ?? "Evergreen answered HTTP \(http.statusCode).")
        }
    }
}

/// The Ask sheet. Reads the answer aloud through Koe's main reading voice.
struct KoeAskBookView: View {
    let book: KoeBook
    let chapter: KoeBookChapter?
    let connection: KoeBookConnection
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var boards = BoardStore.shared
    @AppStorage("koe.ask.autoRead") private var autoRead = true
    @State private var question = ""
    @State private var wholeBook = false
    @State private var busy = false
    @State private var answer: KoeAskAnswer?
    @State private var error: String?
    @State private var showPassages = false
    @State private var saved: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ask the book").font(KoeFont.mincho(22, bold: true))
                    Text(chapter.map { "\(book.title) · Chapter \($0.position), \($0.title)" } ?? book.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if chapter != nil {
                Picker("Scope", selection: $wholeBook) { Text("This chapter").tag(false); Text("Whole book").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            }
            HStack(alignment: .top, spacing: 10) {
                TextField("Ask about what you're reading…", text: $question, axis: .vertical)
                    .lineLimit(1...4).textFieldStyle(.roundedBorder).font(.title3).focused($focused)
                    .onSubmit(send)
                Button(action: send) { Label("Ask", systemImage: "arrow.up.circle.fill") }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || question.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(wholeBook || chapter == nil ? "Reading the book…" : "Reading the chapter…").font(.callout).foregroundStyle(.secondary) }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let answer {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(answer.answer).font(KoeFont.mincho(17)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            Button { read(answer.answer) } label: { Label("Read aloud", systemImage: "play.circle.fill") }
                            Toggle("Read answers automatically", isOn: $autoRead).toggleStyle(.checkbox).font(.callout)
                            Spacer()
                            if !boards.boards.isEmpty {
                                Menu {
                                    ForEach(boards.boards) { board in Button(board.name) { save(answer.answer, to: board) } }
                                } label: { Label("Save to Board", systemImage: "rectangle.stack.badge.plus") }
                                .frame(width: 150)
                            }
                        }
                        if let saved { Text(saved).font(.caption).foregroundStyle(.secondary) }
                        if !answer.passages.isEmpty {
                            DisclosureGroup("Where this came from", isExpanded: $showPassages) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(answer.passages) { p in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Chapter \(p.position) · \(p.chapterTitle)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                            Text(p.excerpt).font(.callout).textSelection(.enabled)
                                        }
                                    }
                                }.padding(.top, 4)
                            }.font(.callout)
                        }
                        Text("Answered by \(answer.model) on Evergreen, from the book's own text.").font(.caption2).foregroundStyle(.tertiary)
                    }.padding(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 360, idealHeight: 520)
        .onAppear { focused = true }
    }

    private func send() {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !busy else { return }
        busy = true; error = nil; answer = nil; saved = nil
        let scopeChapter = wholeBook ? nil : chapter?.id
        Task { @MainActor in
            defer { busy = false }
            do {
                let result = try await connection.ask(book, question: q, chapterId: scopeChapter)
                answer = result
                if autoRead { read(result.answer) }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func read(_ text: String) {
        NotificationCenter.default.post(name: .readFlowReadExternalText, object: text)
    }

    private func save(_ text: String, to board: Board) {
        var source = "Ask · \(book.title)"
        if let chapter, !wholeBook { source += " · \(chapter.title)" }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        boards.addItem(BoardItem(text: q.isEmpty ? text : "Q: \(q)\n\(text)", source: source, kind: "read"), to: board.id)
        saved = "Saved to \(board.name)"
    }
}
