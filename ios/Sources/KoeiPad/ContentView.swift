import SwiftUI

struct ContentView: View {
    @EnvironmentObject var client: CoreClient
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
                LibraryView()
            } else {
                SignInView()
            }
        }
        .task {
            _ = try? await client.listBooks()      // an existing session signs us in silently
            checked = true
        }
    }
}
