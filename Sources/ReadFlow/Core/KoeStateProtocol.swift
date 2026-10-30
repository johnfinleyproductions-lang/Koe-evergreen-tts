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
    /// Documents that are dictionaries keyed by a stable id: merged entry by entry.
    static let dictionaryKeys: Set<String> = [highlights, positions]
    /// Stored as a UserDefaults dictionary rather than JSON Data.
    static let plistKeys: Set<String> = [positions]
    static let apiPath = "/api/reader/koe-state"
}

enum KoeStateLocal {
    private static var defaults: UserDefaults { .standard }

    /// The local document as a JSON value (array/dictionary), or nil when absent.
    static func value(forKey key: String) -> Any? {
        if KoeStateKeys.plistKeys.contains(key) { return defaults.dictionary(forKey: key) }
        guard let data = defaults.data(forKey: key), !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return json
    }

    /// Write a JSON value back exactly the way the owning store reads it.
    static func set(_ value: Any, forKey key: String) {
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
