//
//  KoeLibrary.swift
//  ReadFlow / Koe
//
//  Library (本) — the WRITE & SYNTHESIZE workspace, as a cozy study desk: a warm
//  dark room with string lights and a rainy window, a wood desk under a pool of
//  lamplight (lo-fi record + steaming mug for company), and an OPEN JOURNAL — the
//  left page holds material pulled from your Boards, the right page is where you
//  write. Multiple sections via side tabs. Everything persists.
//
//  End of the flow: Capture (intake) → Quiet Hour (listen) → Canvas (form) →
//  Boards (organize) → Library (write it up).
//

import SwiftUI
import Foundation

// MARK: - Model

struct LibrarySnippet: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var text: String
    var source: String = ""
}

struct LibrarySection: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var body: String = ""
}

// MARK: - Store (persisted)

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published var sections: [LibrarySection] = []
    @Published var pulled: [LibrarySnippet] = []
    @Published var activeID: UUID?

    private let sectionsKey = "readflow.librarySections"
    private let pulledKey = "readflow.libraryPulled"
    private let defaults = UserDefaults.standard

    private let accents: [UInt32] = [0xC0432D, 0x7C8A5B, 0xCF9B4A, 0x33455F]
    func accent(_ id: UUID) -> Color {
        let i = sections.firstIndex { $0.id == id } ?? 0
        return Color(hex: accents[i % accents.count])
    }

    init() {
        load()
        if sections.isEmpty {
            let s = LibrarySection(title: "Untitled", body: "")
            sections = [s]; activeID = s.id; save()
        } else if activeID == nil { activeID = sections.first?.id }
    }

    func load() {
        if let d = defaults.data(forKey: sectionsKey), let s = try? JSONDecoder().decode([LibrarySection].self, from: d) { sections = s }
        if let d = defaults.data(forKey: pulledKey), let p = try? JSONDecoder().decode([LibrarySnippet].self, from: d) { pulled = p }
    }
    func save() {
        if let d = try? JSONEncoder().encode(sections) { defaults.set(d, forKey: sectionsKey) }
        if let d = try? JSONEncoder().encode(pulled) { defaults.set(d, forKey: pulledKey) }
    }
    func activeIndex() -> Int? { sections.firstIndex { $0.id == activeID } }
    func addSection() { let s = LibrarySection(title: "Untitled \(sections.count + 1)", body: ""); sections.append(s); activeID = s.id; save() }
    func removeSection(_ id: UUID) {
        sections.removeAll { $0.id == id }
        if sections.isEmpty { sections = [LibrarySection(title: "Untitled", body: "")] }
        if activeID == id { activeID = sections.first?.id }
        save()
    }
    func pullBoard(_ board: Board) {
        for item in board.items where !pulled.contains(where: { $0.text == item.text }) {
            pulled.insert(LibrarySnippet(text: item.text, source: item.source.isEmpty ? board.name : item.source), at: 0)
        }
        save()
    }
    func removePulled(_ id: UUID) { pulled.removeAll { $0.id == id }; save() }
    func clearPulled() { pulled = []; save() }
}

// MARK: - Library view (the study desk)

struct KoeLibraryView: View {
    @ObservedObject var model: ReaderHUDModel
    @ObservedObject var store = LibraryStore.shared
    @ObservedObject private var boards = BoardStore.shared

    var body: some View {
        GeometryReader { geo in
            ZStack {
                room
                warmGlow
                StringLights().frame(height: 70).frame(maxHeight: .infinity, alignment: .top)
                rainyWindow.position(x: geo.size.width / 2, y: 150)
                deskSurface
                lampPool
                bookshelf
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 18).padding(.top, geo.size.height * 0.26)
                VinylWidget().position(x: 96, y: geo.size.height - 78)
                SteamingMug().position(x: geo.size.width - 96, y: geo.size.height - 120)
                journal.position(x: geo.size.width / 2 - 18, y: geo.size.height - 252)
                ambientPanel.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(20)
                vignette
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    // MARK: Room / desk / light

    private var room: some View {
        LinearGradient(colors: [Color(hex: 0x251D27), Color(hex: 0x2B2230), Color(hex: 0x241D22), Color(hex: 0x1B1611)],
                       startPoint: .top, endPoint: .bottom)
    }
    private var warmGlow: some View {
        RadialGradient(colors: [Color(hex: 0xE8AA5A, alpha: 0.20), .clear], center: .init(x: 0.7, y: 0.02), startRadius: 0, endRadius: 540)
            .allowsHitTesting(false)
    }
    private var deskSurface: some View {
        VStack { Spacer()
            LinearGradient(colors: [Color(hex: 0x3A2C1F), Color(hex: 0x4B3825), Color(hex: 0x3D2D1F)], startPoint: .top, endPoint: .bottom)
                .frame(height: 300)
                .overlay(Rectangle().fill(.black.opacity(0.18)).blur(radius: 12).frame(height: 24), alignment: .top)
        }.allowsHitTesting(false)
    }
    private var lampPool: some View {
        RadialGradient(colors: [Color(hex: 0xF6C678, alpha: 0.28), .clear], center: .center, startRadius: 0, endRadius: 360)
            .frame(width: 780, height: 460).offset(y: 30).allowsHitTesting(false)
    }
    private var vignette: some View {
        RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center, startRadius: 240, endRadius: 640)
            .allowsHitTesting(false)
    }

    // MARK: Rainy window

    private var rainyWindow: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x121828), Color(hex: 0x1A2236), Color(hex: 0x212A3E)], startPoint: .top, endPoint: .bottom)
            // bokeh
            bokeh(0xFFD9A0, 30, x: -150, y: -55); bokeh(0xA9C6EF, 18, x: -74, y: -12)
            bokeh(0xFFCF86, 22, x: 70, y: -50); bokeh(0x9FB9E8, 16, x: 132, y: 8); bokeh(0xFFD79A, 20, x: -16, y: 42)
            RainView()
            // mullions
            Rectangle().fill(Color(hex: 0x2C2017)).frame(width: 8)
            Rectangle().fill(Color(hex: 0x2C2017)).frame(height: 8)
            LinearGradient(colors: [.white.opacity(0.07), .clear], startPoint: .topLeading, endPoint: .center)
        }
        .frame(width: 452, height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(hex: 0x2C2017), lineWidth: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(hex: 0x19120C), lineWidth: 2).padding(-9))
        .shadow(color: .black.opacity(0.65), radius: 22, y: 18)
        .allowsHitTesting(false)
    }
    private func bokeh(_ hex: UInt32, _ d: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        RadialGradient(colors: [Color(hex: hex), .clear], center: .center, startRadius: 0, endRadius: d * 0.7)
            .frame(width: d * 2, height: d * 2).offset(x: x, y: y)
    }

    // MARK: Ambient pills

    private var ambientPanel: some View {
        HStack(spacing: 9) {
            pill("☔", "Rain"); pill("♪", "Lo-fi")
        }
        .padding(7)
        .background(Capsule().fill(Color(hex: 0x1A1410, alpha: 0.62)))
        .overlay(Capsule().stroke(Color(hex: 0x7C6848, alpha: 0.38), lineWidth: 1))
    }
    private func pill(_ glyph: String, _ label: String) -> some View {
        HStack(spacing: 5) { Text(glyph).font(.system(size: 12)); Text(label).font(KoeFont.gothic(11, .medium)) }
            .foregroundStyle(Color(hex: 0xE8DCC4))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(.white.opacity(0.05)))
    }

    // MARK: The open journal

    private var journal: some View {
        HStack(spacing: 0) {
            leftPage
            Rectangle().fill(LinearGradient(colors: [Color(hex: 0x503C1E, alpha: 0.45), Color(hex: 0x503C1E, alpha: 0.12)], startPoint: .leading, endPoint: .trailing)).frame(width: 4)
            rightPage
        }
        .frame(height: 470)
        .shadow(color: .black.opacity(0.6), radius: 40, y: 32)
    }

    // LEFT — pulled material
    private var leftPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("聴").font(KoeFont.mincho(17)).foregroundStyle(Color(hex: 0xC0432D))
                Text("FROM YOUR LISTENING").font(KoeFont.gothic(10, .bold)).tracking(1.5).foregroundStyle(Color(hex: 0x9A7D4F))
            }
            if store.pulled.isEmpty {
                Text("Bring quotes you saved into this page, then write from them →")
                    .font(KoeFont.hand(14)).foregroundStyle(Color(hex: 0xA9966F)).lineSpacing(5)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(store.pulled) { p in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("“\(p.text)”").font(KoeFont.mincho(13.5)).italic().foregroundStyle(Color(hex: 0x574A35)).lineSpacing(3)
                                HStack(spacing: 6) {
                                    Button { listen(p.text) } label: { Image(systemName: "play.circle.fill").font(.system(size: 13)).foregroundStyle(Color(hex: 0xC0432D)) }.buttonStyle(.plain)
                                    Text(p.source).font(KoeFont.mono(10)).foregroundStyle(Color(hex: 0xA9966F)).lineLimit(1)
                                    Spacer()
                                    Button { store.removePulled(p.id) } label: { Image(systemName: "xmark").font(.system(size: 8)).foregroundStyle(Color(hex: 0xA9966F)) }.buttonStyle(.plain)
                                }
                            }
                            .padding(.leading, 11)
                            .overlay(Rectangle().fill(Color(hex: 0xD8B27A)).frame(width: 2), alignment: .leading)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Menu {
                ForEach(boards.boards) { b in Button("\(b.name) (\(b.items.count))") { store.pullBoard(b) }.disabled(b.items.isEmpty) }
                if !store.pulled.isEmpty { Divider(); Button("Clear all", role: .destructive) { store.clearPulled() } }
            } label: {
                Text("＋ Pull from boards ▾").font(KoeFont.gothic(12, .bold)).foregroundStyle(Color(hex: 0xF3EAD4))
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: 0x2C2017)))
            }
            .menuStyle(.borderlessButton)
        }
        .padding(24)
        .frame(width: 312)
        .background(LinearGradient(colors: [Color(hex: 0xF3EAD4), Color(hex: 0xECE0C4)], startPoint: .top, endPoint: .bottom))
        .clipShape(.rect(topLeadingRadius: 8, bottomLeadingRadius: 8))
    }

    // RIGHT — writing
    private var rightPage: some View {
        Group {
            if let idx = store.activeIndex() {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 9) {
                        Circle().fill(store.accent(store.sections[idx].id)).frame(width: 10, height: 10)
                        TextField("Untitled", text: $store.sections[idx].title)
                            .textFieldStyle(.plain).font(KoeFont.mincho(17, bold: true)).foregroundStyle(Color(hex: 0x3A3328))
                            .onSubmit { store.save() }
                        Button { listen(store.sections[idx].body) } label: { Image(systemName: "play.circle.fill").font(.system(size: 16)).foregroundStyle(Color(hex: 0xC0432D)) }
                            .buttonStyle(.plain).disabled(store.sections[idx].body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Text("書").font(KoeFont.mincho(13)).foregroundStyle(Color(hex: 0xBCAA86))
                    }
                    .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 8)
                    Rectangle().fill(Color(hex: 0x786428, alpha: 0.2)).frame(height: 1).padding(.horizontal, 22)

                    ZStack(alignment: .topLeading) {
                        RuledLines()
                        TextEditor(text: $store.sections[idx].body)
                            .font(KoeFont.mincho(16)).foregroundStyle(Color(hex: 0x3A3328))
                            .scrollContentBackground(.hidden).lineSpacing(14)
                        if store.sections[idx].body.isEmpty {
                            Text("Now that you've listened… write what stayed with you.")
                                .font(KoeFont.mincho(16)).foregroundStyle(Color(hex: 0xBCAA86)).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                    .padding(.horizontal, 18).padding(.top, 10)

                    HStack(spacing: 8) {
                        Circle().fill(Color(hex: 0x7C8A5B)).frame(width: 6, height: 6)
                        Text("auto-saved · \(wordCount(store.sections[idx].body)) words").font(KoeFont.mono(10)).foregroundStyle(Color(hex: 0xBCAA86))
                        Spacer()
                        if store.sections.count > 1 {
                            Button { store.removeSection(store.sections[idx].id) } label: { Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Color(hex: 0xBCAA86)) }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24).padding(.vertical, 10)
                }
                .onChange(of: store.sections) { _ in store.save() }
            }
        }
        .frame(width: 312)
        .background(Color(hex: 0xFBF4E4))
        .clipShape(.rect(bottomTrailingRadius: 8, topTrailingRadius: 8))
    }

    // BOOKSHELF — your notebooks, on a shelf on the wall. Pick one to open it on
    // the desk; "+" adds a new notebook.
    private var bookshelf: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("棚  NOTEBOOKS").font(KoeFont.gothic(9, .bold)).tracking(1.5)
                .foregroundStyle(Color(hex: 0xB89A66)).padding(.leading, 4)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(store.sections) { bookSpine($0) }
                addBook
            }
            // shelf board
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(hex: 0x4B3825), Color(hex: 0x2F2316)], startPoint: .top, endPoint: .bottom)
                Rectangle().fill(.white.opacity(0.06)).frame(height: 2)
            }
            .frame(height: 13)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .shadow(color: .black.opacity(0.55), radius: 8, y: 5)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color(hex: 0x140F0B, alpha: 0.40)))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color(hex: 0x7C6848, alpha: 0.25), lineWidth: 1))
        .fixedSize()
    }

    private func bookSpine(_ nb: LibrarySection) -> some View {
        let active = store.activeID == nb.id
        let accent = store.accent(nb.id)
        return Button { store.activeID = nb.id } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [accent.opacity(0.55), accent, accent.opacity(0.78)], startPoint: .leading, endPoint: .trailing))
                Rectangle().fill(.white.opacity(0.20)).frame(width: 1.5).offset(x: -6)   // spine sheen
                Rectangle().fill(.black.opacity(0.22)).frame(height: 8).offset(y: -28)   // top band
                Rectangle().fill(.black.opacity(0.22)).frame(height: 8).offset(y: 28)    // bottom band
                Text(nb.title.isEmpty ? "Untitled" : nb.title)
                    .font(KoeFont.gothic(10.5, .bold)).foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1).fixedSize()
                    .rotationEffect(.degrees(-90))
                    .frame(width: 18, height: 74)
            }
            .frame(width: 22, height: active ? 98 : 86)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black.opacity(0.28), lineWidth: 0.5))
            .offset(y: active ? -7 : 0)
            .shadow(color: .black.opacity(0.45), radius: active ? 7 : 2, y: 3)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: active)
        .help(nb.title.isEmpty ? "Untitled notebook" : nb.title)
    }

    private var addBook: some View {
        Button { store.addSection() } label: {
            Text("＋").font(KoeFont.gothic(13, .bold)).foregroundStyle(Color(hex: 0xC4AD7F))
                .frame(width: 22, height: 86)
                .background(RoundedRectangle(cornerRadius: 2).fill(Color(hex: 0x2C2017, alpha: 0.5)))
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color(hex: 0xC4AD7F), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
        }
        .buttonStyle(.plain).help("New notebook")
    }

    private func wordCount(_ s: String) -> Int { s.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count }
    private func listen(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        NotificationCenter.default.post(name: .readFlowReadExternalText, object: text)
    }
}

// MARK: - Atmospheric pieces

/// Ruled writing lines behind the editor.
private struct RuledLines: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 30
            while y < size.height {
                var p = Path(); p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: size.width, y: y))
                ctx.stroke(p, with: .color(Color(hex: 0x786428, alpha: 0.16)), lineWidth: 1)
                y += 30
            }
        }.allowsHitTesting(false)
    }
}

/// Animated rain streaks.
private struct RainView: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { c, size in
                let n = 60
                let span = Double(size.height) + 40
                for i in 0..<n {
                    let fi = Double(i)
                    let seed = (fi * 12.9898).truncatingRemainder(dividingBy: 1.0)      // 0..1
                    let x = CGFloat(seed) * size.width
                    let speed = 200.0 + (fi * 53).truncatingRemainder(dividingBy: 140)
                    let y = CGFloat((t * speed + fi * 37).truncatingRemainder(dividingBy: span)) - 20
                    var p = Path(); p.move(to: .init(x: x, y: y)); p.addLine(to: .init(x: x - 6, y: y + 16))
                    c.stroke(p, with: .color(Color(hex: 0xB2CAEC, alpha: 0.20)), lineWidth: 1)
                }
            }
        }.allowsHitTesting(false)
    }
}

/// Spinning lo-fi record widget.
private struct VinylWidget: View {
    @State private var spin = false
    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(Color(hex: 0x1A130D))
                    .overlay(Circle().stroke(Color(hex: 0x221912), lineWidth: 2).padding(6))
                    .overlay(Circle().stroke(Color(hex: 0x221912), lineWidth: 2).padding(12))
                Circle().fill(Color(hex: 0xC0432D)).frame(width: 16, height: 16)
                Circle().fill(Color(hex: 0x15100C)).frame(width: 4, height: 4)
            }
            .frame(width: 58, height: 58)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 4).repeatForever(autoreverses: false), value: spin)
            VStack(alignment: .leading, spacing: 2) {
                Text("midnight study").font(KoeFont.gothic(11.5, .medium)).foregroundStyle(Color(hex: 0xE8DCC4))
                Text("lo-fi · ch.1").font(KoeFont.mono(10)).foregroundStyle(Color(hex: 0x9A8F7B))
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<4, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1).fill(Color(hex: [0x7C8A5B, 0x9FB083, 0x7C8A5B, 0xCF9B4A][i]))
                            .frame(width: 3, height: [9, 14, 7, 11][i])
                    }
                }.frame(height: 14).padding(.top, 3)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 13).fill(Color(hex: 0x1A1410, alpha: 0.72)))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color(hex: 0x7C6848, alpha: 0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 16, y: 10)
        .onAppear { spin = true }
    }
}

/// Steaming mug.
private struct SteamingMug: View {
    @State private var rise = false
    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule().fill(Color(hex: 0xE8DCC4, alpha: 0.4))
                        .frame(width: 5, height: 22)
                        .offset(y: rise ? -26 : -10)
                        .opacity(rise ? 0 : 0.6)
                        .animation(.easeOut(duration: 3.2).repeatForever(autoreverses: false).delay(Double(i) * 0.9), value: rise)
                }
            }
            .offset(y: -34)
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(LinearGradient(colors: [Color(hex: 0xB9572F), Color(hex: 0x9A3F22)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 50, height: 42)
                RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x3B2218)).frame(width: 36, height: 8).offset(y: -15)
            }
            .overlay(Circle().stroke(Color(hex: 0x9A3F22), lineWidth: 5).frame(width: 18, height: 18).offset(x: 30, y: -4))
        }
        .shadow(color: .black.opacity(0.5), radius: 10, y: 8)
        .onAppear { rise = true }
    }
}

/// String lights across the top.
private struct StringLights: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                Path { p in
                    p.move(to: .init(x: -10, y: 6))
                    p.addQuadCurve(to: .init(x: w * 0.33, y: 16), control: .init(x: w * 0.15, y: 50))
                    p.addQuadCurve(to: .init(x: w * 0.66, y: 18), control: .init(x: w * 0.5, y: 8))
                    p.addQuadCurve(to: .init(x: w + 10, y: 8), control: .init(x: w * 0.85, y: 34))
                }.stroke(Color(hex: 0x786448, alpha: 0.45), lineWidth: 1.4)
                ForEach(0..<5, id: \.self) { i in
                    let xs: [CGFloat] = [0.15, 0.33, 0.5, 0.66, 0.83]
                    let ys: [CGFloat] = [40, 36, 42, 34, 40]
                    Circle().fill(RadialGradient(colors: [Color(hex: i % 2 == 0 ? 0xFFCF86 : 0xFFD79A), .clear], center: .center, startRadius: 0, endRadius: 9))
                        .frame(width: 18, height: 18).position(x: w * xs[i], y: ys[i])
                }
            }
        }.allowsHitTesting(false)
    }
}
