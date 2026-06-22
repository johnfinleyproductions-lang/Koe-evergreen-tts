//
//  KoeLibrary.swift
//  ReadFlow / Koe
//
//  Library (本) — the WRITE & SYNTHESIZE workspace. An "open book" spread on a
//  warm dark desk: the LEFT page holds material you've pulled in from your Boards
//  (snippets to synthesize from, each ▶ re-listenable), and the RIGHT page is
//  where you write. Multiple sections (documents) with tabs. Everything persists.
//
//  This is the end of the flow: Capture (intake) → Canvas (form ideas) →
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

    init() {
        load()
        if sections.isEmpty {
            let s = LibrarySection(title: "Untitled", body: "")
            sections = [s]
            activeID = s.id
            save()
        } else if activeID == nil {
            activeID = sections.first?.id
        }
    }

    func load() {
        if let d = defaults.data(forKey: sectionsKey),
           let s = try? JSONDecoder().decode([LibrarySection].self, from: d) { sections = s }
        if let d = defaults.data(forKey: pulledKey),
           let p = try? JSONDecoder().decode([LibrarySnippet].self, from: d) { pulled = p }
    }

    func save() {
        if let d = try? JSONEncoder().encode(sections) { defaults.set(d, forKey: sectionsKey) }
        if let d = try? JSONEncoder().encode(pulled) { defaults.set(d, forKey: pulledKey) }
    }

    func activeIndex() -> Int? { sections.firstIndex { $0.id == activeID } }

    func addSection() {
        let s = LibrarySection(title: "Untitled \(sections.count + 1)", body: "")
        sections.append(s); activeID = s.id; save()
    }

    func removeSection(_ id: UUID) {
        sections.removeAll { $0.id == id }
        if sections.isEmpty { let s = LibrarySection(title: "Untitled", body: ""); sections = [s] }
        if activeID == id { activeID = sections.first?.id }
        save()
    }

    /// Pull all of a board's items onto the reference page (deduped by text).
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
    @ObservedObject var model: ReaderHUDModel
    @ObservedObject var store = LibraryStore.shared
    @ObservedObject private var boards = BoardStore.shared
    private let page = KoePalette.light

    var body: some View {
        ZStack {
            // Warm dark desk
            LinearGradient(colors: [Color(hex: 0x251D27), Color(hex: 0x2B2230), Color(hex: 0x241D22), Color(hex: 0x1B1611)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(hex: 0xE8AA5A, alpha: 0.16), .clear], center: .init(x: 0.7, y: 0.04), startRadius: 0, endRadius: 520)
                .allowsHitTesting(false)

            HStack(spacing: 0) {
                leftPage
                Rectangle()   // spine
                    .fill(LinearGradient(colors: [Color.black.opacity(0.28), Color.black.opacity(0.08), Color.black.opacity(0.28)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: 14)
                rightPage
            }
            .frame(maxWidth: 940, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.55), radius: 42, y: 26)
            .padding(.horizontal, 28).padding(.vertical, 26)
        }
    }

    // LEFT — pulled material (synthesize from)
    private var leftPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("聴").font(KoeFont.mincho(17)).foregroundStyle(page.shu)
                Text("PULLED MATERIAL").font(KoeFont.gothic(10.5, .bold)).tracking(2).foregroundStyle(page.mute)
                Spacer()
                Menu {
                    ForEach(boards.boards) { b in
                        Button("\(b.name) (\(b.items.count))") { store.pullBoard(b) }.disabled(b.items.isEmpty)
                    }
                    if !store.pulled.isEmpty { Divider(); Button("Clear all", role: .destructive) { store.clearPulled() } }
                } label: {
                    HStack(spacing: 4) { Text("Pull"); Image(systemName: "chevron.down").font(.system(size: 8)) }
                        .font(KoeFont.gothic(11, .bold)).foregroundStyle(page.shu)
                }
                .menuStyle(.borderlessButton).fixedSize()
            }

            if store.pulled.isEmpty {
                Text("Pull snippets from your Boards to write from. Each one stays here for reference — and you can ▶ re-listen.")
                    .font(KoeFont.mincho(13)).foregroundStyle(page.faint2).lineSpacing(5)
                    .padding(.top, 6)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(store.pulled) { snip in pulledCard(snip) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 320)
        .background(LinearGradient(colors: [Color(hex: 0xF3EAD4), Color(hex: 0xECE0C4)], startPoint: .top, endPoint: .bottom))
    }

    private func pulledCard(_ snip: LibrarySnippet) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(snip.text).font(KoeFont.mincho(13.5)).italic().foregroundStyle(page.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 7) {
                Button { listen(snip.text) } label: {
                    Image(systemName: "play.circle.fill").font(.system(size: 15)).foregroundStyle(page.shu)
                }.buttonStyle(.plain)
                if !snip.source.isEmpty { Text(snip.source).font(KoeFont.mono(9.5)).foregroundStyle(page.mute).lineLimit(1) }
                Spacer()
                Button { store.removePulled(snip.id) } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(page.faint2)
                }.buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.45))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(page.line2, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // RIGHT — your writing
    private var rightPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            // section tabs
            HStack(spacing: 6) {
                ForEach(store.sections) { s in
                    Button { store.activeID = s.id } label: {
                        Text(s.title.isEmpty ? "Untitled" : s.title)
                            .font(KoeFont.gothic(12, store.activeID == s.id ? .bold : .medium))
                            .foregroundStyle(store.activeID == s.id ? page.ink : page.faint)
                            .lineLimit(1)
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(store.activeID == s.id ? page.s2 : .clear))
                    }.buttonStyle(.plain)
                }
                Button { store.addSection() } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(page.faint)
                        .padding(6)
                }.buttonStyle(.plain)
                Spacer()
            }
            .padding(.bottom, 12)

            if let idx = store.activeIndex() {
                TextField("Title", text: $store.sections[idx].title)
                    .textFieldStyle(.plain)
                    .font(KoeFont.mincho(24, bold: true)).foregroundStyle(page.ink)
                    .padding(.bottom, 10)
                    .onSubmit { store.save() }

                TextEditor(text: $store.sections[idx].body)
                    .font(KoeFont.mincho(16))
                    .foregroundStyle(page.ink3)
                    .scrollContentBackground(.hidden)
                    .lineSpacing(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) {
                        if store.sections[idx].body.isEmpty {
                            Text("Write here. Pull material on the left to synthesize from, and ▶ to hear your draft read back.")
                                .font(KoeFont.mincho(16)).foregroundStyle(page.faint2)
                                .padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }

                // footer
                HStack(spacing: 12) {
                    Text("\(wordCount(store.sections[idx].body)) words").font(KoeFont.mono(11)).foregroundStyle(page.mute)
                    Spacer()
                    if store.sections.count > 1 {
                        Button { store.removeSection(store.sections[idx].id) } label: {
                            Image(systemName: "trash").font(.system(size: 12)).foregroundStyle(page.faint2)
                        }.buttonStyle(.plain).help("Delete this section")
                    }
                    Button { listen(store.sections[idx].body) } label: {
                        HStack(spacing: 6) { Image(systemName: "play.circle.fill").font(.system(size: 15)); Text("Listen to draft").font(KoeFont.gothic(11.5, .bold)) }
                            .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(page.shu))
                    }.buttonStyle(.plain).disabled(store.sections[idx].body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 10)
            }
        }
        .padding(28)
        .frame(maxWidth: 600, maxHeight: .infinity, alignment: .topLeading)
        .background(LinearGradient(colors: [Color(hex: 0xFBF4E6), Color(hex: 0xF6EEDD)], startPoint: .top, endPoint: .bottom))
        .onChange(of: store.sections) { _ in store.save() }
    }

    private func wordCount(_ s: String) -> Int {
        s.split { $0 == " " || $0 == "\n" || $0 == "\t" }.count
    }
    private func listen(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        NotificationCenter.default.post(name: .readFlowReadExternalText, object: text)
    }
}
