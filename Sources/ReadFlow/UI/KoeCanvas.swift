//
//  KoeCanvas.swift
//  ReadFlow / Koe
//
//  The Idea Canvas — a calm dot-grid whiteboard of cards. Inspired by Curio's
//  "idea space" concept but deliberately minimal: ONE card type, one surface.
//  Koe's twist over a plain whiteboard: every card is LISTENABLE — it remembers
//  its source and has a ▶ to hear it again in the current voice.
//
//  Cards: add, drag to move, double-click to edit, recolor, delete, ▶ re-listen,
//  long text auto-collapses to a few lines (click to expand). Cards can be
//  connected with thin mindmap links (drag from a card's link handle to another
//  card). Notes + links persist to UserDefaults as JSON.
//

import SwiftUI
import Foundation

// MARK: - Model

struct CanvasNote: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var text: String
    var source: String = ""
    var x: Double
    var y: Double
    var colorIndex: Int
    var tilt: Double
}

struct CanvasLink: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var from: UUID
    var to: UUID
}

// MARK: - Store (persisted)

@MainActor
final class CanvasStore: ObservableObject {
    static let shared = CanvasStore()

    @Published var notes: [CanvasNote] = []
    @Published var links: [CanvasLink] = []

    private let notesKey = "readflow.canvasNotes"
    private let linksKey = "readflow.canvasLinks"
    private let defaults = UserDefaults.standard

    init() { load() }

    func load() {
        if let d = defaults.data(forKey: notesKey),
           let decoded = try? JSONDecoder().decode([CanvasNote].self, from: d) { notes = decoded }
        if let d = defaults.data(forKey: linksKey),
           let decoded = try? JSONDecoder().decode([CanvasLink].self, from: d) { links = decoded }
    }

    func save() {
        if let d = try? JSONEncoder().encode(notes) { defaults.set(d, forKey: notesKey) }
        if let d = try? JSONEncoder().encode(links) { defaults.set(d, forKey: linksKey) }
    }

    @discardableResult
    func add(_ text: String, source: String = "", at point: CGPoint? = nil) -> UUID {
        let n = notes.count
        let p = point ?? CGPoint(x: 320 + Double((n * 47) % 360),
                                 y: 200 + Double((n * 83) % 300))
        let note = CanvasNote(text: text, source: source, x: p.x, y: p.y,
                              colorIndex: n % CanvasColors.sticky.count,
                              tilt: Double((n % 5) - 2) * 1.2)
        notes.append(note)
        save()
        return note.id
    }

    func remove(_ id: UUID) {
        notes.removeAll { $0.id == id }
        links.removeAll { $0.from == id || $0.to == id }   // drop dangling links
        save()
    }

    func link(_ a: UUID, _ b: UUID) {
        guard a != b else { return }
        // No duplicates (either direction).
        if links.contains(where: { ($0.from == a && $0.to == b) || ($0.from == b && $0.to == a) }) { return }
        links.append(CanvasLink(from: a, to: b))
        save()
    }

    func unlink(_ id: UUID) { links.removeAll { $0.id == id }; save() }

    func note(_ id: UUID) -> CanvasNote? { notes.first { $0.id == id } }
}

// MARK: - Sticky colors (from the Koe mock)

enum CanvasColors {
    struct Sticky { let bg: Color; let ink: Color }
    static let sticky: [Sticky] = [
        Sticky(bg: Color(hex: 0xF3D9A0), ink: Color(hex: 0x5C4A24)),  // yellow
        Sticky(bg: Color(hex: 0xD6DFBA), ink: Color(hex: 0x475030)),  // green
        Sticky(bg: Color(hex: 0xF0D2CF), ink: Color(hex: 0x7A3F3A)),  // pink
        Sticky(bg: Color(hex: 0xCDD9E6), ink: Color(hex: 0x33455F)),  // blue
    ]
}

// MARK: - Pending (in-progress) link

private struct PendingLink: Equatable { let from: UUID; var point: CGPoint }

// MARK: - Backgrounds

private struct DotGrid: View {
    let palette: KoePalette
    var spacing: CGFloat = 24
    var body: some View {
        Canvas { ctx, size in
            let dot = palette.faint.opacity(0.28)
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(dot))
                    x += spacing
                }
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

/// Draws the mindmap links (and the in-progress drag line) UNDER the cards.
private struct LinksLayer: View {
    let notes: [CanvasNote]
    let links: [CanvasLink]
    let pending: PendingLink?
    let palette: KoePalette

    var body: some View {
        Canvas { ctx, _ in
            for link in links {
                guard let a = notes.first(where: { $0.id == link.from }),
                      let b = notes.first(where: { $0.id == link.to }) else { continue }
                let p1 = CGPoint(x: a.x, y: a.y), p2 = CGPoint(x: b.x, y: b.y)
                let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2 - 26)
                var path = Path()
                path.move(to: p1); path.addQuadCurve(to: p2, control: mid)
                ctx.stroke(path, with: .color(palette.dash), style: StrokeStyle(lineWidth: 1.6))
                ctx.fill(Path(ellipseIn: CGRect(x: p1.x - 3, y: p1.y - 3, width: 6, height: 6)), with: .color(palette.dash))
                ctx.fill(Path(ellipseIn: CGRect(x: p2.x - 3, y: p2.y - 3, width: 6, height: 6)), with: .color(palette.dash))
            }
            if let pending, let a = notes.first(where: { $0.id == pending.from }) {
                var path = Path()
                path.move(to: CGPoint(x: a.x, y: a.y)); path.addLine(to: pending.point)
                ctx.stroke(path, with: .color(palette.shu.opacity(0.65)),
                           style: StrokeStyle(lineWidth: 1.8, dash: [5, 4]))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Sticky note

private struct StickyNoteView: View {
    @Binding var note: CanvasNote
    let palette: KoePalette
    let onChange: () -> Void
    let onDelete: () -> Void
    let onPlay: () -> Void
    let onLinkChanged: (CGPoint) -> Void
    let onLinkEnded: (CGPoint) -> Void

    @State private var drag: CGSize = .zero
    @State private var editing = false
    @State private var hovering = false
    @State private var expanded = false
    @FocusState private var focused: Bool

    private var color: CanvasColors.Sticky { CanvasColors.sticky[note.colorIndex % CanvasColors.sticky.count] }
    private var isLong: Bool { note.text.count > 120 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Rectangle()   // tape strip
                .fill(Color.white.opacity(0.35))
                .frame(width: 52, height: 15).rotationEffect(.degrees(-4))
                .frame(maxWidth: .infinity)

            if editing {
                TextEditor(text: $note.text)
                    .font(KoeFont.hand(15.5)).foregroundStyle(color.ink)
                    .scrollContentBackground(.hidden)
                    .frame(height: 80).focused($focused)
                    .onChange(of: focused) { f in if !f { editing = false; onChange() } }
            } else {
                Text(note.text.isEmpty ? "New idea…" : note.text)
                    .font(KoeFont.hand(15.5))
                    .foregroundStyle(note.text.isEmpty ? color.ink.opacity(0.5) : color.ink)
                    .lineLimit(expanded ? nil : 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if isLong {
                    Button(expanded ? "less" : "more…") { expanded.toggle() }
                        .buttonStyle(.plain)
                        .font(KoeFont.gothic(11, .medium)).foregroundStyle(color.ink.opacity(0.6))
                }
            }

            // footer: source + play
            HStack(spacing: 7) {
                Button(action: onPlay) {
                    Image(systemName: "play.circle.fill").font(.system(size: 18))
                        .foregroundStyle(palette.shu)
                }
                .buttonStyle(.plain).help("Read this aloud")
                if !note.source.isEmpty {
                    Text(note.source).font(KoeFont.mono(9.5)).foregroundStyle(color.ink.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .padding(13)
        .frame(width: 178, alignment: .topLeading)
        .background(color.bg)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .shadow(color: Color(hex: 0x46371E, alpha: 0.40), radius: 10, y: 7)
        .overlay(alignment: .topTrailing) {
            if hovering && !editing {
                HStack(spacing: 4) {
                    Button { note.colorIndex = (note.colorIndex + 1) % CanvasColors.sticky.count; onChange() }
                        label: { Image(systemName: "paintpalette.fill").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(color.ink.opacity(0.7))
                    Button(action: onDelete) { Image(systemName: "xmark.circle.fill").font(.system(size: 13)) }
                        .buttonStyle(.plain).foregroundStyle(color.ink.opacity(0.7))
                }.padding(5)
            }
        }
        // mindmap link handle (bottom center)
        .overlay(alignment: .bottom) {
            if hovering && !editing {
                Circle().fill(palette.shu).frame(width: 13, height: 13)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .offset(y: 8)
                    .help("Drag to another card to link")
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
                            .onChanged { onLinkChanged($0.location) }
                            .onEnded { onLinkEnded($0.location) }
                    )
            }
        }
        .rotationEffect(.degrees(editing ? 0 : note.tilt))
        .position(x: note.x + drag.width, y: note.y + drag.height)
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { editing = true; focused = true }
        .gesture(
            DragGesture()
                .onChanged { if !editing { drag = $0.translation } }
                .onEnded { v in
                    guard !editing else { return }
                    note.x += v.translation.width; note.y += v.translation.height
                    drag = .zero; onChange()
                }
        )
    }
}

// MARK: - Canvas view

struct KoeCanvasView: View {
    @ObservedObject var model: ReaderHUDModel
    @ObservedObject var store = CanvasStore.shared
    @State private var pending: PendingLink?
    @State private var pan: CGSize = .zero
    @State private var panDrag: CGSize = .zero
    private var palette: KoePalette { model.palette }

    // The whiteboard is much larger than the window so notes can spread out.
    private let worldSize = CGSize(width: 2800, height: 2000)

    var body: some View {
        // GeometryReader locks the canvas to the available content area so the
        // large pannable "world" is clipped INSIDE it and its 2800pt size never
        // propagates up to push the sidebar off-screen.
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Background fills the area and captures drags on empty space to PAN.
                palette.canvas
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture()
                            .onChanged { panDrag = $0.translation }
                            .onEnded { v in
                                pan.width += v.translation.width
                                pan.height += v.translation.height
                                panDrag = .zero
                            }
                    )

                // The large "world" — pans as a whole; notes live in its coordinates.
                ZStack(alignment: .topLeading) {
                    DotGrid(palette: palette)
                    LinksLayer(notes: store.notes, links: store.links, pending: pending, palette: palette)
                    ForEach($store.notes) { $note in
                        let id = note.id
                        StickyNoteView(
                            note: $note,
                            palette: palette,
                            onChange: { store.save() },
                            onDelete: { store.remove(id) },
                            onPlay: { play(note) },
                            onLinkChanged: { pending = PendingLink(from: id, point: $0) },
                            onLinkEnded: { endLink(from: id, at: $0) }
                        )
                    }
                }
                .frame(width: worldSize.width, height: worldSize.height, alignment: .topLeading)
                .coordinateSpace(name: "canvas")
                .offset(x: pan.width + panDrag.width, y: pan.height + panDrag.height)

                toolbar
                if store.notes.isEmpty { emptyState }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { store.add("") } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus"); Text("Add note").font(KoeFont.gothic(12.5, .bold))
                }
                .foregroundStyle(.white).padding(.horizontal, 13).padding(.vertical, 8)
                .background(Capsule().fill(palette.shu))
            }
            .buttonStyle(.plain)
            if pan != .zero || panDrag != .zero {
                Button { withAnimation(.easeOut(duration: 0.25)) { pan = .zero; panDrag = .zero } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "scope"); Text("Re-center").font(KoeFont.gothic(12, .medium))
                    }
                    .foregroundStyle(palette.ink3)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                    .background(Capsule().fill(palette.s3))
                    .overlay(Capsule().stroke(palette.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            if !store.notes.isEmpty {
                Text("\(store.notes.count) note\(store.notes.count == 1 ? "" : "s") · \(store.links.count) link\(store.links.count == 1 ? "" : "s")")
                    .font(KoeFont.mono(11)).foregroundStyle(palette.mute)
            }
            Spacer()
            Text("Idea Canvas · 棚 · drag empty space to pan").font(KoeFont.mincho(13)).foregroundStyle(palette.mute)
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Your whiteboard is empty")
                .font(KoeFont.mincho(18, bold: true)).foregroundStyle(palette.faint)
            Text("Click “Add note”, or “Add to canvas” while reading.\nDouble-click to edit · drag to move · ▶ to re-listen · drag the dot to link.")
                .font(KoeFont.gothic(12.5)).foregroundStyle(palette.faint2)
                .multilineTextAlignment(.center).lineSpacing(4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    /// Re-listen: hand the card's text to the engine (opens it in the reader and
    /// reads aloud in the current voice — same path as the browser/listener).
    private func play(_ note: CanvasNote) {
        guard !note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        NotificationCenter.default.post(name: .readFlowReadExternalText, object: note.text)
    }

    /// Finish a link drag: connect to the nearest card under the drop point.
    private func endLink(from: UUID, at point: CGPoint) {
        defer { pending = nil }
        var best: (id: UUID, dist: CGFloat)?
        for n in store.notes where n.id != from {
            let d = hypot(CGFloat(n.x) - point.x, CGFloat(n.y) - point.y)
            if d < 110, best == nil || d < best!.dist { best = (n.id, d) }
        }
        if let best { store.link(from, best.id) }
    }
}
