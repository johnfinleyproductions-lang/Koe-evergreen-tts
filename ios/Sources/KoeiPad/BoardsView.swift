import SwiftUI

struct BoardsView: View {
    @EnvironmentObject var docs: MacDocuments
    @EnvironmentObject var sync: StateSync

    var body: some View {
        NavigationStack {
            Group {
                if docs.boards.isEmpty {
                    ContentUnavailableView {
                        Label("No boards yet", systemImage: "rectangle.stack")
                    } description: {
                        Text(sync.available ? "Boards you save in Koe on the Mac appear here." : "Evergreen doesn't have the sync store yet.")
                    } actions: {
                        Button("Refresh") { Task { await sync.pullAll(force: true) } }.tint(Koe.shu)
                    }
                } else {
                    List(docs.boards) { board in
                        NavigationLink(value: board) {
                            HStack(spacing: 14) {
                                RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color(hex: board.accentHex)).frame(width: 10, height: 40)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(board.name).font(Koe.serif(19, .semibold)).foregroundStyle(Koe.ink)
                                    Text("\(board.items.count) saved").font(.footnote).foregroundStyle(Koe.faint)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(Koe.paper)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Koe.desk)
            .navigationTitle("Boards")
            .navigationDestination(for: Board.self) { BoardDetailView(board: $0) }
            .refreshable { await sync.pullAll(force: true) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Text("声").font(Koe.serif(24, .semibold)).foregroundStyle(Koe.shu) }
            }
        }
    }
}

struct BoardDetailView: View {
    let board: Board
    var body: some View {
        List(board.items) { item in
            NavigationLink {
                SnippetReaderView(title: board.name, text: item.text, source: item.source)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.text).font(Koe.serif(16)).foregroundStyle(Koe.ink).lineLimit(3)
                    HStack(spacing: 8) {
                        Text(item.kind == "clip" ? "Quote" : "Passage").font(.caption.weight(.medium))
                            .padding(.horizontal, 7).padding(.vertical, 2).background(Color(hex: board.accentHex).opacity(0.18), in: Capsule())
                        if !item.source.isEmpty { Text(item.source).font(.caption).foregroundStyle(Koe.faint).lineLimit(1) }
                    }
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Koe.paper)
        }
        .scrollContentBackground(.hidden)
        .background(Koe.desk)
        .navigationTitle(board.name)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if board.items.isEmpty { ContentUnavailableView("Nothing saved here", systemImage: "rectangle.stack") }
        }
    }
}
