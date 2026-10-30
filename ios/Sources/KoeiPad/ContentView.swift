import SwiftUI

/// Phase 0 placeholder: proves the toolchain, the icon, and the local-network
/// prompt. Shows whether Evergreen Core and the Kokoro voice answer on the LAN.
struct ContentView: View {
    @State private var core: Reach = .unknown
    @State private var kokoro: Reach = .unknown

    var body: some View {
        ZStack {
            KoePalette.washi.ignoresSafeArea()
            VStack(spacing: 28) {
                Text("声")
                    .font(.system(size: 120, weight: .semibold, design: .serif))
                    .foregroundStyle(KoePalette.vermilion)
                Text("Koe")
                    .font(.system(size: 34, weight: .semibold, design: .serif))
                    .foregroundStyle(KoePalette.ink)
                Text("Companion to your Mac. Books, Boards and the Quiet Hour arrive in Phase 1.")
                    .font(.system(size: 17, design: .serif))
                    .foregroundStyle(KoePalette.ink.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                VStack(alignment: .leading, spacing: 10) {
                    ReachRow(label: "Evergreen Core", state: core)
                    ReachRow(label: "Kokoro voice", state: kokoro)
                }
                .padding(18)
                .background(KoePalette.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Button("Check again") { Task { await probe() } }
                    .buttonStyle(.borderedProminent)
                    .tint(KoePalette.vermilion)
            }
            .padding(32)
        }
        .task { await probe() }
    }

    private func probe() async {
        async let c = Reach.probe("http://192.168.4.200:3000/reader")
        async let k = Reach.probe("http://192.168.4.200:8880/health")
        (core, kokoro) = await (c, k)
    }
}

enum Reach: Equatable {
    case unknown, checking, reachable(Int), unreachable(String)

    static func probe(_ url: String) async -> Reach {
        guard let u = URL(string: url) else { return .unreachable("bad URL") }
        var request = URLRequest(url: u)
        request.timeoutInterval = 5
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)
        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return .reachable(code)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    /// Any HTTP answer counts as "reachable"; don't follow Core's login redirect.
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
            Text(label).font(.system(size: 17, design: .serif)).foregroundStyle(KoePalette.ink)
            Spacer(minLength: 24)
            Text(text).font(.system(size: 15, design: .monospaced)).foregroundStyle(KoePalette.ink.opacity(0.7))
        }
        .frame(minWidth: 320)
    }

    private var color: Color {
        switch state {
        case .reachable: return Color(red: 0.49, green: 0.54, blue: 0.36)
        case .unreachable: return KoePalette.vermilion
        default: return .gray
        }
    }

    private var text: String {
        switch state {
        case .unknown: return "…"
        case .checking: return "checking"
        case .reachable(let code): return "HTTP \(code)"
        case .unreachable(let why): return why
        }
    }
}

enum KoePalette {
    static let vermilion = Color(red: 0.753, green: 0.263, blue: 0.176)   // #c0432d
    static let washi = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(red: 0.11, green: 0.10, blue: 0.09, alpha: 1)
                                          : UIColor(red: 0.96, green: 0.94, blue: 0.89, alpha: 1)
    })
    static let card = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.06) : UIColor(white: 1, alpha: 0.55)
    })
    static let ink = Color(UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(white: 0.92, alpha: 1) : UIColor(red: 0.16, green: 0.14, blue: 0.12, alpha: 1)
    })
}
