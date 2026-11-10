import SwiftUI

@main
struct KoeiPadApp: App {
    @StateObject private var client: CoreClient
    @StateObject private var sync: StateSync
    @StateObject private var docs = MacDocuments()

    init() {
        let client = CoreClient()
        _client = StateObject(wrappedValue: client)
        _sync = StateObject(wrappedValue: StateSync(client: client))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(client)
                .environmentObject(sync)
                .environmentObject(docs)
                .tint(Koe.shu)
        }
    }
}
