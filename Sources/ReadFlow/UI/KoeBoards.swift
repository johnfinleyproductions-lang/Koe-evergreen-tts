//
//  KoeBoards.swift
//  ReadFlow / Koe
//
//  Boards (棚) — named collections of saved reading snippets. You save a passage
//  to a board while reading; each saved card remembers its source and can be
//  re-listened with ▶. Deliberately minimal (matching the canvas philosophy):
//  an overview grid of boards, and a board's detail list. Persists to UserDefaults.
//

import SwiftUI
import Foundation

// MARK: - Model

struct BoardItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var text: String
    var source: String = ""
    var kind: String = "read"     // "read" (full passage) | "clip" (short quote)
}

struct Board: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var accentHex: UInt32
    var items: [BoardItem] = []
}

// MARK: - Store (persisted)

@MainActor
final class BoardStore: ObservableObject {
    static let shared = BoardStore()

    @Published var boards: [Board] = []

    private let key = "readflow.boards"
    private let defaults = UserDefaults.standard
    private let accents: [UInt32] = [0x7C8A5B, 0xCF9B4A, 0x33455F, 0xC0432D]

    init() {
        load()
        if boards.isEmpty {
            boards = [
                Board(name: "Evergreen", accentHex: 0x7C8A5B),
                Board(name: "Research", accentHex: 0x33455F),
                Board(name: "Read later", accentHex: 0xCF9B4A),
            ]
            save()
        }
    }

    func load() {
        if let d = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Board].self, from: d) { boards = decoded }
    }

    func save() {
        if let d = try? JSONEncoder().encode(boards) { defaults.set(d, forKey: key) }
    }

    @discardableResult
    func addBoard(name: String = "New board") -> UUID {
        let accent = accents[boards.count % accents.count]
        let b = Board(name: name, accentHex: accent)
        boards.append(b)
        save()
        return b.id
    }

    func removeBoard(_ id: UUID) { boards.removeAll { $0.id == id }; save() }

    func addItem(_ item: BoardItem, to boardID: UUID) {
        guard let i = boards.firstIndex(where: { $0.id == boardID }) else { return }
        boards[i].items.insert(item, at: 0)
        save()
    }

    func removeItem(_ itemID: UUID, from boardID: UUID) {
        guard let i = boards.firstIndex(where: { $0.id == boardID }) else { return }
        boards[i].items.removeAll { $0.id == itemID }
        save()
    }
}

// MARK: - Boards view (overview + detail)

struct KoeBoardsView: View {
    @ObservedObject var model: ReaderHUDModel
    @ObservedObject var store = BoardStore.shared
    @State private var openedID: UUID?
    private var palette: KoePalette { model.palette }

    var body: some View {
        ZStack {
            palette.s1
            if let openedID, let idx = store.boards.firstIndex(where: { $0.id == openedID }) {
                BoardDetail(board: $store.boards[idx], model: model, palette: palette,
                            onBack: { self.openedID = nil },
                            onSave: { store.save() },
                            onDelete: { store.removeBoard(openedID); self.openedID = nil })
            } else {
                overview
            }
        }
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Boards").font(KoeFont.mincho(30, bold: true)).foregroundStyle(palette.ink)
                    Text("棚 · saved from reading").font(KoeFont.mincho(14)).foregroundStyle(palette.mute)
                    Spacer()
                    Button { openedID = store.addBoard() } label: {
                        HStack(spacing: 6) { Image(systemName: "plus"); Text("New board").font(KoeFont.gothic(12.5, .bold)) }
                            .foregroundStyle(palette.faint)
                            .padding(.horizontal, 13).padding(.vertical, 8)
                            .overlay(Capsule().stroke(palette.dash, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    }
                    .buttonStyle(.plain)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 20)], alignment: .leading, spacing: 20) {
                    ForEach(store.boards) { board in
                        boardCard(board)
                    }
                }
            }
            .padding(34)
        }
    }

    private func boardCard(_ board: Board) -> some View {
        let accent = Color(hex: board.accentHex)
        let reads = board.items.filter { $0.kind == "read" }.count
        let clips = board.items.count - reads
        return Button { openedID = board.id } label: {
            HStack(spacing: 0) {
                Rectangle().fill(accent).frame(width: 6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Circle().fill(accent).frame(width: 9, height: 9)
                        Text(board.name).font(KoeFont.mincho(16.5, bold: true)).foregroundStyle(palette.ink).lineLimit(1)
                    }
                    Text("\(board.items.count) saved · \(reads) reads · \(clips) clips")
                        .font(KoeFont.mono(11)).foregroundStyle(palette.mute)
                        .padding(.bottom, 6)
                    if board.items.isEmpty {
                        Text("Empty — save a read here").font(KoeFont.mincho(12.5)).italic().foregroundStyle(palette.faint2)
                    } else {
                        ForEach(board.items.prefix(2)) { it in
                            Text("“\(it.text.prefix(70))\(it.text.count > 70 ? "…" : "")”")
                                .font(KoeFont.mincho(12.5)).italic().foregroundStyle(palette.soft)
                                .lineLimit(2)
                                .padding(.leading, 9)
                                .overlay(Rectangle().fill(palette.line2).frame(width: 2), alignment: .leading)
                        }
                    }
                    Text("Open board →").font(KoeFont.gothic(12, .bold)).foregroundStyle(accent).padding(.top, 10)
                }
                .padding(16)
                Spacer(minLength: 0)
            }
            .background(palette.s0)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 1))
            .shadow(color: Color(hex: 0x46371E, alpha: 0.18), radius: 12, y: 8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Board detail

private struct BoardDetail: View {
    @Binding var board: Board
    @ObservedObject var model: ReaderHUDModel
    let palette: KoePalette
    let onBack: () -> Void
    let onSave: () -> Void
    let onDelete: () -> Void

    private var accent: Color { Color(hex: board.accentHex) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button(action: onBack) {
                    HStack(spacing: 6) { Image(systemName: "chevron.left"); Text("All boards").font(KoeFont.gothic(12.5, .medium)) }
                        .foregroundStyle(palette.faint)
                }
                .buttonStyle(.plain)

                HStack(spacing: 12) {
                    Circle().fill(accent).frame(width: 14, height: 14)
                    TextField("Board name", text: $board.name)
                        .textFieldStyle(.plain)
                        .font(KoeFont.mincho(28, bold: true)).foregroundStyle(palette.ink)
                        .onSubmit { onSave() }
                        .frame(maxWidth: 360)
                    Spacer()
                    Button(action: saveCurrentRead) {
                        HStack(spacing: 6) { Image(systemName: "plus"); Text("Save current read").font(KoeFont.gothic(12.5, .bold)) }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 13).padding(.vertical, 8)
                            .background(Capsule().fill(accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.words.isEmpty)

                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash").foregroundStyle(palette.faint)
                    }
                    .buttonStyle(.plain).help("Delete this board")
                }

                if board.items.isEmpty {
                    Text("Nothing saved yet.\nWhile reading, use “Save to board”, or click “Save current read”.")
                        .font(KoeFont.mincho(15)).foregroundStyle(palette.faint).lineSpacing(5)
                        .padding(.top, 30).frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(board.items) { item in
                            itemCard(item)
                        }
                    }
                }
            }
            .padding(34)
        }
    }

    private func itemCard(_ item: BoardItem) -> some View {
        let isRead = item.kind == "read"
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text(item.kind.uppercased())
                    .font(KoeFont.gothic(9, .bold)).tracking(1)
                    .foregroundStyle(isRead ? Color(hex: 0xA3361F) : palette.noteBlue)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(isRead ? palette.tintShu : palette.tintAi))
                Spacer()
                if !item.source.isEmpty {
                    Text(item.source).font(KoeFont.mono(10)).foregroundStyle(palette.mute).lineLimit(1)
                }
            }
            .padding(.bottom, 9)

            Text(item.text).font(KoeFont.mincho(14.5)).foregroundStyle(palette.ink2)
                .lineLimit(5).fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button { play(item.text) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.circle.fill").font(.system(size: 16)).foregroundStyle(palette.shu)
                        Text("Play").font(KoeFont.gothic(11)).foregroundStyle(palette.faint)
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                Button { board.items.removeAll { $0.id == item.id }; onSave() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(palette.faint2)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 13)
        }
        .padding(16)
        .background(palette.s0)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.line, lineWidth: 1))
        .shadow(color: Color(hex: 0x46371E, alpha: 0.16), radius: 10, y: 6)
    }

    private func saveCurrentRead() {
        let text = model.words.map(\.text).joined(separator: " ")
        guard !text.isEmpty else { return }
        board.items.insert(BoardItem(text: text, source: model.title, kind: "read"), at: 0)
        onSave()
    }

    private func play(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        NotificationCenter.default.post(name: .readFlowReadExternalText, object: text)
    }
}
