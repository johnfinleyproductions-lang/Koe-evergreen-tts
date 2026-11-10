//
//  KoeStateProtocol.swift
//  ReadFlow / Koe — shared by the Mac app and the iPad companion (symlinked).
//
//  What the two apps sync through Evergreen Core's koe_state store, how each
//  document is kept locally, and how a remote copy merges in. The transport
//  (cookies, URLSession) lives in each app; this file is Foundation only.
//
import Foundation

extension Notification.Name {
    /// Posted by the stores after a local save. `object` = the UserDefaults key.
    static let koeStateChanged = Notification.Name("koe.stateChanged")
    /// Posted by the sync after a remote document was written locally. `object` = key.
    static let koeStateDidPull = Notification.Name("koe.stateDidPull")
}

enum KoeStateKeys {
    static let boards = "readflow.boards"
    static let canvasNotes = "readflow.canvasNotes"
    static let canvasLinks = "readflow.canvasLinks"
    static let notebooks = "readflow.notebooks"
    static let libraryPulled = "readflow.libraryPulled"
    static let highlights = "readflow.readingHighlights.v1"
    static let positions = "readflow.readingPositions"
    static let all = [boards, canvasNotes, canvasLinks, notebooks, libraryPulled, highlights, positions]
    /// One document per Pencil sketch on the Idea Canvas: `canvasInk.<note id>`.
    /// Kept out of `canvasNotes` so a dozen drawings never push that document past the 1 MB cap.
    static let inkPrefix = "canvasInk."
    static func inkKey(for noteId: UUID) -> String { inkPrefix + noteId.uuidString.lowercased() }
    static func isInk(_ key: String) -> Bool { key.hasPrefix(inkPrefix) && key.count > inkPrefix.count }
    /// Every key the sync will pull or push.
    static func isSynced(_ key: String) -> Bool { all.contains(key) || isInk(key) }
    /// Documents that are dictionaries keyed by a stable id: merged entry by entry.
    static let dictionaryKeys: Set<String> = [highlights, positions]
    /// Stored as a UserDefaults dictionary rather than JSON Data.
    static let plistKeys: Set<String> = [positions]
    static let apiPath = "/api/reader/koe-state"
}

enum KoeStateLocal {
    private static var defaults: UserDefaults { .standard }

    // Ink documents are files, not UserDefaults: Application Support/Koe/canvas-ink/<key>.json
    private static var inkDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Koe/canvas-ink", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func inkURL(_ key: String) -> URL { inkDir.appendingPathComponent(key + ".json") }
    /// Ink keys this device has on disk.
    static func localInkKeys() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: inkDir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.filter(KoeStateKeys.isInk)
    }
    /// Forget a document (and its revision) locally. Used after a sketch is deleted here or elsewhere.
    static func remove(forKey key: String) {
        if KoeStateKeys.isInk(key) { try? FileManager.default.removeItem(at: inkURL(key)) } else { defaults.removeObject(forKey: key) }
        defaults.removeObject(forKey: "koe.sync.revision." + key)
    }

    /// The local document as a JSON value (array/dictionary), or nil when absent.
    static func value(forKey key: String) -> Any? {
        if KoeStateKeys.isInk(key) {
            guard let data = try? Data(contentsOf: inkURL(key)), let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
            return json
        }
        if KoeStateKeys.plistKeys.contains(key) { return defaults.dictionary(forKey: key) }
        guard let data = defaults.data(forKey: key), !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return json
    }

    /// Write a JSON value back exactly the way the owning store reads it.
    static func set(_ value: Any, forKey key: String) {
        if KoeStateKeys.isInk(key) {
            guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return }
            try? data.write(to: inkURL(key), options: .atomic)
            return
        }
        if KoeStateKeys.plistKeys.contains(key) {
            if let dict = value as? [String: Any] { defaults.set(dict, forKey: key) }
            return
        }
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        defaults.set(data, forKey: key)
    }

    static func revision(forKey key: String) -> Int? {
        let v = defaults.integer(forKey: "koe.sync.revision." + key)
        return v > 0 ? v : nil
    }
    static func setRevision(_ revision: Int, forKey key: String) {
        defaults.set(revision, forKey: "koe.sync.revision." + key)
    }

    /// Dictionary documents: remote entries, overlaid by the local ones (this
    /// device's edits win for the entries it touched). Boards: union by id,
    /// items union by id (both devices append). Everything else: remote.
    static func merge(local: Any?, remote: Any, key: String) -> Any {
        if key == KoeStateKeys.boards, let r = remote as? [[String: Any]] {
            guard let l = local as? [[String: Any]] else { return r }
            return mergeBoards(local: l, remote: r)
        }
        // Canvas cards: both devices add cards now (the iPad sketches, the Mac types).
        // Union by id in remote order, local-only cards appended; a card both touched takes the remote copy.
        if key == KoeStateKeys.canvasNotes, let r = remote as? [[String: Any]] {
            guard let l = local as? [[String: Any]] else { return r }
            func id(_ o: [String: Any]) -> String? { (o["id"] as? String)?.lowercased() }
            let seen = Set(r.compactMap(id))
            return r + l.filter { !(id($0).map(seen.contains) ?? true) }
        }
        guard KoeStateKeys.dictionaryKeys.contains(key),
              let r = remote as? [String: Any] else { return remote }
        guard let l = local as? [String: Any] else { return r }
        var out = r
        for (k, v) in l { out[k] = v }
        return out
    }

    /// Remote boards in remote order, each with local-only items appended;
    /// local-only boards appended at the end. Field names are the Mac's Board/BoardItem.
    static func mergeBoards(local: [[String: Any]], remote: [[String: Any]]) -> [[String: Any]] {
        func id(_ o: [String: Any]) -> String? { (o["id"] as? String)?.lowercased() }
        var out: [[String: Any]] = []
        for var board in remote {
            guard let bid = id(board) else { out.append(board); continue }
            if let mine = local.first(where: { id($0) == bid }) {
                var items = board["items"] as? [[String: Any]] ?? []
                let known = Set(items.compactMap(id))
                for item in (mine["items"] as? [[String: Any]] ?? []) where !(id(item).map(known.contains) ?? true) { items.append(item) }
                board["items"] = items
            }
            out.append(board)
        }
        let seen = Set(out.compactMap(id))
        for board in local where !(id(board).map(seen.contains) ?? true) { out.append(board) }
        return out
    }

    static func isEqual(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b, JSONSerialization.isValidJSONObject(a), JSONSerialization.isValidJSONObject(b),
              let da = try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys]),
              let db = try? JSONSerialization.data(withJSONObject: b, options: [.sortedKeys]) else { return false }
        return da == db
    }
}

/// The sketch document behind an ink card. Foundation only; each app turns the
/// bytes into its own image type. `drawing` is PencilKit's PKDrawing data (vector,
/// re-editable on the iPad); `preview` is a JPEG both apps can show at once.
enum KoeCanvasInk {
    /// Core refuses documents over 1 MB; leave headroom for the JSON envelope.
    static let maxDocumentBytes = 950_000

    static func document(id: UUID, width: Double, height: Double, drawing: Data, preview: Data) -> [String: Any] {
        ["id": id.uuidString.lowercased(), "w": width, "h": height,
         "drawing": drawing.base64EncodedString(), "preview": preview.base64EncodedString(),
         "updated": ISO8601DateFormatter().string(from: Date())]
    }
    static func encodedSize(_ doc: [String: Any]) -> Int {
        (try? JSONSerialization.data(withJSONObject: doc))?.count ?? Int.max
    }
    static func drawing(in doc: Any?) -> Data? { data(doc, "drawing") }
    static func preview(in doc: Any?) -> Data? { data(doc, "preview") }
    static func size(in doc: Any?) -> (width: Double, height: Double)? {
        guard let d = doc as? [String: Any], let w = d["w"] as? Double, let h = d["h"] as? Double, w > 0, h > 0 else { return nil }
        return (w, h)
    }
    private static func data(_ doc: Any?, _ field: String) -> Data? {
        guard let d = doc as? [String: Any], let s = d[field] as? String, !s.isEmpty else { return nil }
        return Data(base64Encoded: s)
    }
}
