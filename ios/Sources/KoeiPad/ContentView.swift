import SwiftUI

struct ContentView: View {
    @EnvironmentObject var client: CoreClient
    @EnvironmentObject var sync: StateSync
    @Environment(\.scenePhase) private var scenePhase
    @State private var checked = false

    var body: some View {
        Group {
            if !checked {
                ZStack {
                    Koe.desk.ignoresSafeArea()
                    VStack(spacing: 12) {
                        Text("声").font(Koe.serif(96, .semibold)).foregroundStyle(Koe.shu)
                        ProgressView().tint(Koe.shu)
                    }
                }
            } else if client.signedIn {
                TabView {
                    LibraryView().tabItem { Label("Books", systemImage: "books.vertical") }
                    BoardsView().tabItem { Label("Boards", systemImage: "rectangle.stack") }
                    NotebooksView().tabItem { Label("Library", systemImage: "book.closed") }
                    CanvasView().tabItem { Label("Canvas", systemImage: "square.grid.3x3") }
                }
            } else {
                SignInView()
            }
        }
        .task {
            await client.refreshSession()      // the stored session signs us in; the call also extends it
            checked = true
            await sync.pullAll(force: true)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, checked { Task { await client.refreshSession(); await sync.pullAll() } }
        }
        .onChange(of: client.signedIn) { _, signedIn in
            if signedIn { Task { await sync.pullAll(force: true) } }
        }
    }
}
