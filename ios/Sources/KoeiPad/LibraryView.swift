import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var client: CoreClient
    @State private var books: [BookSummary] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showServer = false
    @State private var showConnection = false

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty && loading {
                    ProgressView("Loading your books…").tint(Koe.shu)
                } else if books.isEmpty {
                    ContentUnavailableView {
                        Label("No books yet", systemImage: "books.vertical")
                    } description: {
                        Text(error ?? "Books you prepare in Evergreen's Reader appear here.")
                    } actions: {
                        Button("Refresh") { Task { await load() } }.tint(Koe.shu)
                    }
                } else {
                    List(books) { book in
                        NavigationLink(value: book) { BookRow(book: book) }
                            .listRowBackground(Koe.paper)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Koe.desk)
            .navigationTitle("Books")
            .navigationDestination(for: BookSummary.self) { BookView(summary: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("声").font(Koe.serif(24, .semibold)).foregroundStyle(Koe.shu)
                }
                if client.servedOffline {
                    ToolbarItem(placement: .topBarTrailing) {
                        Label("Offline", systemImage: "icloud.slash").font(.caption.weight(.medium))
                            .padding(.horizontal, 8).padding(.vertical, 4).background(Koe.paper2, in: Capsule()).foregroundStyle(Koe.ink2)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        Button { showConnection = true } label: { Label("Connection", systemImage: "dot.radiowaves.left.and.right") }
                        Button { showServer = true } label: { Label("Server…", systemImage: "server.rack") }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .tint(Koe.ink2)
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .sheet(isPresented: $showServer) { ServerSheet() }
            .sheet(isPresented: $showConnection) { ConnectionView() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do { books = try await client.listBooks(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct BookRow: View {
    let book: BookSummary
    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Koe.shu.opacity(0.85)).frame(width: 34, height: 48)
                .overlay(Text("声").font(Koe.serif(16, .semibold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 4) {
                Text(book.title).font(Koe.serif(19, .semibold)).foregroundStyle(Koe.ink)
                if !book.author.isEmpty { Text(book.author).font(Koe.serif(15)).foregroundStyle(Koe.ink2) }
                Text("\(book.ready) of \(book.count) chapters ready").font(.footnote).foregroundStyle(Koe.faint)
            }
        }
        .padding(.vertical, 6)
    }
}
