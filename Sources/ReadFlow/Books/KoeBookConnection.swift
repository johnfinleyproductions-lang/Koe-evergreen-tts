import Foundation
import WebKit
import AppKit

struct KoeRemoteBookDetail: Decodable {
    struct Book: Decodable { var contentHash: String; var sourceSha256: String }
    struct Chapter: Decodable { var id: String; var status: String }
    struct Reading: Decodable { var id: String; var textHash: String; var audioUrl: String?; var durationSeconds: Double?; var tokens: [KoeBookToken] }
    var book: Book; var chapters: [Chapter]; var reading: Reading?
}

@MainActor
final class KoeBookConnection: NSObject, WKNavigationDelegate {
    private let session = URLSession(configuration: .ephemeral)
    private var loginWindow: NSWindow?
    private var webView: WKWebView?
    private var connectingBook: KoeBook?
    var onConnected: (() -> Void)?

    private func base(_ book: KoeBook) throws -> URL {
        let trusted = UserDefaults.standard.string(forKey: "readflow.books.coreURL") ?? "http://192.168.4.200:3000"
        guard let url = URL(string: book.coreURL), ["http", "https"].contains(url.scheme), url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == trusted.trimmingCharacters(in: CharacterSet(charactersIn: "/")) else { throw KoeBookError.unsafeURL }
        return url
    }
    private func endpoint(_ path: String, book: KoeBook) throws -> URL {
        let server = try base(book)
        guard path.hasPrefix("/api/reader/books/") || path.hasPrefix("/api/readings/"),
              !path.hasPrefix("//"), let url = URL(string: path, relativeTo: server)?.absoluteURL,
              url.host == server.host, url.port == server.port, url.scheme == server.scheme else { throw KoeBookError.unsafeURL }
        return url
    }
    private func useOwnSignInSession(for book: KoeBook) async throws {
        let server = try base(book)
        // Only this application's WebKit sign-in session is used. Never inspect
        // or import Safari/Chrome/browser-extension credentials.
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for cookie in session.configuration.httpCookieStorage?.cookies ?? [] where cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == server.host {
            session.configuration.httpCookieStorage?.deleteCookie(cookie)
        }
        for cookie in cookies where cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == server.host {
            session.configuration.httpCookieStorage?.setCookie(cookie)
        }
    }
    func metadata(_ book: KoeBook, chapter: String? = nil) async throws -> KoeRemoteBookDetail {
        try await useOwnSignInSession(for: book)
        let path = "/api/reader/books/" + book.id + "/native" + (chapter.map { "?chapter=" + $0 } ?? "")
        var request = URLRequest(url: try endpoint(path, book: book)); request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw KoeBookError.signIn }
        guard data.count <= 16 * 1024 * 1024 else { throw KoeBookError.tooLarge }
        return try JSONDecoder().decode(KoeRemoteBookDetail.self, from: data)
    }
    func download(path: String, book: KoeBook) async throws -> URL {
        try await useOwnSignInSession(for: book)
        var request = URLRequest(url: try endpoint(path, book: book)); request.timeoutInterval = 120
        let (file, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { try? FileManager.default.removeItem(at: file); throw KoeBookError.signIn }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 256 * 1024 * 1024, http.mimeType?.hasPrefix("audio/") == true else {
            try? FileManager.default.removeItem(at: file); throw KoeBookError.tooLarge
        }
        return file
    }
    func connect(_ book: KoeBook) throws {
            let server = try base(book)
            if let loginWindow { loginWindow.makeKeyAndOrderFront(nil); return }
            let browser = WKWebView(frame: .zero)
            browser.navigationDelegate = self
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Connect Koe to Evergreen"; window.isReleasedWhenClosed = false
            window.contentView = browser; window.center(); window.makeKeyAndOrderFront(nil)
            webView = browser; loginWindow = window
            connectingBook = book
            browser.load(URLRequest(url: server.appendingPathComponent("reader")))
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let book = connectingBook, webView.url?.host == URL(string: book.coreURL)?.host,
              webView.url?.path.hasPrefix("/auth") == false else { return }
        Task { @MainActor [weak self] in
            guard let self, (try? await self.metadata(book)) != nil else { return }
            self.loginWindow?.orderOut(nil); self.loginWindow = nil; self.webView = nil; self.connectingBook = nil
            self.onConnected?()
        }
    }
}
