import SwiftUI

@main
struct KoeiPadApp: App {
    @StateObject private var client = CoreClient()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
                .tint(Koe.shu)
        }
    }
}
