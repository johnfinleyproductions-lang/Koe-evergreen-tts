import SwiftUI

/// The Mac's Idea Canvas: sticky notes on a dot grid with links. Pan with a
/// finger; tap a card to hear it. Editing stays on the Mac for now.
struct CanvasView: View {
    @EnvironmentObject var docs: MacDocuments
    @EnvironmentObject var sync: StateSync
    @State private var selected: CanvasNote?
    private let card = CGSize(width: 220, height: 150)

    var body: some View {
        NavigationStack {
            Group {
                if docs.notes.isEmpty {
                    ContentUnavailableView {
                        Label("The canvas is empty", systemImage: "square.grid.3x3")
                    } description: {
                        Text(sync.available ? "Cards you place on the Mac's Idea Canvas appear here." : "Evergreen doesn't have the sync store yet.")
                    } actions: {
                        Button("Refresh") { Task { await sync.pullAll(force: true) } }.tint(Koe.shu)
                    }
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: .topLeading) {
                            DotGrid().frame(width: size.width, height: size.height)
                            Path { path in
                                for link in docs.links {
                                    guard let a = docs.notes.first(where: { $0.id == link.from }), let b = docs.notes.first(where: { $0.id == link.to }) else { continue }
                                    path.move(to: center(a)); path.addLine(to: center(b))
                                }
                            }
                            .stroke(Koe.faint.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                            ForEach(docs.notes) { note in
                                NoteCard(note: note, size: card)
                                    .rotationEffect(.degrees(note.tilt))
                                    .position(center(note))
                                    .onTapGesture { selected = note }
                            }
                        }
                        .frame(width: size.width, height: size.height)
                    }
                    .background(Koe.desk)
                }
            }
            .navigationTitle("Canvas")
            .refreshable { await sync.pullAll(force: true) }
            .toolbar { ToolbarItem(placement: .topBarLeading) { Text("声").font(Koe.serif(24, .semibold)).foregroundStyle(Koe.shu) } }
            .sheet(item: $selected) { note in
                NavigationStack { SnippetReaderView(title: "Canvas card", text: note.text, source: note.source) }
            }
        }
    }

    private var origin: CGPoint {
        CGPoint(x: (docs.notes.map(\.x).min() ?? 0) - 60, y: (docs.notes.map(\.y).min() ?? 0) - 60)
    }
    private var size: CGSize {
        let maxX = (docs.notes.map(\.x).max() ?? 0) + card.width + 120
        let maxY = (docs.notes.map(\.y).max() ?? 0) + card.height + 120
        return CGSize(width: max(600, maxX - origin.x), height: max(600, maxY - origin.y))
    }
    private func center(_ note: CanvasNote) -> CGPoint {
        CGPoint(x: note.x - origin.x + card.width / 2, y: note.y - origin.y + card.height / 2)
    }
}

private struct NoteCard: View {
    let note: CanvasNote
    let size: CGSize
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(note.text).font(Koe.serif(15)).foregroundStyle(Color(hex: 0x2C2620)).lineLimit(6)
            Spacer(minLength: 0)
            HStack {
                if !note.source.isEmpty { Text(note.source).font(.caption2).foregroundStyle(Color(hex: 0x6F6557)).lineLimit(1) }
                Spacer()
                Image(systemName: "play.circle.fill").foregroundStyle(Koe.shu)
            }
        }
        .padding(12)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(Color(hex: MacDocuments.canvasColors[abs(note.colorIndex) % MacDocuments.canvasColors.count]), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
    }
}

private struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 28
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 2, height: 2)), with: .color(Koe.faint.opacity(0.35)))
                    x += step
                }
                y += step
            }
        }
    }
}
