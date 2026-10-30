import Foundation

/// iPad half of the Phase 2 sync: pulls the Mac's Boards, Canvas, Library,
/// highlights and positions from Core's koe_state store on launch and
/// foreground, and pushes the two documents the iPad edits (highlights,
/// positions) after a change. Same protocol file as the Mac (Shared/).
@MainActor
final class StateSync: ObservableObject {
    @Published var lastPulled: Date?
    @Published var available = true          // false until Core has the store
    @Published var lastError: String?

    private let client: CoreClient
    private var pending: Set<String> = []
    private var pushTimer: Timer?
    private var observer: NSObjectProtocol?
    private var lastPull = Date.distantPast
    private var busy = false

    init(client: CoreClient) {
        self.client = client
        observer = NotificationCenter.default.addObserver(forName: .koeStateChanged, object: nil, queue: .main) { [weak self] note in
            guard let key = note.object as? String, KoeStateKeys.dictionaryKeys.contains(key) else { return }
            Task { @MainActor in self?.schedulePush(key) }
        }
    }

    private struct IndexEntry: Decodable { var key: String; var revision: Int }
    private struct IndexResponse: Decodable { var keys: [IndexEntry] }
    private struct Document: Decodable { var revision: Int; var value: AnyJSON }

    func pullAll(force: Bool = false) async {
        guard client.signedIn, force || Date().timeIntervalSince(lastPull) > 60, !busy else { return }
        busy = true; defer { busy = false }
        lastPull = Date()
        do {
            let index = try await client.rawJSON("GET", KoeStateKeys.apiPath)
            if index.status == 404 { available = false; return }
            guard index.status == 200 else { lastError = "Sync index HTTP \(index.status)"; return }
            available = true
            let entries = try JSONDecoder().decode(IndexResponse.self, from: index.data).keys
            for entry in entries where KoeStateKeys.all.contains(entry.key) && entry.revision != KoeStateLocal.revision(forKey: entry.key) {
                let reply = try await client.rawJSON("GET", KoeStateKeys.apiPath + "/" + entry.key)
                guard reply.status == 200, reply.data.count <= 2 * 1024 * 1024,
                      let doc = try? JSONDecoder().decode(Document.self, from: reply.data) else { continue }
                let local = KoeStateLocal.value(forKey: entry.key)
                let merged = KoeStateLocal.merge(local: local, remote: doc.value.value, key: entry.key)
                KoeStateLocal.set(merged, forKey: entry.key)
                KoeStateLocal.setRevision(doc.revision, forKey: entry.key)
                NotificationCenter.default.post(name: .koeStateDidPull, object: entry.key)
                if !KoeStateLocal.isEqual(merged, doc.value.value) { await push(entry.key, useBase: false) }
            }
            lastPulled = Date()
        } catch {
            lastError = error.localizedDescription
        }
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
        for key in keys { await push(key, useBase: true) }
    }

    private func push(_ key: String, useBase: Bool) async {
        guard client.signedIn, available, let value = KoeStateLocal.value(forKey: key) else { return }
        var body: [String: Any] = ["value": value, "device": "ipad"]
        if useBase, let base = KoeStateLocal.revision(forKey: key) { body["baseRevision"] = base }
        do {
            let reply = try await client.rawJSON("PUT", KoeStateKeys.apiPath + "/" + key, body: body)
            switch reply.status {
            case 200:
                if let saved = try? JSONDecoder().decode(IndexEntry.self, from: reply.data) { KoeStateLocal.setRevision(saved.revision, forKey: key) }
            case 409:
                guard let doc = try? JSONDecoder().decode(Document.self, from: reply.data) else { return }
                let merged = KoeStateLocal.merge(local: value, remote: doc.value.value, key: key)
                KoeStateLocal.set(merged, forKey: key)
                KoeStateLocal.setRevision(doc.revision, forKey: key)
                NotificationCenter.default.post(name: .koeStateDidPull, object: key)
                let again = try await client.rawJSON("PUT", KoeStateKeys.apiPath + "/" + key, body: ["value": merged, "device": "ipad"])
                if again.status == 200, let saved = try? JSONDecoder().decode(IndexEntry.self, from: again.data) { KoeStateLocal.setRevision(saved.revision, forKey: key) }
            case 404:
                available = false
            default:
                lastError = "Sync \(key): HTTP \(reply.status)"
            }
        } catch {
            lastError = error.localizedDescription
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
