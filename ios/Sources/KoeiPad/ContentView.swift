import SwiftUI

struct ContentView: View {
    @EnvironmentObject var client: CoreClient
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
                LibraryView()
            } else {
                SignInView()
            }
        }
        .task {
            await client.refreshSession()      // the stored session signs us in; the call also extends it
            checked = true
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, checked { Task { await client.refreshSession() } }
        }
    }
}
