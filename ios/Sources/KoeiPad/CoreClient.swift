import Foundation
import WebKit

/// Talks to Evergreen Core as Tyler, with a session cookie Koe owns outright:
/// the magic-link sign-in happens inside the app, the cookie lives in the
/// app's persistent jar, and every launch refreshes it so it never lapses.
/// Only the book, reading and auth routes are allowed, only on the configured server.
@MainActor
final class CoreClient: ObservableObject {
    @Published var baseURLString: String {
        didSet { UserDefaults.standard.set(baseURLString, forKey: "koe.coreURL") }
    }
    @Published var signedIn = false { didSet { UserDefaults.standard.set(signedIn, forKey: "koe.signedIn") } }
    @Published var userEmail: String?
    @Published var lastError: String?
    /// True after a screen was served from the offline copy because Evergreen didn't answer.
    @Published var servedOffline = false

    private let session: URLSession

    init() {
        baseURLString = UserDefaults.standard.string(forKey: "koe.coreURL") ?? "http://192.168.4.200:3000"
        let config = URLSessionConfiguration.default      // HTTPCookieStorage.shared: persists across launches
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        session = URLSession(configuration: config)
    }

    var baseURL: URL { URL(string: baseURLString) ?? URL(string: "http://192.168.4.200:3000")! }
    var origin: String {
        var s = "\(baseURL.scheme ?? "http")://\(baseURL.host ?? "")"
        if let port = baseURL.port { s += ":\(port)" }
        return s
    }

    private static let allowedPrefixes = ["/api/reader/books", "/api/reader/koe-state", "/api/readings/", "/api/auth/get-session",
                                          "/api/auth/sign-in/magic-link", "/api/auth/magic-link/verify"]

    private func endpoint(_ path: String) throws -> URL {
        guard Self.allowedPrefixes.contains(where: { path.hasPrefix($0) }), !path.hasPrefix("//"),
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.host == baseURL.host, url.port == baseURL.port, url.scheme == baseURL.scheme else {
            throw KoeError.unsafeURL
        }
        return url
    }

    // MARK: Session

    private struct SessionEnvelope: Decodable {
        struct User: Decodable { var email: String? }
        var user: User?
    }

    /// Better Auth extends a session that is being used; calling this on every
    /// launch and foreground keeps Tyler signed in indefinitely.
    @discardableResult
    func refreshSession() async -> Bool {
        do {
            var request = URLRequest(url: try endpoint("/api/auth/get-session"))
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let envelope = try? JSONDecoder().decode(SessionEnvelope?.self, from: data), let user = envelope.user else {
                signedIn = false; userEmail = nil
                return false
            }
            userEmail = user.email
            signedIn = true
            return true
        } catch {
            // Offline or server down: trust the last known state so cached books still open.
            let remembered = UserDefaults.standard.bool(forKey: "koe.signedIn")
            if remembered { signedIn = true; servedOffline = true }
            return signedIn
        }
    }

    func requestMagicLink(email: String) async throws {
        var request = URLRequest(url: try endpoint("/api/auth/sign-in/magic-link"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "callbackURL": "/reader"])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw KoeError.network("No response from Evergreen.") }
        guard http.statusCode == 200 else {
            if http.statusCode >= 500 {
                throw KoeError.network("Evergreen can't send email right now (no email provider is configured on the server). Use the web sign-in above instead.")
            }
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw KoeError.network(message ?? "Evergreen answered HTTP \(http.statusCode).")
        }
        UserDefaults.standard.set(email, forKey: "koe.email")
    }

    /// The link from the email, pasted rather than tapped, so the cookie lands
    /// in Koe's jar instead of Safari's.
    func completeMagicLink(_ link: String) async throws {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              url.scheme == baseURL.scheme, url.host == baseURL.host, url.port == baseURL.port,
              url.path == "/api/auth/magic-link/verify",
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value, !token.isEmpty else {
            throw KoeError.network("That isn't a sign-in link from your Evergreen server.")
        }
        var request = URLRequest(url: url)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        // Stop at the redirect: the Set-Cookie rides on that response.
        let (_, response) = try await session.data(for: request, delegate: NoRedirect())
        guard let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) else {
            throw KoeError.network("Evergreen refused the link. Links are single-use and expire; send a fresh one.")
        }
        guard await refreshSession() else {
            throw KoeError.network("The link was accepted but no session came back. Send a fresh link and paste it again.")
        }
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// After a web sign-in (Google on Core's login page), copy the session
    /// cookies from the web view's jar into the app's own persistent jar so
    /// every later request, and the launch-time refresh, carry them.
    func adoptWebCookies() async -> Bool {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let host = baseURL.host ?? ""
        var adopted = 0
        for cookie in cookies where cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host {
            HTTPCookieStorage.shared.setCookie(cookie)
            adopted += 1
        }
        guard adopted > 0 else { return false }
        return await refreshSession()
    }

    func signOut() async {
        let jar = HTTPCookieStorage.shared
        for cookie in jar.cookies ?? [] where cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == baseURL.host {
            jar.deleteCookie(cookie)
        }
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        signedIn = false
        userEmail = nil
    }

    // MARK: Requests

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        var request = URLRequest(url: try endpoint(path))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw KoeError.network("No response from Evergreen.") }
        if http.statusCode == 401 { signedIn = false; throw KoeError.signIn }
        guard http.statusCode == 200 else { throw KoeError.http(http.statusCode) }
        guard data.count <= 32 * 1024 * 1024 else { throw KoeError.tooLarge }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Raw JSON (koe-state sync)

    struct RawReply { let status: Int; let data: Data }

    func rawJSON(_ method: String, _ path: String, body: Any? = nil) async throws -> RawReply {
        var request = URLRequest(url: try endpoint(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            guard JSONSerialization.isValidJSONObject(body) else { throw KoeError.network("Bad JSON body") }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw KoeError.network("No response from Evergreen.") }
        if http.statusCode == 401 { signedIn = false; throw KoeError.signIn }
        return RawReply(status: http.statusCode, data: data)
    }

    // MARK: Books (live, with an offline copy of every JSON answer)

    /// Fetch live and keep a copy; when Evergreen doesn't answer, serve the copy.
    private func getKeepingCopy<T: Decodable>(_ path: String, copy name: String, as type: T.Type) async throws -> T {
        let file = Self.cacheRoot.appendingPathComponent(name)
        var request = URLRequest(url: try endpoint(path))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw KoeError.network("No response from Evergreen.") }
            if http.statusCode == 401 { signedIn = false; throw KoeError.signIn }
            guard http.statusCode == 200 else { throw KoeError.http(http.statusCode) }
            guard data.count <= 32 * 1024 * 1024 else { throw KoeError.tooLarge }
            let decoded = try JSONDecoder().decode(T.self, from: data)
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            servedOffline = false
            return decoded
        } catch let error as URLError {
            guard let data = try? Data(contentsOf: file), let decoded = try? JSONDecoder().decode(T.self, from: data) else { throw error }
            servedOffline = true
            return decoded
        }
    }

    func listBooks() async throws -> [BookSummary] {
        let library = try await getKeepingCopy("/api/reader/books/native", copy: "library.json", as: LibraryResponse.self)
        signedIn = true
        return library.books
    }

    func book(_ id: String) async throws -> BookDetailResponse {
        try await getKeepingCopy("/api/reader/books/\(id)/native", copy: "books/\(id)/detail.json", as: BookDetailResponse.self)
    }

    func chapter(bookId: String, chapterId: String) async throws -> BookDetailResponse {
        try await getKeepingCopy("/api/reader/books/\(bookId)/native?chapter=\(chapterId)", copy: "books/\(bookId)/chapters/\(chapterId).json", as: BookDetailResponse.self)
    }

    func hasCopy(_ name: String) -> Bool { FileManager.default.fileExists(atPath: Self.cacheRoot.appendingPathComponent(name).path) }

    /// Core checks Origin against Host on book writes; a native app sends none,
    /// so we send our own server's origin.
    func saveProgress(bookId: String, chapterId: String, seconds: Double) async {
        do {
            var request = URLRequest(url: try endpoint("/api/reader/books/\(bookId)/progress"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(origin, forHTTPHeaderField: "Origin")
            let body: [String: Any] = ["chapterId": chapterId, "seconds": max(0, seconds),
                                       "observedAt": ISO8601DateFormatter().string(from: Date())]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 300 {
                lastError = "Progress not saved to Evergreen (HTTP \(http.statusCode))."
            }
        } catch {
            lastError = "Progress not saved to Evergreen: \(error.localizedDescription)"
        }
    }

    // MARK: Files (PDF, audio) cached under Caches/koe

    /// Application Support, not Caches: kept books must survive iPadOS cache purges.
    /// Excluded from backup; everything here is re-downloadable from Evergreen.
    static var cacheRoot: URL {
        var base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Koe/cache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: base.path) {
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? base.setResourceValues(values)
        }
        return base
    }

    /// Download once, then serve from the cache. `name` is the cache-relative path.
    func cachedFile(path: String, name: String, mimePrefix: String, maxBytes: Int) async throws -> URL {
        let target = Self.cacheRoot.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        var request = URLRequest(url: try endpoint(path))
        request.timeoutInterval = 300
        let (tmp, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse else { try? FileManager.default.removeItem(at: tmp); throw KoeError.network("No response from Evergreen.") }
        if http.statusCode == 401 { try? FileManager.default.removeItem(at: tmp); signedIn = false; throw KoeError.signIn }
        guard http.statusCode == 200 else { try? FileManager.default.removeItem(at: tmp); throw KoeError.http(http.statusCode) }
        let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= maxBytes, (http.mimeType ?? "").hasPrefix(mimePrefix) else {
            try? FileManager.default.removeItem(at: tmp); throw KoeError.tooLarge
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: tmp, to: target)
        return target
    }
}
