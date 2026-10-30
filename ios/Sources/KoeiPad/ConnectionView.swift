import SwiftUI

/// The Phase 0 probe, kept as a diagnostic sheet.
struct ConnectionView: View {
    @EnvironmentObject var client: CoreClient
    @Environment(\.dismiss) private var dismiss
    @State private var core: Reach = .unknown
    @State private var kokoro: Reach = .unknown

    var body: some View {
        NavigationStack {
            List {
                Section("On your network") {
                    ReachRow(label: "Evergreen Core", state: core)
                    ReachRow(label: "Kokoro voice", state: kokoro)
                }
                Section {
                    Button("Check again") { Task { await probe() } }.tint(Koe.shu)
                }
            }
            .navigationTitle("Connection")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { await probe() }
        }
    }

    private func probe() async {
        async let c = Reach.probe(client.baseURL.appendingPathComponent("reader").absoluteString)
        async let k = Reach.probe(KokoroSettings.baseURL.appendingPathComponent("health").absoluteString)
        (core, kokoro) = await (c, k)
    }
}

enum Reach: Equatable {
    case unknown, reachable(Int), unreachable(String)

    static func probe(_ url: String) async -> Reach {
        guard let u = URL(string: url) else { return .unreachable("bad URL") }
        var request = URLRequest(url: u)
        request.timeoutInterval = 5
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        do {
            let (_, response) = try await session.data(for: request)
            return .reachable((response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}

struct ReachRow: View {
    let label: String
    let state: Reach
    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(label)
            Spacer()
            Text(text).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
    private var color: Color {
        switch state {
        case .reachable: return Koe.green
        case .unreachable: return Koe.shu
        case .unknown: return .gray
        }
    }
    private var text: String {
        switch state {
        case .unknown: return "…"
        case .reachable(let code): return "HTTP \(code)"
        case .unreachable(let why): return why
        }
    }
}
