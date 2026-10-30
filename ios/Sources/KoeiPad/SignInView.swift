import SwiftUI

/// Native magic-link sign-in. Core emails a link; it must be *pasted* into
/// Koe (a tap would sign Safari in, not Koe). Done once per iPad.
struct SignInView: View {
    @EnvironmentObject var client: CoreClient
    @State private var email = UserDefaults.standard.string(forKey: "koe.email") ?? ""
    @State private var link = ""
    @State private var sent = false
    @State private var busy = false
    @State private var message: String?
    @State private var showServer = false
    @FocusState private var focus: Field?
    enum Field { case email, link }

    var body: some View {
        ZStack {
            Koe.desk.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("声").font(Koe.serif(44, .semibold)).foregroundStyle(Koe.shu)
                        Text("Sign in to Evergreen").font(Koe.serif(28, .semibold)).foregroundStyle(Koe.ink)
                        Spacer()
                        Button { showServer = true } label: { Image(systemName: "server.rack") }.tint(Koe.ink2)
                    }
                    Text("Once. After this Koe keeps you signed in on this iPad.")
                        .font(Koe.serif(17)).foregroundStyle(Koe.ink2)

                    step(1, "Your Evergreen email")
                    HStack(spacing: 10) {
                        TextField("you@example.com", text: $email)
                            .textContentType(.emailAddress).keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focus, equals: .email)
                            .padding(12).background(Koe.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .submitLabel(.send).onSubmit { Task { await send() } }
                        Button { Task { await send() } } label: {
                            Text(sent ? "Send again" : "Email me a link").fontWeight(.semibold).padding(.horizontal, 6)
                        }
                        .buttonStyle(.borderedProminent).tint(Koe.shu)
                        .disabled(busy || !email.contains("@"))
                    }

                    step(2, "Open the email on this iPad, then copy the link")
                    Text("Long-press the **Sign in** button in the email and choose **Copy Link**. Don't tap it: tapping opens Safari, and Safari would get the session instead of Koe.")
                        .font(Koe.serif(16)).foregroundStyle(Koe.ink2)

                    step(3, "Paste it here")
                    HStack(spacing: 10) {
                        TextField("http://…/api/auth/magic-link/verify?token=…", text: $link)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .focused($focus, equals: .link)
                            .padding(12).background(Koe.paper, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .submitLabel(.go).onSubmit { Task { await finish(link) } }
                        PasteButton(payloadType: String.self) { strings in
                            if let s = strings.first { link = s; Task { await finish(s) } }
                        }
                        .labelStyle(.titleAndIcon).buttonBorderShape(.capsule).tint(Koe.ink)
                        Button { Task { await finish(link) } } label: { Text("Sign in").fontWeight(.semibold).padding(.horizontal, 6) }
                            .buttonStyle(.borderedProminent).tint(Koe.shu)
                            .disabled(busy || link.isEmpty)
                    }

                    if let message {
                        HStack(alignment: .top, spacing: 8) {
                            if busy { ProgressView().tint(Koe.shu) }
                            Text(message).font(Koe.serif(16)).foregroundStyle(message.hasPrefix("✓") ? Koe.green : Koe.shu)
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .sheet(isPresented: $showServer) { ServerSheet() }
        .onAppear { focus = email.isEmpty ? .email : nil }
    }

    private func step(_ n: Int, _ title: String) -> some View {
        HStack(spacing: 10) {
            Text(String(n)).font(.system(.footnote, design: .monospaced).weight(.bold))
                .frame(width: 24, height: 24).background(Koe.shu.opacity(0.14), in: Circle()).foregroundStyle(Koe.shu)
            Text(title).font(Koe.serif(19, .semibold)).foregroundStyle(Koe.ink)
        }
    }

    private func send() async {
        busy = true; message = "Asking Evergreen for a link…"
        defer { busy = false }
        do {
            try await client.requestMagicLink(email: email.trimmingCharacters(in: .whitespaces).lowercased())
            sent = true
            message = "✓ Sent. Check Mail on this iPad, copy the link, and paste it below."
            focus = .link
        } catch {
            message = error.localizedDescription
        }
    }

    private func finish(_ value: String) async {
        guard !value.isEmpty else { return }
        busy = true; message = "Signing in…"
        defer { busy = false }
        do {
            try await client.completeMagicLink(value)
            message = "✓ Signed in."
        } catch {
            message = error.localizedDescription
        }
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
