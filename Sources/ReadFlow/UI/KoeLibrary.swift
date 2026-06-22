//
//  KoeLibrary.swift
//  ReadFlow / Koe
//
//  Library (本) — the WRITE & SYNTHESIZE workspace as a cozy study desk. A shelf
//  of NOTEBOOKS you browse; click one and it opens ~full-screen as a two-page
//  spread (pulled Board material on the left, your writing on the right). Each
//  notebook has TABS (pages); each page holds text + dragged-in images. Click
//  anywhere on the page to write. Everything persists.
//

import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Model

struct LibrarySnippet: Identifiable, Codable, Equatable { var id = UUID(); var text: String; var source: String = "" }
struct LibraryImage: Identifiable, Codable, Equatable { var id = UUID(); var filename: String }
struct NotebookTab: Identifiable, Codable, Equatable { var id = UUID(); var title: String; var body: String = ""; var images: [LibraryImage] = [] }
struct Notebook: Identifiable, Codable, Equatable {
    var id = UUID(); var title: String
    var tabs: [NotebookTab] = [NotebookTab(title: "Page 1")]
    var activeTabID: UUID?
}

/// Legacy flat model, kept only to migrate old saved writing into notebooks.
private struct LegacySection: Codable { var id: UUID; var title: String; var body: String }

// MARK: - Store (persisted)

@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published var notebooks: [Notebook] = []
    @Published var pulled: [LibrarySnippet] = []

    private let notebooksKey = "readflow.notebooks"
    private let legacyKey = "readflow.librarySections"
    private let pulledKey = "readflow.libraryPulled"
    private let defaults = UserDefaults.standard
    private let accents: [UInt32] = [0xC0432D, 0x7C8A5B, 0xCF9B4A, 0x33455F, 0x8A5A9E, 0x3E7C8A]

    static var imagesDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koe/images", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    static func imageURL(_ name: String) -> URL { imagesDir.appendingPathComponent(name) }

    init() {
        load()
        if notebooks.isEmpty { migrateOrSeed() }
        for i in notebooks.indices where notebooks[i].activeTabID == nil { notebooks[i].activeTabID = notebooks[i].tabs.first?.id }
    }

    func accent(_ id: UUID) -> Color { Color(hex: accents[(notebooks.firstIndex { $0.id == id } ?? 0) % accents.count]) }

    func load() {
        if let d = defaults.data(forKey: notebooksKey), let n = try? JSONDecoder().decode([Notebook].self, from: d) { notebooks = n }
        if let d = defaults.data(forKey: pulledKey), let p = try? JSONDecoder().decode([LibrarySnippet].self, from: d) { pulled = p }
    }
    func save() {
        if let d = try? JSONEncoder().encode(notebooks) { defaults.set(d, forKey: notebooksKey) }
        if let d = try? JSONEncoder().encode(pulled) { defaults.set(d, forKey: pulledKey) }
    }
    private func migrateOrSeed() {
        if let d = defaults.data(forKey: legacyKey), let old = try? JSONDecoder().decode([LegacySection].self, from: d), !old.isEmpty {
            notebooks = old.map { s in
                let tab = NotebookTab(title: "Page 1", body: s.body)
                return Notebook(title: s.title, tabs: [tab], activeTabID: tab.id)
            }
        } else {
            let tab = NotebookTab(title: "Page 1")
            notebooks = [Notebook(title: "Untitled", tabs: [tab], activeTabID: tab.id)]
        }
        save()
    }

    // notebooks
    @discardableResult
    func addNotebook() -> UUID {
        let tab = NotebookTab(title: "Page 1")
        let nb = Notebook(title: "Untitled \(notebooks.count + 1)", tabs: [tab], activeTabID: tab.id)
        notebooks.append(nb); save(); return nb.id
    }
    func removeNotebook(_ id: UUID) {
        notebooks.removeAll { $0.id == id }
        if notebooks.isEmpty { _ = addNotebook() } else { save() }
    }
    // tabs
    func addTab(to nbID: UUID) {
        guard let n = notebooks.firstIndex(where: { $0.id == nbID }) else { return }
        let t = NotebookTab(title: "Page \(notebooks[n].tabs.count + 1)")
        notebooks[n].tabs.append(t); notebooks[n].activeTabID = t.id; save()
    }
    func removeTab(_ tabID: UUID, from nbID: UUID) {
        guard let n = notebooks.firstIndex(where: { $0.id == nbID }) else { return }
        notebooks[n].tabs.removeAll { $0.id == tabID }
        if notebooks[n].tabs.isEmpty { notebooks[n].tabs = [NotebookTab(title: "Page 1")] }
        if notebooks[n].activeTabID == tabID { notebooks[n].activeTabID = notebooks[n].tabs.first?.id }
        save()
    }
    // images
    func addImage(_ filename: String, toNotebook nbID: UUID) {
        guard let n = notebooks.firstIndex(where: { $0.id == nbID }),
              let t = notebooks[n].tabs.firstIndex(where: { $0.id == notebooks[n].activeTabID }) else { return }
        notebooks[n].tabs[t].images.append(LibraryImage(filename: filename)); save()
    }
    func removeImage(_ imgID: UUID, tab tabID: UUID, notebook nbID: UUID) {
        guard let n = notebooks.firstIndex(where: { $0.id == nbID }),
              let t = notebooks[n].tabs.firstIndex(where: { $0.id == tabID }) else { return }
        notebooks[n].tabs[t].images.removeAll { $0.id == imgID }; save()
    }
    // pulled
    func pullBoard(_ board: Board) {
        for item in board.items where !pulled.contains(where: { $0.text == item.text }) {
            pulled.insert(LibrarySnippet(text: item.text, source: item.source.isEmpty ? board.name : item.source), at: 0)
        }
        save()
    }
    func removePulled(_ id: UUID) { pulled.removeAll { $0.id == id }; save() }
    func clearPulled() { pulled = []; save() }
}

// MARK: - Library view

struct KoeLibraryView: View {
    @ObservedObject var store = LibraryStore.shared
    @ObservedObject private var boards = BoardStore.shared
    @State private var openID: UUID?
    @State private var editingTabID: UUID?
    @State private var dropTargeted = false
    @FocusState private var writing: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack {
                room; warmGlow
                StringLights().frame(height: 70).frame(maxHeight: .infinity, alignment: .top)
                rainyWindow.position(x: geo.size.width / 2, y: 150)
                deskSurface; lampPool
                VinylWidget().position(x: 96, y: geo.size.height - 78)
                SteamingMug().position(x: geo.size.width - 96, y: geo.size.height - 120)
                ambientPanel.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(20)
                vignette
                if openID != nil { openMode(geo: geo) } else { shelfMode(geo: geo) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    // MARK: Shelf mode

    private func shelfMode(geo: GeometryProxy) -> some View {
        VStack(spacing: 18) {
            Text("棚  Your Notebooks").font(KoeFont.mincho(22, bold: true)).foregroundStyle(Color(hex: 0xE8DCC4)).shadow(color: .black.opacity(0.5), radius: 6)
            HStack(alignment: .bottom, spacing: 7) {
                ForEach(store.notebooks) { bigSpine($0) }
                bigAddBook
            }
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(hex: 0x5A4327), Color(hex: 0x2F2316)], startPoint: .top, endPoint: .bottom)
                Rectangle().fill(.white.opacity(0.07)).frame(height: 3)
            }
            .frame(width: min(geo.size.width * 0.82, 760), height: 18).clipShape(RoundedRectangle(cornerRadius: 3)).shadow(color: .black.opacity(0.6), radius: 12, y: 7)
            Text("Click a book to open it · ＋ to start a new one").font(KoeFont.gothic(11)).foregroundStyle(Color(hex: 0xB89A66))
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity).transition(.opacity)
    }

    private func bigSpine(_ nb: Notebook) -> some View {
        let accent = store.accent(nb.id)
        let h = 150.0 + Double(abs(nb.id.hashValue) % 50)
        return Button { withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { openID = nb.id } } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(LinearGradient(colors: [accent.opacity(0.55), accent, accent.opacity(0.8)], startPoint: .leading, endPoint: .trailing))
                Rectangle().fill(.white.opacity(0.22)).frame(width: 2).offset(x: -13)
                Rectangle().fill(.black.opacity(0.22)).frame(height: 12).offset(y: -(h / 2) + 16)
                Rectangle().fill(.black.opacity(0.22)).frame(height: 12).offset(y: (h / 2) - 16)
                Text(nb.title.isEmpty ? "Untitled" : nb.title).font(KoeFont.gothic(13, .bold)).foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1).fixedSize().rotationEffect(.degrees(-90)).frame(width: 24, height: h - 36)
            }
            .frame(width: 46, height: h).overlay(RoundedRectangle(cornerRadius: 3).stroke(.black.opacity(0.3), lineWidth: 0.5)).shadow(color: .black.opacity(0.5), radius: 6, y: 4)
        }
        .buttonStyle(.plain).help(nb.title.isEmpty ? "Untitled notebook" : nb.title)
    }

    private var bigAddBook: some View {
        Button { let id = store.addNotebook(); withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) { openID = id } } label: {
            VStack(spacing: 6) { Image(systemName: "plus").font(.system(size: 16, weight: .bold)); Text("New").font(KoeFont.gothic(10, .bold)) }
                .foregroundStyle(Color(hex: 0xC4AD7F)).frame(width: 46, height: 150)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color(hex: 0x2C2017, alpha: 0.5)))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color(hex: 0xC4AD7F), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        }.buttonStyle(.plain).help("New notebook")
    }

    // MARK: Open mode

    private func openMode(geo: GeometryProxy) -> some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { close() }
            if let nbIdx = store.notebooks.firstIndex(where: { $0.id == openID }) {
                HStack(spacing: 0) {
                    leftPage
                    Rectangle().fill(LinearGradient(colors: [Color(hex: 0x503C1E, alpha: 0.5), Color(hex: 0x503C1E, alpha: 0.12)], startPoint: .leading, endPoint: .trailing)).frame(width: 5)
                    writingPage(nbIdx)
                }
                .frame(width: geo.size.width * 0.88, height: geo.size.height * 0.88)
                .clipShape(RoundedRectangle(cornerRadius: 10)).shadow(color: .black.opacity(0.7), radius: 50, y: 30)
                .overlay(alignment: .topLeading) {
                    Button { close() } label: {
                        HStack(spacing: 6) { Image(systemName: "chevron.left"); Text("Bookshelf").font(KoeFont.gothic(12, .bold)) }
                            .foregroundStyle(Color(hex: 0xF3EAD4)).padding(.horizontal, 13).padding(.vertical, 8).background(Capsule().fill(Color(hex: 0x2C2017, alpha: 0.9)))
                    }.buttonStyle(.plain).padding(14)
                }
            }
        }.transition(.opacity)
    }
    private func close() { writing = false; editingTabID = nil; withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { openID = nil } }

    // LEFT — pulled material
    private var leftPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("聴").font(KoeFont.mincho(17)).foregroundStyle(Color(hex: 0xC0432D))
                Text("FROM YOUR LISTENING").font(KoeFont.gothic(10, .bold)).tracking(1.5).foregroundStyle(Color(hex: 0x9A7D4F))
            }
            if store.pulled.isEmpty {
                Text("Bring quotes you saved into this page, then write from them →").font(KoeFont.hand(14)).foregroundStyle(Color(hex: 0xA9966F)).lineSpacing(5)
            } else {
                ScrollView { VStack(alignment: .leading, spacing: 14) {
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
                        .padding(.leading, 11).overlay(Rectangle().fill(Color(hex: 0xD8B27A)).frame(width: 2), alignment: .leading)
                    }
                } }
            }
            Spacer(minLength: 0)
            Menu {
                ForEach(boards.boards) { b in Button("\(b.name) (\(b.items.count))") { store.pullBoard(b) }.disabled(b.items.isEmpty) }
                if !store.pulled.isEmpty { Divider(); Button("Clear all", role: .destructive) { store.clearPulled() } }
            } label: {
                Text("＋ Pull from boards ▾").font(KoeFont.gothic(12, .bold)).foregroundStyle(Color(hex: 0xF3EAD4)).frame(maxWidth: .infinity).padding(.vertical, 11).background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: 0x2C2017)))
            }.menuStyle(.borderlessButton)
        }
        .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LinearGradient(colors: [Color(hex: 0xF3EAD4), Color(hex: 0xECE0C4)], startPoint: .top, endPoint: .bottom))
        .clipShape(.rect(topLeadingRadius: 8, bottomLeadingRadius: 8))
    }

    // RIGHT — the open notebook: title, tabs, writing + images
    private func writingPage(_ nbIdx: Int) -> some View {
        let nbID = store.notebooks[nbIdx].id
        let tabIdx = store.notebooks[nbIdx].tabs.firstIndex { $0.id == store.notebooks[nbIdx].activeTabID } ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            // notebook title + listen
            HStack(spacing: 9) {
                Circle().fill(store.accent(nbID)).frame(width: 10, height: 10)
                TextField("Untitled", text: $store.notebooks[nbIdx].title).textFieldStyle(.plain).font(KoeFont.mincho(18, bold: true)).foregroundStyle(Color(hex: 0x3A3328)).onSubmit { store.save() }
                Button { listen(store.notebooks[nbIdx].tabs[tabIdx].body) } label: { Image(systemName: "play.circle.fill").font(.system(size: 16)).foregroundStyle(Color(hex: 0xC0432D)) }
                    .buttonStyle(.plain).disabled(store.notebooks[nbIdx].tabs[tabIdx].body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("書").font(KoeFont.mincho(13)).foregroundStyle(Color(hex: 0xBCAA86))
            }
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 8)

            tabsRow(nbIdx)
            Rectangle().fill(Color(hex: 0x786428, alpha: 0.2)).frame(height: 1).padding(.horizontal, 22).padding(.top, 4)

            // page: click anywhere to write + drop images
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ZStack(alignment: .topLeading) {
                        RuledLines().frame(minHeight: 320)
                        TextEditor(text: $store.notebooks[nbIdx].tabs[tabIdx].body)
                            .font(KoeFont.mincho(16)).foregroundStyle(Color(hex: 0x3A3328)).scrollContentBackground(.hidden).lineSpacing(14)
                            .frame(minHeight: 320).focused($writing)
                        if store.notebooks[nbIdx].tabs[tabIdx].body.isEmpty {
                            Text("Now that you've listened… write what stayed with you.\nClick anywhere to write — and drag images onto the page.")
                                .font(KoeFont.mincho(15)).foregroundStyle(Color(hex: 0xBCAA86)).lineSpacing(4).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                    imageGallery(nbIdx: nbIdx, tabIdx: tabIdx)
                }
                .padding(.horizontal, 18).padding(.top, 10)
                .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture { writing = true }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                Circle().fill(Color(hex: 0x7C8A5B)).frame(width: 6, height: 6)
                Text("auto-saved · \(wordCount(store.notebooks[nbIdx].tabs[tabIdx].body)) words").font(KoeFont.mono(10)).foregroundStyle(Color(hex: 0xBCAA86))
                Spacer()
                Button { store.removeNotebook(nbID); close() } label: { Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Color(hex: 0xBCAA86)) }.buttonStyle(.plain).help("Delete notebook")
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
        }
        .onChange(of: store.notebooks) { _ in store.save() }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(hex: 0xFBF4E4))
        .overlay(dropTargeted ? RoundedRectangle(cornerRadius: 6).stroke(Color(hex: 0xC0432D), lineWidth: 3).padding(6) : nil)
        .clipShape(.rect(bottomTrailingRadius: 8, topTrailingRadius: 8))
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted) { importDrop($0) }
    }

    private func tabsRow(_ nbIdx: Int) -> some View {
        let nbID = store.notebooks[nbIdx].id
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(store.notebooks[nbIdx].tabs) { tab in
                    let active = store.notebooks[nbIdx].activeTabID == tab.id
                    Group {
                        if editingTabID == tab.id, let tIdx = store.notebooks[nbIdx].tabs.firstIndex(where: { $0.id == tab.id }) {
                            TextField("Page", text: $store.notebooks[nbIdx].tabs[tIdx].title)
                                .textFieldStyle(.plain).font(KoeFont.gothic(12, .bold)).frame(width: 70)
                                .onSubmit { editingTabID = nil; store.save() }
                        } else {
                            Text(tab.title).font(KoeFont.gothic(12, active ? .bold : .medium))
                                .foregroundStyle(active ? Color(hex: 0x3A3328) : Color(hex: 0x9A8358)).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(active ? Color(hex: 0xF1E7D0) : .clear))
                    .overlay(active ? RoundedRectangle(cornerRadius: 7).stroke(Color(hex: 0xD8C4A0), lineWidth: 1) : nil)
                    .onTapGesture(count: 2) { editingTabID = tab.id }
                    .onTapGesture { store.notebooks[nbIdx].activeTabID = tab.id }
                    .contextMenu { if store.notebooks[nbIdx].tabs.count > 1 { Button("Delete page", role: .destructive) { store.removeTab(tab.id, from: nbID) } } }
                }
                Button { store.addTab(to: nbID) } label: { Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(Color(hex: 0x9A8358)).padding(6) }.buttonStyle(.plain).help("New page")
            }
            .padding(.horizontal, 22)
        }
        .frame(height: 34)
    }

    @ViewBuilder
    private func imageGallery(nbIdx: Int, tabIdx: Int) -> some View {
        let imgs = store.notebooks[nbIdx].tabs[tabIdx].images
        if !imgs.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(imgs) { img in
                    if let ns = NSImage(contentsOf: LibraryStore.imageURL(img.filename)) {
                        Image(nsImage: ns).resizable().aspectRatio(contentMode: .fill)
                            .frame(height: 110).frame(maxWidth: .infinity).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color(hex: 0xD8C4A0), lineWidth: 1))
                            .overlay(alignment: .topTrailing) {
                                Button { store.removeImage(img.id, tab: store.notebooks[nbIdx].tabs[tabIdx].id, notebook: store.notebooks[nbIdx].id) } label: {
                                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.white).shadow(radius: 2)
                                }.buttonStyle(.plain).padding(4)
                            }
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: Helpers

    private func importDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let nbID = openID else { return false }
        var handled = false
        for p in providers {
            if p.canLoadObject(ofClass: NSImage.self) {
                handled = true
                p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage, let tiff = img.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
                    let name = UUID().uuidString + ".png"
                    try? png.write(to: LibraryStore.imageURL(name))
                    Task { @MainActor in self.store.addImage(name, toNotebook: nbID) }
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    var src: URL?
                    if let d = item as? Data { src = URL(dataRepresentation: d, relativeTo: nil) } else if let u = item as? URL { src = u }
                    guard let url = src, NSImage(contentsOf: url) != nil else { return }
                    let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
                    let name = UUID().uuidString + "." + ext
                    try? FileManager.default.copyItem(at: url, to: LibraryStore.imageURL(name))
                    Task { @MainActor in self.store.addImage(name, toNotebook: nbID) }
                }
            }
        }
        return handled
    }

    private func wordCount(_ s: String) -> Int { s.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count }
    private func listen(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        NotificationCenter.default.post(name: .readFlowReadExternalText, object: text)
    }

    // MARK: Backdrop pieces
    private var room: some View { LinearGradient(colors: [Color(hex: 0x251D27), Color(hex: 0x2B2230), Color(hex: 0x241D22), Color(hex: 0x1B1611)], startPoint: .top, endPoint: .bottom) }
    private var warmGlow: some View { RadialGradient(colors: [Color(hex: 0xE8AA5A, alpha: 0.20), .clear], center: .init(x: 0.7, y: 0.02), startRadius: 0, endRadius: 540).allowsHitTesting(false) }
    private var deskSurface: some View {
        VStack { Spacer(); LinearGradient(colors: [Color(hex: 0x3A2C1F), Color(hex: 0x4B3825), Color(hex: 0x3D2D1F)], startPoint: .top, endPoint: .bottom).frame(height: 300)
            .overlay(Rectangle().fill(.black.opacity(0.18)).blur(radius: 12).frame(height: 24), alignment: .top) }.allowsHitTesting(false)
    }
    private var lampPool: some View { RadialGradient(colors: [Color(hex: 0xF6C678, alpha: 0.28), .clear], center: .center, startRadius: 0, endRadius: 360).frame(width: 780, height: 460).offset(y: 30).allowsHitTesting(false) }
    private var vignette: some View { RadialGradient(colors: [.clear, .black.opacity(0.55)], center: .center, startRadius: 240, endRadius: 640).allowsHitTesting(false) }
    private var rainyWindow: some View {
        ZStack {
            LinearGradient(colors: [Color(hex: 0x121828), Color(hex: 0x1A2236), Color(hex: 0x212A3E)], startPoint: .top, endPoint: .bottom)
            bokeh(0xFFD9A0, 30, x: -150, y: -55); bokeh(0xA9C6EF, 18, x: -74, y: -12); bokeh(0xFFCF86, 22, x: 70, y: -50); bokeh(0x9FB9E8, 16, x: 132, y: 8); bokeh(0xFFD79A, 20, x: -16, y: 42)
            RainView()
            Rectangle().fill(Color(hex: 0x2C2017)).frame(width: 8); Rectangle().fill(Color(hex: 0x2C2017)).frame(height: 8)
            LinearGradient(colors: [.white.opacity(0.07), .clear], startPoint: .topLeading, endPoint: .center)
        }
        .frame(width: 452, height: 230).clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(hex: 0x2C2017), lineWidth: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(hex: 0x19120C), lineWidth: 2).padding(-9))
        .shadow(color: .black.opacity(0.65), radius: 22, y: 18).allowsHitTesting(false)
    }
    private func bokeh(_ hex: UInt32, _ d: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        RadialGradient(colors: [Color(hex: hex), .clear], center: .center, startRadius: 0, endRadius: d * 0.7).frame(width: d * 2, height: d * 2).offset(x: x, y: y)
    }
    private var ambientPanel: some View {
        HStack(spacing: 9) { pill("☔", "Rain"); pill("♪", "Lo-fi") }
            .padding(7).background(Capsule().fill(Color(hex: 0x1A1410, alpha: 0.62))).overlay(Capsule().stroke(Color(hex: 0x7C6848, alpha: 0.38), lineWidth: 1))
    }
    private func pill(_ glyph: String, _ label: String) -> some View {
        HStack(spacing: 5) { Text(glyph).font(.system(size: 12)); Text(label).font(KoeFont.gothic(11, .medium)) }
            .foregroundStyle(Color(hex: 0xE8DCC4)).padding(.horizontal, 11).padding(.vertical, 6).background(Capsule().fill(.white.opacity(0.05)))
    }
}

// MARK: - Atmospheric animated pieces

private struct RuledLines: View {
    var body: some View {
        Canvas { ctx, size in
            var y: CGFloat = 30
            while y < size.height { var p = Path(); p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: size.width, y: y)); ctx.stroke(p, with: .color(Color(hex: 0x786428, alpha: 0.16)), lineWidth: 1); y += 30 }
        }.allowsHitTesting(false)
    }
}

private struct RainView: View {
    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { c, size in
                let n = 60; let span = Double(size.height) + 40
                for i in 0..<n {
                    let fi = Double(i)
                    let seed = (fi * 12.9898).truncatingRemainder(dividingBy: 1.0)
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

private struct VinylWidget: View {
    @State private var spin = false
    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(Color(hex: 0x1A130D)).overlay(Circle().stroke(Color(hex: 0x221912), lineWidth: 2).padding(6)).overlay(Circle().stroke(Color(hex: 0x221912), lineWidth: 2).padding(12))
                Circle().fill(Color(hex: 0xC0432D)).frame(width: 16, height: 16); Circle().fill(Color(hex: 0x15100C)).frame(width: 4, height: 4)
            }
            .frame(width: 58, height: 58).rotationEffect(.degrees(spin ? 360 : 0)).animation(.linear(duration: 4).repeatForever(autoreverses: false), value: spin)
            VStack(alignment: .leading, spacing: 2) {
                Text("midnight study").font(KoeFont.gothic(11.5, .medium)).foregroundStyle(Color(hex: 0xE8DCC4))
                Text("lo-fi · ch.1").font(KoeFont.mono(10)).foregroundStyle(Color(hex: 0x9A8F7B))
                HStack(alignment: .bottom, spacing: 2) { ForEach(0..<4, id: \.self) { i in RoundedRectangle(cornerRadius: 1).fill(Color(hex: [0x7C8A5B, 0x9FB083, 0x7C8A5B, 0xCF9B4A][i])).frame(width: 3, height: [9, 14, 7, 11][i]) } }.frame(height: 14).padding(.top, 3)
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 13).fill(Color(hex: 0x1A1410, alpha: 0.72))).overlay(RoundedRectangle(cornerRadius: 13).stroke(Color(hex: 0x7C6848, alpha: 0.4), lineWidth: 1)).shadow(color: .black.opacity(0.6), radius: 16, y: 10)
        .onAppear { spin = true }
    }
}

private struct SteamingMug: View {
    @State private var rise = false
    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 6) { ForEach(0..<3, id: \.self) { i in Capsule().fill(Color(hex: 0xE8DCC4, alpha: 0.4)).frame(width: 5, height: 22).offset(y: rise ? -26 : -10).opacity(rise ? 0 : 0.6).animation(.easeOut(duration: 3.2).repeatForever(autoreverses: false).delay(Double(i) * 0.9), value: rise) } }.offset(y: -34)
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(LinearGradient(colors: [Color(hex: 0xB9572F), Color(hex: 0x9A3F22)], startPoint: .top, endPoint: .bottom)).frame(width: 50, height: 42)
                RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x3B2218)).frame(width: 36, height: 8).offset(y: -15)
            }.overlay(Circle().stroke(Color(hex: 0x9A3F22), lineWidth: 5).frame(width: 18, height: 18).offset(x: 30, y: -4))
        }.shadow(color: .black.opacity(0.5), radius: 10, y: 8).onAppear { rise = true }
    }
}

private struct StringLights: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack {
                Path { p in p.move(to: .init(x: -10, y: 6)); p.addQuadCurve(to: .init(x: w * 0.33, y: 16), control: .init(x: w * 0.15, y: 50)); p.addQuadCurve(to: .init(x: w * 0.66, y: 18), control: .init(x: w * 0.5, y: 8)); p.addQuadCurve(to: .init(x: w + 10, y: 8), control: .init(x: w * 0.85, y: 34)) }.stroke(Color(hex: 0x786448, alpha: 0.45), lineWidth: 1.4)
                ForEach(0..<5, id: \.self) { i in let xs: [CGFloat] = [0.15, 0.33, 0.5, 0.66, 0.83]; let ys: [CGFloat] = [40, 36, 42, 34, 40]; Circle().fill(RadialGradient(colors: [Color(hex: i % 2 == 0 ? 0xFFCF86 : 0xFFD79A), .clear], center: .center, startRadius: 0, endRadius: 9)).frame(width: 18, height: 18).position(x: w * xs[i], y: ys[i]) }
            }
        }.allowsHitTesting(false)
    }
}
