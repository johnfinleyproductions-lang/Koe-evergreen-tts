import SwiftUI
import WebKit

/// Koe's own sign-in window: Core's normal login page inside a web view.
/// When the page lands outside /auth on our server, we try the book list; if
/// it answers, the session cookies are ours.
struct SignInView: View {
    @EnvironmentObject var client: CoreClient
    @State private var checking = false
    @State private var showServer = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("声").font(Koe.serif(26, .semibold)).foregroundStyle(Koe.shu)
                Text("Connect Koe to Evergreen").font(Koe.serif(20, .semibold)).foregroundStyle(Koe.ink)
                Spacer()
                if checking { ProgressView().tint(Koe.shu) }
                Button { showServer = true } label: { Image(systemName: "server.rack") }
                    .tint(Koe.ink2)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Koe.paper)
            Divider()
            WebView(url: client.baseURL.appendingPathComponent("reader")) { url in
                Task { await landed(url) }
            }
            .id(client.baseURLString)
        }
        .background(Koe.desk)
        .sheet(isPresented: $showServer) { ServerSheet() }
    }

    private func landed(_ url: URL) async {
        guard url.host == client.baseURL.host, !url.path.hasPrefix("/auth"), !checking else { return }
        checking = true
        defer { checking = false }
        if (try? await client.listBooks()) != nil { client.signedIn = true }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    let onNavigated: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onNavigated: onNavigated) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()      // persistent: sign in once
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: url))
        return view
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onNavigated: (URL) -> Void
        init(onNavigated: @escaping (URL) -> Void) { self.onNavigated = onNavigated }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let url = webView.url { onNavigated(url) }
        }
    }
}

struct ServerSheet: View {
    @EnvironmentObject var client: CoreClient
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Evergreen Core") {
                    TextField("http://192.168.4.200:3000", text: $text)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Koe only talks to this server. On the home Wi-Fi it is the think box; away from home use its Tailscale address.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Button("Sign out of Evergreen", role: .destructive) { Task { await client.signOut(); dismiss() } }
                }
            }
            .navigationTitle("Server")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let u = URL(string: trimmed), ["http", "https"].contains(u.scheme ?? ""), u.host != nil {
                            client.baseURLString = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { text = client.baseURLString }
        }
    }
}
