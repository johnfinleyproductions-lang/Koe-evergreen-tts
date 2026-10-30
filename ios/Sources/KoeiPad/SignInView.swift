import SwiftUI
import WebKit

/// Sign-in, done once per iPad. Primary path: Core's own login page in a web
/// view (Google works there); when it lands outside /auth on our server, Koe
/// adopts the session cookies into its own jar and keeps them refreshed.
/// Secondary path: an emailed magic link, pasted in, for when Core has an
/// email provider configured.
struct SignInView: View {
    @EnvironmentObject var client: CoreClient
    @State private var checking = false
    @State private var showServer = false
    @State private var showEmail = false
    @State private var reloadToken = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("声").font(Koe.serif(26, .semibold)).foregroundStyle(Koe.shu)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in to Evergreen").font(Koe.serif(20, .semibold)).foregroundStyle(Koe.ink)
                    Text("Once. Koe keeps you signed in on this iPad afterwards.").font(.footnote).foregroundStyle(Koe.ink2)
                }
                Spacer()
                if checking { ProgressView().tint(Koe.shu) }
                Button { reloadToken += 1 } label: { Image(systemName: "arrow.clockwise") }.tint(Koe.ink2)
                Button { showEmail.toggle() } label: { Image(systemName: "envelope") }.tint(showEmail ? Koe.shu : Koe.ink2)
                Button { showServer = true } label: { Image(systemName: "server.rack") }.tint(Koe.ink2)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Koe.paper)
            Divider()
            if showEmail {
                MagicLinkPanel()
                Divider()
            }
            WebView(url: client.baseURL.appendingPathComponent("reader")) { url in
                Task { await landed(url) }
            }
            .id("\(client.baseURLString)-\(reloadToken)")
        }
        .background(Koe.desk)
        .sheet(isPresented: $showServer) { ServerSheet() }
    }

    private func landed(_ url: URL) async {
        guard url.host == client.baseURL.host, !url.path.hasPrefix("/auth"), !checking else { return }
        checking = true
        defer { checking = false }
        _ = await client.adoptWebCookies()
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    let onNavigated: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onNavigated: onNavigated) }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
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

/// The emailed-link path: request, copy the link from Mail, paste it here.
struct MagicLinkPanel: View {
    @EnvironmentObject var client: CoreClient
    @State private var email = UserDefaults.standard.string(forKey: "koe.email") ?? ""
    @State private var link = ""
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Or sign in with an emailed link").font(Koe.serif(17, .semibold)).foregroundStyle(Koe.ink)
            HStack(spacing: 10) {
                TextField("you@example.com", text: $email)
                    .textContentType(.emailAddress).keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(10).background(Koe.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Button { Task { await send() } } label: { Text("Email me a link").fontWeight(.semibold) }
                    .buttonStyle(.borderedProminent).tint(Koe.shu).disabled(busy || !email.contains("@"))
            }
            Text("In Mail, long-press the Sign in button → Copy Link. Don't tap it (Safari would get the session, not Koe). Then paste it here.")
                .font(.footnote).foregroundStyle(Koe.ink2)
            HStack(spacing: 10) {
                TextField("http://…/api/auth/magic-link/verify?token=…", text: $link)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .padding(10).background(Koe.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                PasteButton(payloadType: String.self) { strings in
                    if let s = strings.first { link = s; Task { await finish(s) } }
                }
                .labelStyle(.iconOnly).buttonBorderShape(.capsule).tint(Koe.ink)
                Button { Task { await finish(link) } } label: { Text("Sign in").fontWeight(.semibold) }
                    .buttonStyle(.borderedProminent).tint(Koe.shu).disabled(busy || link.isEmpty)
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(message.hasPrefix("✓") ? Koe.green : Koe.shu)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Koe.paper2)
    }

    private func send() async {
        busy = true; message = "Asking Evergreen for a link…"
        defer { busy = false }
        do {
            try await client.requestMagicLink(email: email.trimmingCharacters(in: .whitespaces).lowercased())
            message = "✓ Sent. Check Mail on this iPad, copy the link, and paste it here."
        } catch { message = error.localizedDescription }
    }

    private func finish(_ value: String) async {
        guard !value.isEmpty else { return }
        busy = true; message = "Signing in…"
        defer { busy = false }
        do { try await client.completeMagicLink(value); message = "✓ Signed in." }
        catch { message = error.localizedDescription }
    }
}

struct ServerSheet: View {
    private struct VoiceList: Decodable { struct Voice: Decodable { var id: String }; var voices: [Voice] }
    private func loadVoices() async {
        var request = URLRequest(url: KokoroSettings.baseURL.appendingPathComponent("v1/audio/voices"))
        request.timeoutInterval = 6
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let list = try JSONDecoder().decode(VoiceList.self, from: data).voices.map(\.id).sorted()
            voices = list
            if !list.contains(kokoroVoice), let first = list.first(where: { $0 == "af_heart" }) ?? list.first { kokoroVoice = first }
            voicesNote = "\(list.count) voices on the Kokoro server. The Mac uses af_heart."
        } catch {
            voicesNote = "Couldn't list voices (\(error.localizedDescription)). Type a voice id, e.g. af_heart."
        }
    }
    @EnvironmentObject var client: CoreClient
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var kokoroURL = ""
    @State private var kokoroVoice = ""
    @State private var voices: [String] = []
    @State private var voicesNote = "Loading voices…"

    var body: some View {
        NavigationStack {
            Form {
                Section("Evergreen Core") {
                    TextField("http://192.168.4.200:3000", text: $text)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Koe only talks to this server. On the home Wi-Fi it is the think box; away from home use its Tailscale address.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let who = client.userEmail {
                    Section("Signed in as") { Text(who) }
                }
                Section("Kokoro voice") {
                    TextField("http://192.168.4.200:8880", text: $kokoroURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if voices.isEmpty {
                        TextField("af_heart", text: $kokoroVoice).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } else {
                        Picker("Voice", selection: $kokoroVoice) {
                            ForEach(voices, id: \.self) { Text(KokoroSettings.voiceName($0) + "  ·  " + $0).tag($0) }
                        }
                    }
                    Text(voicesNote).font(.footnote).foregroundStyle(.secondary)
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
                        let k = kokoroURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        if let u = URL(string: k), ["http", "https"].contains(u.scheme ?? ""), u.host != nil { KokoroSettings.baseURL = u }
                        let v = kokoroVoice.trimmingCharacters(in: .whitespaces)
                        if !v.isEmpty, v.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) { KokoroSettings.voice = v }
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .onAppear { text = client.baseURLString; kokoroURL = KokoroSettings.baseURL.absoluteString; kokoroVoice = KokoroSettings.voice }
            .task { await loadVoices() }
        }
    }
}
