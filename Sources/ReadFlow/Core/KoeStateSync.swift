//
//  KoeStateSync.swift
//  Koe (Mac) — pushes Boards, Canvas, Library, highlights and positions to
//  Evergreen Core's koe_state store and pulls what other devices wrote.
//
//  Transport: Koe's own WebKit sign-in session (the same cookies the Books
//  connection uses). Silent when signed out or when the store isn't deployed.
//
import Foundation
import WebKit
import os

@MainActor
final class KoeStateSync {
    static let shared = KoeStateSync()
    private let session: URLSession
    private var pending: Set<String> = []
    private var pushTimer: Timer?
    private var lastPull = Date.distantPast
    private var observer: NSObjectProtocol?
    private var busy = false
    private(set) var lastError: String?
    private let log = Logger(subsystem: "com.readflow.app", category: "sync")

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    var baseURL: URL {
        URL(string: UserDefaults.standard.string(forKey: "readflow.books.coreURL") ?? "") ?? URL(string: "http://192.168.4.200:3000")!
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .koeStateChanged, object: nil, queue: .main) { [weak self] note in
            guard let key = note.object as? String, KoeStateKeys.all.contains(key) else { return }
            Task { @MainActor in self?.schedulePush(key) }
        }
        Task { await pullAll() }
    }

    func schedulePush(_ key: String) {
        pending.insert(key)
        pushTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: false) { [weak self] _ in Task { @MainActor in await self?.flush() } }
        RunLoop.main.add(timer, forMode: .common)
        pushTimer = timer
    }

    func flush() async {
        let keys = pending; pending = []
        for key in keys { await push(key) }
    }

    /// Pull every document another device has moved past our revision.
    /// Returns true when the server answered the index (= this Mac is signed in).
    @discardableResult
    func pullAll(force: Bool = false) async -> Bool {
        guard force || Date().timeIntervalSince(lastPull) > 60, !busy else { return false }
        busy = true; defer { busy = false }
        lastPull = Date()
        guard let index = await getIndex() else { return false }
        for entry in index where KoeStateKeys.all.contains(entry.key) && entry.revision != KoeStateLocal.revision(forKey: entry.key) {
            guard let doc = await getDocument(entry.key) else { continue }
            let local = KoeStateLocal.value(forKey: entry.key)
            let merged = KoeStateLocal.merge(local: local, remote: doc.value, key: entry.key)
            KoeStateLocal.set(merged, forKey: entry.key)
            KoeStateLocal.setRevision(doc.revision, forKey: entry.key)
            reload(entry.key)
            // Our overlay changed the merged document: publish it, last writer wins.
            if !KoeStateLocal.isEqual(merged, doc.value) { await push(entry.key, base: nil) }
        }
        // Seed: documents this Mac holds that the server has never seen (first sync, or a
        // key added since). Without this, boards made before the store existed never leave.
        let remoteKeys = Set(index.map(\.key))
        for key in KoeStateKeys.all where !remoteKeys.contains(key) && KoeStateLocal.value(forKey: key) != nil {
            log.notice("seed \(key, privacy: .public)")
            await push(key, base: .some(nil))
        }
        return true
    }

    func note(_ message: String) { log.notice("\(message, privacy: .public)") }

    private func push(_ key: String, base: Int?? = nil) async {
        guard let value = KoeStateLocal.value(forKey: key) else { return }
        let baseRevision: Int? = base == nil ? KoeStateLocal.revision(forKey: key) : base!
        switch await put(key, value: value, baseRevision: baseRevision) {
        case .saved(let revision):
            KoeStateLocal.setRevision(revision, forKey: key)
        case .conflict(let remoteRevision, let remoteValue):
            let merged = KoeStateLocal.merge(local: value, remote: remoteValue, key: key)
            KoeStateLocal.set(merged, forKey: key)
            KoeStateLocal.setRevision(remoteRevision, forKey: key)
            reload(key)
            if case .saved(let revision) = await put(key, value: merged, baseRevision: nil) {
                KoeStateLocal.setRevision(revision, forKey: key)
            }
        case .unavailable:
            break
        }
    }

    private func reload(_ key: String) {
        switch key {
        case KoeStateKeys.boards: BoardStore.shared.load()
        case KoeStateKeys.canvasNotes, KoeStateKeys.canvasLinks: CanvasStore.shared.load()
        case KoeStateKeys.notebooks, KoeStateKeys.libraryPulled: LibraryStore.shared.load()
        default: break
        }
        NotificationCenter.default.post(name: .koeStateDidPull, object: key)
    }

    // MARK: Transport

    private struct IndexEntry: Decodable { var key: String; var revision: Int }
    private struct IndexResponse: Decodable { var keys: [IndexEntry] }
    private struct Document: Decodable { var revision: Int; var value: AnyJSON }
    private enum PutResult { case saved(Int), conflict(Int, Any), unavailable }

    private func useOwnSignInSession() async {
        let host = baseURL.host ?? ""
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let storage = session.configuration.httpCookieStorage
        storage?.cookies?.forEach { storage?.deleteCookie($0) }
        for cookie in cookies where cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host { storage?.setCookie(cookie) }
    }

    private func endpoint(_ key: String?) -> URL? {
        var path = KoeStateKeys.apiPath
        if let key { path += "/" + key }
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL, url.host == baseURL.host, url.port == baseURL.port else { return nil }
        return url
    }

    private var origin: String {
        var s = "\(baseURL.scheme ?? "http")://\(baseURL.host ?? "")"
        if let port = baseURL.port { s += ":\(port)" }
        return s
    }

    private func getIndex() async -> [IndexEntry]? {
        guard let url = endpoint(nil) else { return nil }
        await useOwnSignInSession()
        var request = URLRequest(url: url); request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { log.notice("index: no reply"); return nil }
        log.notice("index: HTTP \(http.statusCode, privacy: .public)")
        guard http.statusCode == 200 else { lastError = "koe-state index: HTTP \(http.statusCode)"; return nil }
        return try? JSONDecoder().decode(IndexResponse.self, from: data).keys
    }

    private func getDocument(_ key: String) async -> (revision: Int, value: Any)? {
        guard let url = endpoint(key) else { return nil }
        await useOwnSignInSession()
        var request = URLRequest(url: url); request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 2 * 1024 * 1024, let doc = try? JSONDecoder().decode(Document.self, from: data) else { return nil }
        return (doc.revision, doc.value.value)
    }

    private func put(_ key: String, value: Any, baseRevision: Int?) async -> PutResult {
        guard let url = endpoint(key) else { return .unavailable }
        await useOwnSignInSession()
        var body: [String: Any] = ["value": value, "device": "mac"]
        if let baseRevision { body["baseRevision"] = baseRevision }
        guard JSONSerialization.isValidJSONObject(body), let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 1_050_000 else { return .unavailable }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(origin, forHTTPHeaderField: "Origin")
        guard let (reply, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return .unavailable }
        switch http.statusCode {
        case 200:
            guard let doc = try? JSONDecoder().decode(IndexEntry.self, from: reply) else { log.notice("put \(key, privacy: .public): bad reply"); return .unavailable }
            log.notice("put \(key, privacy: .public): saved rev \(doc.revision, privacy: .public)")
            return .saved(doc.revision)
        case 409:
            guard let doc = try? JSONDecoder().decode(Document.self, from: reply) else { return .unavailable }
            return .conflict(doc.revision, doc.value.value)
        default:
            lastError = "koe-state \(key): HTTP \(http.statusCode)"
            log.notice("put \(key, privacy: .public): HTTP \(http.statusCode, privacy: .public)")
            return .unavailable
        }
    }
}

/// Decodes any JSON value into Foundation objects (what JSONSerialization produces).
struct AnyJSON: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = NSNull(); return }
        if let b = try? c.decode(Bool.self) { value = b; return }
        if let i = try? c.decode(Int.self) { value = i; return }
        if let d = try? c.decode(Double.self) { value = d; return }
        if let s = try? c.decode(String.self) { value = s; return }
        if let a = try? c.decode([AnyJSON].self) { value = a.map(\.value); return }
        if let o = try? c.decode([String: AnyJSON].self) { value = o.mapValues(\.value); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON")
    }
}
