//
//  WordFlowView.swift  →  Koe UI
//  ReadFlow / Koe
//
//  The SwiftUI surface for Koe: a sidebar, the "Capture" and "The Quiet Hour"
//  reading views, and the persistent player bar with the moving per-word
//  vermilion highlight. Per-word backgrounds require a custom `Layout`
//  (`WrappingHStack`) — `Text`+`AttributedString` cannot carry them.
//
//  `ReaderHUDModel` keeps its name and the surface the manager/window push into
//  (words / currentIndex / state / rate / typography + the transport callbacks);
//  it is extended with Koe presentation state (appearance, view, source label,
//  elapsed/total). `KoeRootView` is the root the window hosts.
//

import SwiftUI
import AppKit
import AVFoundation

// MARK: - View Model

/// The observable model `ReaderHUDWindow` owns and the manager pushes
/// words / highlight / state into. The SAME instance drives the SwiftUI tree.
@MainActor
final class ReaderHUDModel: ObservableObject {
    // --- Manager-facing surface (unchanged contract) ---
    @Published var words: [Word] = []
    @Published var currentIndex: Int?
    @Published var state: TTSPlaybackState = .idle

    // Typography — mirrored from Settings by ReaderHUDWindow.
    @Published var fontName: String = ""
    @Published var fontSize: Double = 22
    @Published var lineHeight: Double = 1.45
    @Published var letterSpacing: Double = 0.4

    // Live transport value so the speed control tracks without round-tripping.
    @Published var rate: Double = 1.0

    // --- Koe presentation state ---
    @Published var appearance: KoeAppearance = .light
    @Published var koeView: KoeView = .capture   // first launch shows onboarding
    @Published var sourceLabel: String = "selection"
    @Published var title: String = "Reading"
    @Published var elapsed: TimeInterval = 0
    @Published var total: TimeInterval = 0
    @Published var highlightOn: Bool = true
    @Published var engineLabel: String = "System Voice"
    @Published var voiceGlyph: String = "声"

    // --- Callbacks bridged out to the manager by ReaderHUDWindow ---
    var onTogglePlayPause: (() -> Void)?
    var onRateChange: ((Double) -> Void)?
    var onRestart: (() -> Void)?
    var onStop: (() -> Void)?
    var onClose: (() -> Void)?

    init() {}

    var palette: KoePalette { .forAppearance(appearance) }
    var isPlaying: Bool { state == .speaking || state == .preparing }

    /// Extra leading per line to approximate the requested line-height multiplier.
    var resolvedLineSpacing: CGFloat {
        max(2, CGFloat(fontSize) * CGFloat(max(0, lineHeight - 1.0)))
    }
}

// MARK: - Wrapping Layout (unchanged, proven)

/// Lays subviews left-to-right, wrapping to a new line on overflow. This is what
/// makes per-word background highlights possible: each word is its own subview.
struct WrappingHStack: Layout {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(maxWidth: maxWidth, subviews: subviews)
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for (i, row) in rows.enumerated() {
            totalHeight += row.height
            if i < rows.count - 1 { totalHeight += verticalSpacing }
            totalWidth = max(totalWidth, row.width)
        }
        let resolvedWidth = proposal.width ?? totalWidth
        return CGSize(width: resolvedWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let size = item.size
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct RowItem { let index: Int; let size: CGSize }
    private struct Row { var items: [RowItem] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func computeRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let projectedWidth = current.items.isEmpty ? size.width : current.width + horizontalSpacing + size.width
            if !current.items.isEmpty, projectedWidth > maxWidth {
                rows.append(current); current = Row()
            }
            if current.items.isEmpty { current.width = size.width }
            else { current.width += horizontalSpacing + size.width }
            current.height = max(current.height, size.height)
            current.items.append(RowItem(index: index, size: size))
        }
        if !current.items.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Word chip (Koe styling)

/// One word. The current word gets the vermilion highlight; already-read words
/// use `ink2`, upcoming words `faint2` — exactly the mock's read-position model.
private struct KoeWordChip: View {
    let text: String
    let position: Position
    let font: Font
    let letterSpacing: CGFloat
    let palette: KoePalette

    enum Position { case past, current, upcoming }

    var body: some View {
        Text(text)
            .font(font)
            .tracking(letterSpacing)
            .fontWeight(position == .current ? .semibold : .regular)
            .foregroundStyle(color)
            .padding(.horizontal, position == .current ? 4 : 0)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(position == .current ? palette.highlightFill : Color.clear)
            )
            .animation(.easeOut(duration: 0.09), value: position == .current)
    }

    private var color: Color {
        switch position {
        case .current:  return palette.ink
        case .past:     return palette.ink2
        case .upcoming: return palette.faint2
        }
    }
}

// MARK: - Word column (shared by Capture + Read)

/// The wrapping, auto-scrolling column of highlighted words.
private struct KoeWordColumn: View {
    @ObservedObject var model: ReaderHUDModel
    var maxWidth: CGFloat = 600

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                WrappingHStack(horizontalSpacing: 6, verticalSpacing: model.resolvedLineSpacing) {
                    ForEach(model.words, id: \.index) { word in
                        KoeWordChip(
                            text: word.text,
                            position: position(for: word.index),
                            font: KoeFont.mincho(CGFloat(model.fontSize)),
                            letterSpacing: CGFloat(model.letterSpacing),
                            palette: model.palette
                        )
                        .id(word.index)
                    }
                }
                .frame(maxWidth: maxWidth, alignment: .leading)
                .padding(.vertical, 4)
            }
            .onChange(of: model.currentIndex) { newIndex in
                guard let newIndex else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private func position(for index: Int) -> KoeWordChip.Position {
        guard let cur = model.currentIndex else { return .upcoming }
        if index == cur { return .current }
        return index < cur ? .past : .upcoming
    }
}

// MARK: - Lined-paper background (The Quiet Hour)

private struct LinedPaper: View {
    let palette: KoePalette
    var spacing: CGFloat = 34
    var topInset: CGFloat = 92

    var body: some View {
        Canvas { ctx, size in
            var y = topInset
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(path, with: .color(palette.noteBlue.opacity(0.08)), lineWidth: 1)
                y += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - The Quiet Hour (reading view)

private struct KoeReadingView: View {
    @ObservedObject var model: ReaderHUDModel
    var palette: KoePalette { model.palette }

    private func saveToBoard(_ id: UUID) {
        let text = model.words.map(\.text).joined(separator: " ")
        guard !text.isEmpty else { return }
        BoardStore.shared.addItem(BoardItem(text: text, source: model.title, kind: "read"), to: id)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            palette.s1
            LinedPaper(palette: palette)
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("READING ALOUD · FROM \(model.sourceLabel.uppercased())")
                            .font(KoeFont.gothic(11, .medium))
                            .tracking(2)
                            .foregroundStyle(palette.mute)
                        Text(model.title)
                            .font(KoeFont.mincho(29, bold: true))
                            .foregroundStyle(palette.ink)
                    }
                    Spacer()
                    Button {
                        let text = model.words.map(\.text).joined(separator: " ")
                        if !text.isEmpty {
                            CanvasStore.shared.add(text, source: model.title)
                            model.koeView = .canvas
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "plus.square.on.square").font(.system(size: 12))
                            Text("Add to canvas").font(KoeFont.gothic(12.5, .medium))
                        }
                        .foregroundStyle(palette.ink3)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(Capsule().fill(palette.s3))
                        .overlay(Capsule().stroke(palette.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.words.isEmpty)

                    Menu {
                        ForEach(BoardStore.shared.boards) { b in
                            Button(b.name) { saveToBoard(b.id) }
                        }
                        Divider()
                        Button("New board…") {
                            let id = BoardStore.shared.addBoard()
                            saveToBoard(id)
                            model.koeView = .boards
                        }
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "tray.and.arrow.down").font(.system(size: 12))
                            Text("Save to board").font(KoeFont.gothic(12.5, .bold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(Capsule().fill(palette.shu))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .disabled(model.words.isEmpty)
                }
                KoeWordColumn(model: model, maxWidth: 600)
                    .foregroundStyle(palette.soft)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 34)
        }
    }
}

// MARK: - Capture (paper page + Listen chip)

private struct KoeCaptureView: View {
    @ObservedObject var model: ReaderHUDModel
    private var palette: KoePalette { model.palette }   // app chrome (dark/light)
    private let page = KoePalette.light                  // the document is ALWAYS cream paper

    var body: some View {
        ZStack {
            palette.readerBg
            VStack(spacing: 0) {
                docChrome
                ScrollViewReader { proxy in
                    ScrollView {
                        pageView
                            .padding(.vertical, 34)
                            .frame(maxWidth: .infinity)
                    }
                    .onChange(of: model.currentIndex) { idx in
                        guard let idx else { return }
                        withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(idx, anchor: .center) }
                    }
                }
            }
        }
    }

    // Faux PDF window chrome
    private var docChrome: some View {
        HStack(spacing: 7) {
            Circle().fill(Color(hex: 0xC8836F)).frame(width: 11, height: 11)
            Circle().fill(Color(hex: 0xD8BD7E)).frame(width: 11, height: 11)
            Circle().fill(Color(hex: 0x9FB083)).frame(width: 11, height: 11)
            Text(model.sourceLabel).font(KoeFont.mono(12)).foregroundStyle(palette.ink3).padding(.leading, 6)
            Spacer()
            Text(model.words.isEmpty ? "no selection" : "\(model.words.count) words")
                .font(KoeFont.mono(12)).foregroundStyle(palette.mute)
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .background(palette.readerBar)
        .overlay(Rectangle().fill(palette.line).frame(height: 1), alignment: .bottom)
    }

    // The cream document page (always light)
    private var pageView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.words.isEmpty {
                Text("Select text in any app and press ⌥R (or use the browser extension), and it lands here for Koe to read aloud — with the words highlighting as it goes.")
                    .font(KoeFont.mincho(16)).foregroundStyle(page.faint).lineSpacing(8)
            } else {
                Text(model.title).font(KoeFont.mincho(25, bold: true)).foregroundStyle(page.ink)
                    .padding(.bottom, 6)
                Text("\(model.sourceLabel) · captured").font(KoeFont.mono(11)).foregroundStyle(page.mute)
                    .padding(.bottom, 24)
                selectionBox
                captureChip.padding(.top, 16)
            }
        }
        .padding(.horizontal, 58).padding(.vertical, 54)
        .frame(width: 620, alignment: .leading)
        .background(page.s0)
        .overlay(Rectangle().stroke(page.line, lineWidth: 1))
        .shadow(color: Color(hex: 0x281E0F, alpha: 0.5), radius: 30, y: 20)
    }

    // The highlighted selection (rose-tinted box; current word highlights live)
    private var selectionBox: some View {
        WrappingHStack(horizontalSpacing: 6, verticalSpacing: 10) {
            ForEach(model.words, id: \.index) { w in
                KoeWordChip(text: w.text,
                            position: position(w.index),
                            font: KoeFont.mincho(CGFloat(model.fontSize)),
                            letterSpacing: CGFloat(model.letterSpacing),
                            palette: page)
                    .id(w.index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(model.highlightOn ? page.selectionFill : .clear))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .stroke(model.highlightOn ? Color(hex: 0xC0432D, alpha: 0.30) : .clear, lineWidth: 1))
    }

    // Listen · Highlight · Add to canvas · Save to board
    private var captureChip: some View {
        HStack(spacing: 9) {
            Button { model.onTogglePlayPause?() } label: {
                HStack(spacing: 8) {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 12))
                    Text("Listen").font(KoeFont.gothic(12.5, .bold))
                }
                .foregroundStyle(.white).padding(.horizontal, 13).padding(.vertical, 8)
                .background(Capsule().fill(page.shu))
            }
            .buttonStyle(.plain)

            Rectangle().fill(page.line).frame(width: 1, height: 22)

            Button { model.highlightOn.toggle() } label: {
                HStack(spacing: 7) {
                    RoundedRectangle(cornerRadius: 3).fill(page.shu).frame(width: 13, height: 13)
                    Text("Highlight").font(KoeFont.gothic(12, .medium))
                }
                .foregroundStyle(model.highlightOn ? Color(hex: 0xA3361F) : page.soft)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(model.highlightOn ? page.tintShu : page.s3))
                .overlay(Capsule().stroke(model.highlightOn ? Color(hex: 0xD98C7A) : page.line, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Button { addToCanvas() } label: {
                HStack(spacing: 7) { Text("⌗"); Text("Add to canvas").font(KoeFont.gothic(12, .medium)) }
                    .foregroundStyle(page.ink3).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(page.s3)).overlay(Capsule().stroke(page.line, lineWidth: 1))
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(BoardStore.shared.boards) { b in Button(b.name) { saveToBoard(b.id) } }
                Divider()
                Button("New board…") { let id = BoardStore.shared.addBoard(); saveToBoard(id); model.koeView = .boards }
            } label: {
                HStack(spacing: 7) { Text("▤"); Text("Save to board").font(KoeFont.gothic(12, .medium)); Image(systemName: "chevron.down").font(.system(size: 8)) }
                    .foregroundStyle(page.ink3).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(page.s3)).overlay(Capsule().stroke(page.line, lineWidth: 1))
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(7)
        .background(Capsule().fill(page.s1))
        .overlay(Capsule().stroke(page.line, lineWidth: 1))
        .shadow(color: Color(hex: 0x281E0F, alpha: 0.30), radius: 16, y: 10)
    }

    private func position(_ index: Int) -> KoeWordChip.Position {
        guard let cur = model.currentIndex else { return .upcoming }
        if index == cur { return .current }
        return index < cur ? .past : .upcoming
    }

    private func addToCanvas() {
        let text = model.words.map(\.text).joined(separator: " ")
        guard !text.isEmpty else { return }
        CanvasStore.shared.add(text, source: model.title)
        model.koeView = .canvas
    }
    private func saveToBoard(_ id: UUID) {
        let text = model.words.map(\.text).joined(separator: " ")
        guard !text.isEmpty else { return }
        BoardStore.shared.addItem(BoardItem(text: text, source: model.title, kind: "read"), to: id)
    }
}

// MARK: - Sidebar

private struct KoeSidebar: View {
    @ObservedObject var model: ReaderHUDModel
    var palette: KoePalette { model.palette }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Koe").font(KoeFont.mincho(22, bold: true)).foregroundStyle(palette.ink)
                Text("声").font(KoeFont.mincho(15)).foregroundStyle(palette.shu)
            }
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 16)

            VStack(spacing: 3) {
                navButton(.capture, "Capture", "doc.text")
                navButton(.read, "The Quiet Hour", "book")
                navButton(.canvas, "Idea Canvas", "square.grid.2x2")
                navButton(.boards, "Boards", "tray.full")
                navButton(.library, "Library", "books.vertical")
            }

            Spacer()

            Button { withAnimation(.easeInOut(duration: 0.2)) { model.appearance = model.appearance.toggled } } label: {
                HStack(spacing: 9) {
                    Image(systemName: model.appearance == .dark ? "sun.max" : "moon").font(.system(size: 12))
                    Text(model.appearance == .dark ? "Light mode" : "Dark mode").font(KoeFont.gothic(12, .medium))
                }
                .foregroundStyle(palette.soft)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(palette.s1))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(palette.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.bottom, 10)

            // "Now reading" card
            VStack(alignment: .leading, spacing: 9) {
                Text("NOW READING").font(KoeFont.gothic(9.5, .medium)).tracking(2).foregroundStyle(palette.mute)
                HStack(spacing: 8) {
                    BlinkDot(color: palette.shu, active: model.isPlaying)
                    Text(model.words.isEmpty ? "Nothing yet" : model.title)
                        .font(KoeFont.mincho(13)).foregroundStyle(palette.ink).lineLimit(1)
                }
                Text("\(model.sourceLabel) · \(model.engineLabel)")
                    .font(KoeFont.mono(11)).foregroundStyle(palette.mute).lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11).fill(palette.s1))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(palette.line, lineWidth: 1))
        }
        .padding(.horizontal, 14).padding(.vertical, 18)
        .frame(width: 216)
        .background(palette.s2)
        .overlay(Rectangle().fill(palette.line).frame(width: 1), alignment: .trailing)
    }

    private func navButton(_ view: KoeView, _ label: String, _ icon: String) -> some View {
        let active = model.koeView == view
        return Button { model.koeView = view } label: {
            HStack(spacing: 11) {
                Image(systemName: icon).font(.system(size: 13)).frame(width: 18)
                Text(label).font(KoeFont.gothic(13.5, active ? .bold : .medium))
                Spacer()
            }
            .foregroundStyle(active ? palette.ink : palette.soft)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9).fill(active ? palette.navAct : Color.clear)
                    .overlay(active ? Rectangle().fill(palette.shu).frame(width: 3).cornerRadius(2) : nil,
                             alignment: .leading)
            )
        }
        .buttonStyle(.plain)
    }

    private func soonRow(_ label: String, _ icon: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon).font(.system(size: 13)).frame(width: 18)
            Text(label).font(KoeFont.gothic(13.5, .medium))
            Spacer()
            Text("soon").font(KoeFont.gothic(9, .medium)).foregroundStyle(palette.mute)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(palette.s1))
        }
        .foregroundStyle(palette.faint2)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .opacity(0.7)
    }
}

private struct BlinkDot: View {
    let color: Color
    let active: Bool
    @State private var dim = false
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .opacity(active ? (dim ? 0.35 : 1.0) : 0.5)
            .animation(active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: dim)
            .onAppear { dim = active }
            .onChange(of: active) { dim = $0 }
    }
}

// MARK: - Waveform

private struct Waveform: View {
    let palette: KoePalette
    let active: Bool

    var body: some View {
        GeometryReader { geo in
            let count = max(24, Int(geo.size.width / 7))
            if active {
                TimelineView(.animation) { ctx in
                    let t = ctx.date.timeIntervalSinceReferenceDate
                    bars(count: count, height: geo.size.height) { i in
                        let phase = t * 3.2 + Double(i) * 0.5
                        return 0.28 + 0.72 * (0.5 + 0.5 * sin(phase))
                    }
                }
            } else {
                bars(count: count, height: geo.size.height) { i in
                    0.18 + Double((i * 37) % 50) / 140.0
                }
            }
        }
        .frame(height: 30)
    }

    private func bars(count: Int, height: CGFloat, scale: (Int) -> Double) -> some View {
        // Resolve heights eagerly so the per-bar `scale` closure isn't captured
        // by the (escaping) ForEach content.
        let heights = (0..<count).map { max(3, height * CGFloat(scale($0))) }
        return HStack(alignment: .center, spacing: 3) {
            ForEach(0..<count, id: \.self) { i in
                let lead = i < 5 && active
                RoundedRectangle(cornerRadius: 2)
                    .fill(lead ? palette.shu : (i < 5 ? Color(hex: 0xD98C7A) : palette.line))
                    .frame(width: 3.5, height: heights[i])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Player bar

private struct VoiceOption: Identifiable { let id: String; let label: String }

private struct KoePlayerBar: View {
    @ObservedObject var model: ReaderHUDModel
    @ObservedObject private var settings = Settings.shared
    var palette: KoePalette { model.palette }

    private let rates: [Double] = [0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    // MARK: Engine / voice switching

    private var engineBinding: Binding<EngineKind> {
        Binding(get: { settings.engineKind }, set: { settings.engineKind = $0 })
    }
    private var voiceBinding: Binding<String> {
        switch settings.engineKind {
        case .system: return Binding(get: { settings.systemVoiceID }, set: { settings.systemVoiceID = $0 })
        case .kokoro: return Binding(get: { settings.kokoroVoice }, set: { settings.kokoroVoice = $0 })
        case .azure:  return Binding(get: { settings.azureVoice }, set: { settings.azureVoice = $0 })
        }
    }
    private var voiceOptions: [VoiceOption] {
        switch settings.engineKind {
        case .system:
            let voices = AVSpeechSynthesisVoice.speechVoices()
                .filter { $0.language.hasPrefix("en") }
                .sorted { $0.name < $1.name }
            return [VoiceOption(id: "", label: "Default")]
                + voices.map { VoiceOption(id: $0.identifier, label: $0.name) }
        case .kokoro:
            return [
                VoiceOption(id: "af_heart", label: "Heart — warm (F)"),
                VoiceOption(id: "af_bella", label: "Bella (F)"),
                VoiceOption(id: "af_nova", label: "Nova (F)"),
                VoiceOption(id: "af_sky", label: "Sky (F)"),
                VoiceOption(id: "af_sarah", label: "Sarah (F)"),
                VoiceOption(id: "am_adam", label: "Adam (M)"),
                VoiceOption(id: "am_michael", label: "Michael (M)"),
                VoiceOption(id: "bf_emma", label: "Emma — UK (F)"),
                VoiceOption(id: "bm_george", label: "George — UK (M)"),
            ]
        case .azure:
            return [
                VoiceOption(id: "en-US-JennyNeural", label: "Jenny (F)"),
                VoiceOption(id: "en-US-AriaNeural", label: "Aria (F)"),
                VoiceOption(id: "en-US-GuyNeural", label: "Guy (M)"),
                VoiceOption(id: "en-GB-SoniaNeural", label: "Sonia — UK (F)"),
            ]
        }
    }
    private var engineShort: String {
        switch settings.engineKind { case .system: return "System"; case .kokoro: return "Kokoro"; case .azure: return "Azure" }
    }
    private var currentVoiceShort: String {
        let id = voiceBinding.wrappedValue
        guard let opt = voiceOptions.first(where: { $0.id == id }) else { return "" }
        return String(opt.label.prefix { $0 != " " && $0 != "—" })
    }

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 11) {
                circleButton("arrow.counterclockwise", size: 40, big: false) { model.onRestart?() }
                    .disabled(model.words.isEmpty)
                Button { model.onTogglePlayPause?() } label: {
                    ZStack {
                        Circle().fill(palette.shu).frame(width: 54, height: 54)
                            .overlay(Circle().stroke(palette.s1, lineWidth: 2))
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.words.isEmpty)
                circleButton("stop.fill", size: 40, big: false) { model.onStop?() }
                    .disabled(model.words.isEmpty)
            }

            Text(timeString(model.elapsed)).font(KoeFont.mono(12)).foregroundStyle(palette.soft)

            Waveform(palette: palette, active: model.isPlaying)
                .frame(maxWidth: .infinity)

            Text(timeString(model.total)).font(KoeFont.mono(12)).foregroundStyle(palette.faint)

            // Speed pill (cycles common rates)
            Menu {
                ForEach(rates, id: \.self) { r in
                    Button(String(format: "%.2g×", r)) { model.rate = r; model.onRateChange?(r) }
                }
            } label: {
                Text(String(format: "%.2g×", model.rate))
                    .font(KoeFont.mono(12)).foregroundStyle(palette.ink3)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(Capsule().fill(palette.s3))
                    .overlay(Capsule().stroke(palette.line, lineWidth: 1))
            }
            .menuStyle(.borderlessButton).fixedSize()

            // Voice pill — click to switch engine + voice (no menu bar needed)
            Menu {
                Picker("Voice engine", selection: engineBinding) {
                    ForEach(EngineKind.allCases, id: \.self) { k in Text(k.displayName).tag(k) }
                }
                Picker("Voice", selection: voiceBinding) {
                    ForEach(voiceOptions) { opt in Text(opt.label).tag(opt.id) }
                }
            } label: {
                HStack(spacing: 7) {
                    ZStack {
                        Circle().fill(palette.noteBlue).frame(width: 18, height: 18)
                        Text("声").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                    }
                    Text(currentVoiceShort.isEmpty ? engineShort : "\(engineShort) · \(currentVoiceShort)")
                        .font(KoeFont.gothic(12, .regular)).foregroundStyle(palette.ink3).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundStyle(palette.faint)
                }
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(Capsule().fill(palette.s3))
                .overlay(Capsule().stroke(palette.line, lineWidth: 1))
            }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.horizontal, 24)
        .frame(height: 84)
        .background(palette.s2)
        .overlay(Rectangle().fill(palette.line2).frame(height: 1), alignment: .top)
    }

    private func circleButton(_ icon: String, size: CGFloat, big: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(palette.ink)
                .frame(width: size, height: size)
                .background(Circle().fill(palette.s3))
                .overlay(Circle().stroke(palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Root

struct KoeRootView: View {
    @ObservedObject var model: ReaderHUDModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                KoeSidebar(model: model)
                ZStack {
                    switch model.koeView {
                    case .capture: KoeCaptureView(model: model)
                    case .read:    KoeReadingView(model: model)
                    case .canvas:  KoeCanvasView(model: model)
                    case .boards:  KoeBoardsView(model: model)
                    case .library: KoeLibraryView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            KoePlayerBar(model: model)
        }
        .background(model.palette.s1)
        .frame(minWidth: 920, minHeight: 620)
        .preferredColorScheme(model.appearance == .dark ? .dark : .light)
    }
}
