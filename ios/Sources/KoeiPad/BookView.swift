import SwiftUI

struct BookView: View {
    @EnvironmentObject var client: CoreClient
    let summary: BookSummary
    @State private var detail: BookDetailResponse?
    @State private var place: Place?
    @State private var error: String?

    var body: some View {
        Group {
            if let detail {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(detail.book.title).font(Koe.serif(26, .semibold)).foregroundStyle(Koe.ink)
                            if !detail.book.author.isEmpty { Text(detail.book.author).font(Koe.serif(17)).foregroundStyle(Koe.ink2) }
                            HStack(spacing: 12) {
                                if let pages = detail.book.pageCount { Label("\(pages) pages", systemImage: "doc.text") }
                                Label("\(detail.chapters.filter(\.isReady).count) of \(detail.chapters.count) ready", systemImage: "waveform")
                            }
                            .font(.footnote).foregroundStyle(Koe.faint)
                        }
                        .padding(.vertical, 6)
                        if let place, let chapter = detail.chapters.first(where: { $0.id == place.chapterId }) {
                            NavigationLink {
                                ReaderView(book: detail.book, chapters: detail.chapters, chapter: chapter, place: place)
                            } label: {
                                Label(place.voiceSource == .kokoro ? "Continue · \(chapter.title) · Kokoro, word \((place.kokoroWord ?? 0) + 1)"
                                                                  : "Continue · \(chapter.title) · \(clock(place.seconds))", systemImage: "play.circle.fill")
                                    .font(Koe.serif(17, .semibold)).foregroundStyle(Koe.shu)
                            }
                        }
                    }
                    .listRowBackground(Koe.paper)
                    Section("Chapters") {
                        ForEach(detail.chapters) { chapter in
                            NavigationLink {
                                ReaderView(book: detail.book, chapters: detail.chapters, chapter: chapter,
                                           place: place?.chapterId == chapter.id ? place : nil)
                            } label: { ChapterRow(chapter: chapter, current: place?.chapterId == chapter.id) }
                        }
                        .listRowBackground(Koe.paper)
                    }
                }
                .scrollContentBackground(.hidden)
            } else if let error {
                ContentUnavailableView("Couldn't load this book", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().tint(Koe.shu)
            }
        }
        .background(Koe.desk)
        .navigationTitle(summary.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onAppear { place = PlaceStore.load(summary.id) }
    }

    private func load() async {
        do { detail = try await client.book(summary.id); place = PlaceStore.load(summary.id) }
        catch { self.error = error.localizedDescription }
    }
}

struct ChapterRow: View {
    let chapter: Chapter
    let current: Bool
    var body: some View {
        HStack(spacing: 12) {
            Text(String(chapter.position)).font(.system(.footnote, design: .monospaced)).foregroundStyle(Koe.faint).frame(width: 28, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Text(chapter.title).font(Koe.serif(17, current ? .semibold : .regular)).foregroundStyle(Koe.ink)
                HStack(spacing: 8) {
                    if let first = chapter.sourcePages.min(), let last = chapter.sourcePages.max() {
                        Text(first == last ? "p. \(first)" : "pp. \(first)–\(last)")
                    }
                    if let d = chapter.durationSeconds, d > 0, chapter.isReady { Text(clock(d)) }
                    if !chapter.isReady { Text("Kokoro reads it") }
                }
                .font(.footnote).foregroundStyle(Koe.faint)
            }
            Spacer()
            Text(chapter.statusLabel)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background((chapter.isReady ? Koe.green : chapter.status == "failed" ? Koe.shu : Koe.faint).opacity(0.18), in: Capsule())
                .foregroundStyle(chapter.isReady ? Koe.green : chapter.status == "failed" ? Koe.shu : Koe.faint)
        }
        .padding(.vertical, 4)
    }
}

func clock(_ seconds: Double) -> String {
    let total = max(0, Int(seconds.rounded()))
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}
