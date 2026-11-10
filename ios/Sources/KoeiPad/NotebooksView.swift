import SwiftUI

/// The Mac's Library: notebooks with pages. Read-only on the iPad; tap a page to hear it.
struct NotebooksView: View {
    @EnvironmentObject var docs: MacDocuments
    @EnvironmentObject var sync: StateSync

    var body: some View {
        NavigationStack {
            content
                .background(Koe.desk)
                .navigationTitle("Library")
                .navigationDestination(for: Notebook.self) { NotebookDetailView(notebook: $0) }
                .refreshable { await sync.pullAll(force: true) }
                .toolbar { ToolbarItem(placement: .topBarLeading) { Text("声").font(Koe.serif(24, .semibold)).foregroundStyle(Koe.shu) } }
        }
    }

    @ViewBuilder private var content: some View {
        if docs.notebooks.isEmpty && docs.pulled.isEmpty {
            ContentUnavailableView {
                Label("No notebooks yet", systemImage: "book.closed")
            } description: {
                Text(sync.available ? "Your Library on the Mac appears here." : "Evergreen doesn't have the sync store yet.")
            } actions: {
                Button("Refresh") { Task { await sync.pullAll(force: true) } }.tint(Koe.shu)
            }
        } else {
            List {
                Section("Notebooks") {
                    ForEach(docs.notebooks) { notebook in
                        NavigationLink(value: notebook) { NotebookRow(notebook: notebook) }
                    }
                    .listRowBackground(Koe.paper)
                }
                if !docs.pulled.isEmpty {
                    Section("Pulled snippets") {
                        ForEach(docs.pulled) { snippet in
                            NavigationLink { SnippetReaderView(title: "Snippet", text: snippet.text, source: snippet.source) } label: {
                                Text(snippet.text).font(Koe.serif(16)).foregroundStyle(Koe.ink).lineLimit(2)
                            }
                        }
                        .listRowBackground(Koe.paper)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}

private struct NotebookRow: View {
    let notebook: Notebook
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(notebook.title).font(Koe.serif(19, .semibold)).foregroundStyle(Koe.ink)
            Text("\(notebook.tabs.count) page\(notebook.tabs.count == 1 ? "" : "s")").font(.footnote).foregroundStyle(Koe.faint)
        }
        .padding(.vertical, 4)
    }
}

struct NotebookDetailView: View {
    let notebook: Notebook
    var body: some View {
        List(notebook.tabs) { tab in
            NavigationLink { SnippetReaderView(title: tab.title, text: tab.body.isEmpty ? "(empty page)" : tab.body, source: notebook.title) } label: {
                PageRow(tab: tab)
            }
            .listRowBackground(Koe.paper)
        }
        .scrollContentBackground(.hidden)
        .background(Koe.desk)
        .navigationTitle(notebook.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PageRow: View {
    let tab: NotebookTab
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tab.title).font(Koe.serif(17, .semibold)).foregroundStyle(Koe.ink)
            Text(tab.body.isEmpty ? "Empty page" : tab.body).font(Koe.serif(15)).foregroundStyle(Koe.ink2).lineLimit(2)
            if !tab.images.isEmpty {
                Text("\(tab.images.count) image\(tab.images.count == 1 ? "" : "s") on the Mac").font(.caption).foregroundStyle(Koe.faint)
            }
        }
        .padding(.vertical, 4)
    }
}
