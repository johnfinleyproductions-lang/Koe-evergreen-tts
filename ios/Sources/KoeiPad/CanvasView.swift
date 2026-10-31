import SwiftUI
import PencilKit

/// The Mac's Idea Canvas, editable from the iPad: sticky notes on a dot grid with
/// links, plus Pencil sketches as cards. Drag a card to move it, tap a text card
/// to hear it, tap a sketch to keep drawing. Everything syncs back to the Mac.
struct CanvasView: View {
    @EnvironmentObject var docs: MacDocuments
    @EnvironmentObject var sync: StateSync
    @StateObject private var inks = InkImages()
    @State private var selected: CanvasNote?
    @State private var editingSketch: CanvasNote?
    @State private var newSketch = false
    @State private var dragId: UUID?
    @State private var dragOffset: CGSize = .zero
    @State private var failure: String?
    private let card = CGSize(width: 220, height: 150)

    var body: some View {
        NavigationStack {
            Group {
                if docs.notes.isEmpty {
                    ContentUnavailableView {
                        Label("The canvas is empty", systemImage: "square.grid.3x3")
                    } description: {
                        Text(sync.available ? "Cards from the Mac's Idea Canvas appear here. Sketch one with the Pencil to start." : "Evergreen doesn't have the sync store yet.")
                    } actions: {
                        Button { newSketch = true } label: { Label("New sketch", systemImage: "pencil.tip.crop.circle.badge.plus") }.tint(Koe.shu)
                        Button("Refresh") { Task { await sync.pullAll(force: true) } }.tint(Koe.ink2)
                    }
                } else {
                    ScrollView([.horizontal, .vertical]) {
                        ZStack(alignment: .topLeading) {
                            DotGrid().frame(width: world.width, height: world.height)
                            Path { path in
                                for link in docs.links {
                                    guard let a = docs.notes.first(where: { $0.id == link.from }), let b = docs.notes.first(where: { $0.id == link.to }) else { continue }
                                    path.move(to: center(a)); path.addLine(to: center(b))
                                }
                            }
                            .stroke(Koe.faint.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
                            ForEach(docs.notes) { note in
                                cardView(note)
                                    .rotationEffect(.degrees(dragId == note.id ? 0 : note.tilt))
                                    .offset(dragId == note.id ? dragOffset : .zero)
                                    .position(center(note))
                                    .zIndex(dragId == note.id ? 10 : 0)
                            }
                        }
                        .frame(width: world.width, height: world.height)
                        .coordinateSpace(name: "world")
                    }
                    .background(Koe.desk)
                }
            }
            .navigationTitle("Canvas")
            .refreshable { await sync.pullAll(force: true) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Text("声").font(Koe.serif(24, .semibold)).foregroundStyle(Koe.shu) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newSketch = true } label: { Label("New sketch", systemImage: "pencil.tip.crop.circle.badge.plus") }
                        .tint(Koe.shu)
                }
            }
            .sheet(item: $selected) { note in
                NavigationStack { SnippetReaderView(title: "Canvas card", text: note.text, source: note.source) }
            }
            .fullScreenCover(isPresented: $newSketch) {
                SketchSheet(title: "New sketch") { drawing in
                    do { try CanvasWriter.addSketch(drawing) } catch { failure = error.localizedDescription }
                }
            }
            .fullScreenCover(item: $editingSketch) { note in
                SketchSheet(title: "Edit sketch", initial: note.ink.flatMap { inks.drawing($0) } ?? PKDrawing()) { drawing in
                    do { try CanvasWriter.updateSketch(note.id, drawing: drawing) } catch { failure = error.localizedDescription }
                }
            }
            .alert("Couldn't save the sketch", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(failure ?? "") }
        }
    }

    // MARK: Cards

    @ViewBuilder
    private func cardView(_ note: CanvasNote) -> some View {
        let size = cardSize(note)
        Group {
            if let key = note.ink {
                InkCard(note: note, image: inks.image(key), size: size)
            } else {
                NoteCard(note: note, size: size)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if note.ink != nil { editingSketch = note } else { selected = note }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 10, coordinateSpace: .named("world"))
                .onChanged { value in dragId = note.id; dragOffset = value.translation }
                .onEnded { value in
                    dragId = nil; dragOffset = .zero
                    CanvasWriter.move(note.id, to: CGPoint(x: note.x + value.translation.width, y: note.y + value.translation.height))
                }
        )
        .contextMenu {
            if note.ink != nil {
                Button { editingSketch = note } label: { Label("Edit sketch", systemImage: "pencil.tip") }
            } else {
                Button { selected = note } label: { Label("Read aloud", systemImage: "play.circle") }
            }
            Button { CanvasWriter.recolor(note.id) } label: { Label("Change colour", systemImage: "paintpalette") }
            Divider()
            Button(role: .destructive) { CanvasWriter.remove(note.id, sync: sync) } label: { Label("Delete", systemImage: "trash") }
        }
    }

    /// The world matches the Mac's canvas coordinates, so a card sits where the Mac put it.
    private var world: CGSize {
        let maxX = (docs.notes.map { $0.x + cardSize($0).width }.max() ?? 0) + 300
        let maxY = (docs.notes.map { $0.y + cardSize($0).height }.max() ?? 0) + 300
        return CGSize(width: max(2800, maxX), height: max(2000, maxY))
    }
    private func cardSize(_ note: CanvasNote) -> CGSize {
        guard let key = note.ink else { return card }
        guard let image = inks.image(key), image.size.width > 0 else { return CGSize(width: card.width, height: 140) }
        let height = min(360, max(110, card.width * image.size.height / image.size.width))
        return CGSize(width: card.width, height: height)
    }
    private func center(_ note: CanvasNote) -> CGPoint {
        let size = cardSize(note)
        return CGPoint(x: note.x + size.width / 2, y: note.y + size.height / 2)
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

/// A Pencil sketch on a sticky. The preview image is what the Mac shows too.
private struct InkCard: View {
    let note: CanvasNote
    let image: UIImage?
    let size: CGSize
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(width: size.width - 20)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Text("Sketch arriving…").font(.caption).foregroundStyle(Color(hex: 0x6F6557)).frame(maxWidth: .infinity, minHeight: 60)
            }
            if !note.text.isEmpty {
                Text(note.text).font(Koe.serif(12.5)).foregroundStyle(Color(hex: 0x2C2620)).lineLimit(2)
            }
        }
        .padding(10)
        .frame(width: size.width, alignment: .topLeading)
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
