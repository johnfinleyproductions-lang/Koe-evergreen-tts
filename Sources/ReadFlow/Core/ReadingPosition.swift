//
//  ReadingPosition.swift
//  ReadFlow / Koe
//
//  Persists the furthest word index reached per DOCUMENT so long PDFs and web
//  articles resume where you left off. Keyed by a STABLE content hash (not the
//  source name), so the same text resumes however it was opened. A document's
//  entry is cleared once it's read to the end.
//

import Foundation

enum ReadingPositionStore {
    private static let key = "readflow.readingPositions"   // [contentHash: wordIndex]
    private static let maxEntries = 300

    /// Deterministic content id. Swift's `Hasher` is per-run randomized, so we use
    /// a stable djb2 over the UTF-8 bytes instead.
    static func contentHash(_ text: String) -> String {
        var h: UInt64 = 5381
        for byte in text.utf8 { h = (h &* 33) ^ UInt64(byte) }
        return String(h, radix: 16)
    }

    /// The saved word index for `text`, if any.
    static func position(for text: String) -> Int? {
        let dict = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        return dict[contentHash(text)]
    }

    /// Record the furthest word reached for `text`.
    static func save(_ index: Int, for text: String) {
        var dict = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        // Crude bound so the store can't grow forever; positions are cheap to lose.
        if dict.count > maxEntries { dict = [:] }
        dict[contentHash(text)] = index
        UserDefaults.standard.set(dict, forKey: key)
        NotificationCenter.default.post(name: .koeStateChanged, object: key)
    }

    /// Forget `text`'s position (called when it's read to the end).
    static func clear(for text: String) {
        var dict = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
        dict.removeValue(forKey: contentHash(text))
        UserDefaults.standard.set(dict, forKey: key)
        NotificationCenter.default.post(name: .koeStateChanged, object: key)
    }
}
