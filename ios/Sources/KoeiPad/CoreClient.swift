import Foundation
import WebKit

/// Talks to Evergreen Core with Koe's own sign-in session (the WKWebView
/// cookie jar), exactly like the Mac app's KoeBookConnection. Only the book
/// and reading routes are allowed, only on the configured server.
@MainActor
final class CoreClient: ObservableObject {
    @Published var baseURLString: String {
        didSet { UserDefaults.standard.set(baseURLString, forKey: "koe.coreURL") }
    }
    @Published var signedIn = false
    @Published var lastError: String?

    private let session: URLSession

    init() {
        baseURLString = UserDefaults.standard.string(forKey: "koe.coreURL") ?? "http://192.168.4.200:3000"
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.httpCookieAcceptPolicy = .always
        session = URLSession(configuration: config)
    }

    var baseURL: URL { URL(string: baseURLString) ?? URL(string: "http://192.168.4.200:3000")! }
    var origin: String {
        var s = "\(baseURL.scheme ?? "http")://\(baseURL.host ?? "")"
        if let port = baseURL.port { s += ":\(port)" }
        return s
    }

    // MARK: Session

    /// Copy the sign-in cookies from the web view's jar into our URLSession.
    func syncCookies() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let host = baseURL.host ?? ""
        let storage = session.configuration.httpCookieStorage
        storage?.cookies?.forEach { storage?.deleteCookie($0) }
        for cookie in cookies where cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host {
            storage?.setCookie(cookie)
        }
    }

    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        session.configuration.httpCookieStorage?.cookies?.forEach { session.configuration.httpCookieStorage?.deleteCookie($0) }
        signedIn = false
    }

    private func endpoint(_ path: String) throws -> URL {
        guard path.hasPrefix("/api/reader/books") || path.hasPrefix("/api/readings/"), !path.hasPrefix("//"),
              let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.host == baseURL.host, url.port == baseURL.port, url.scheme == baseURL.scheme else {
            throw KoeError.unsafeURL
        }
        return url
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        await syncCookies()
        var request = URLRequest(url: try endpoint(path))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw KoeError.network("No response from Evergreen.") }
        if http.statusCode == 401 { signedIn = false; throw KoeError.signIn }
        guard http.statusCode == 200 else { throw KoeError.http(http.statusCode) }
        guard data.count <= 32 * 1024 * 1024 else { throw KoeError.tooLarge }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Books

    func listBooks() async throws -> [BookSummary] {
        let library = try await get("/api/reader/books/native", as: LibraryResponse.self)
        signedIn = true
        return library.books
    }

    func book(_ id: String) async throws -> BookDetailResponse {
        try await get("/api/reader/books/\(id)/native", as: BookDetailResponse.self)
    }

    func chapter(bookId: String, chapterId: String) async throws -> BookDetailResponse {
        try await get("/api/reader/books/\(bookId)/native?chapter=\(chapterId)", as: BookDetailResponse.self)
    }

    /// Core checks Origin against Host on book writes; a native app sends none,
    /// so we send our own server's origin.
    func saveProgress(bookId: String, chapterId: String, seconds: Double) async {
        do {
            await syncCookies()
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

    static var cacheRoot: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("koe", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Download once, then serve from the cache. `name` is the cache-relative path.
    func cachedFile(path: String, name: String, mimePrefix: String, maxBytes: Int) async throws -> URL {
        let target = Self.cacheRoot.appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        await syncCookies()
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
