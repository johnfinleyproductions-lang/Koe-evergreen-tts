//
//  ReadingHighlights.swift
//  ReadFlow / Koe
//
//  Durable, source-relative highlights for the text currently loaded in Koe.
//  Ranges use UTF-16 offsets because that is the coordinate space shared with
//  NSTextView, RTF, and AppKit attributed strings.
//

import Foundation

enum KoeHighlightColor: String, Codable, CaseIterable, Identifiable, Hashable {
    case yellow
    case green
    case pink
    case blue

    var id: String { rawValue }

    var label: String {
        switch self {
        case .yellow: return "Yellow"
        case .green:  return "Green"
        case .pink:   return "Pink"
        case .blue:   return "Blue"
        }
    }
}

struct KoeTextHighlight: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let location: Int
    let length: Int
    let color: KoeHighlightColor

    init(id: UUID = UUID(), range: NSRange, color: KoeHighlightColor) {
        self.id = id
        self.location = range.location
        self.length = range.length
        self.color = color
    }

    var range: NSRange { NSRange(location: location, length: length) }
    var upperBound: Int { location + length }
}

enum KoeHighlightOperations {
    static func applying(
        color: KoeHighlightColor?,
        to selection: NSRange,
        in existing: [KoeTextHighlight],
        textLength: Int
    ) -> [KoeTextHighlight] {
        guard let selected = clamped(selection, to: textLength), selected.length > 0 else {
            return sanitized(existing, textLength: textLength)
        }

        var next: [KoeTextHighlight] = []
        for highlight in sanitized(existing, textLength: textLength) {
            let overlap = NSIntersectionRange(highlight.range, selected)
            guard overlap.length > 0 else {
                next.append(highlight)
                continue
            }

            if highlight.location < selected.location {
                next.append(KoeTextHighlight(
                    range: NSRange(
                        location: highlight.location,
                        length: selected.location - highlight.location
                    ),
                    color: highlight.color
                ))
            }

            if highlight.upperBound > NSMaxRange(selected) {
                next.append(KoeTextHighlight(
                    range: NSRange(
                        location: NSMaxRange(selected),
                        length: highlight.upperBound - NSMaxRange(selected)
                    ),
                    color: highlight.color
                ))
            }
        }

        if let color {
            next.append(KoeTextHighlight(range: selected, color: color))
        }
        return merged(next, textLength: textLength)
    }

    static func sanitized(_ highlights: [KoeTextHighlight], textLength: Int) -> [KoeTextHighlight] {
        merged(
            highlights.compactMap { highlight in
                guard let range = clamped(highlight.range, to: textLength), range.length > 0 else {
                    return nil
                }
                return KoeTextHighlight(id: highlight.id, range: range, color: highlight.color)
            },
            textLength: textLength
        )
    }

    private static func clamped(_ range: NSRange, to textLength: Int) -> NSRange? {
        guard range.location != NSNotFound, range.location >= 0, textLength >= 0 else { return nil }
        let start = min(range.location, textLength)
        let end = min(max(range.location, NSMaxRange(range)), textLength)
        guard end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private static func merged(_ highlights: [KoeTextHighlight], textLength: Int) -> [KoeTextHighlight] {
        let ordered = highlights
            .filter { $0.length > 0 && $0.location >= 0 && $0.upperBound <= textLength }
            .sorted {
                if $0.location == $1.location { return $0.length < $1.length }
                return $0.location < $1.location
            }

        var result: [KoeTextHighlight] = []
        for highlight in ordered {
            if let last = result.last,
               last.color == highlight.color,
               highlight.location <= last.upperBound {
                result.removeLast()
                let end = max(last.upperBound, highlight.upperBound)
                result.append(KoeTextHighlight(
                    id: last.id,
                    range: NSRange(location: last.location, length: end - last.location),
                    color: last.color
                ))
            } else {
                result.append(highlight)
            }
        }
        return result
    }
}

enum KoeHighlightStore {
    private static let defaultsKey = "readflow.readingHighlights.v1"

    static func documentID(for text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        var byteCount = 0
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
            byteCount += 1
        }
        return String(format: "%016llx-%d", hash, byteCount)
    }

    static func load(documentID: String, textLength: Int) -> [KoeTextHighlight] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let archive = try? JSONDecoder().decode([String: [KoeTextHighlight]].self, from: data)
        else { return [] }
        return KoeHighlightOperations.sanitized(archive[documentID] ?? [], textLength: textLength)
    }

    static func save(_ highlights: [KoeTextHighlight], documentID: String, textLength: Int) {
        var archive: [String: [KoeTextHighlight]] = [:]
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: [KoeTextHighlight]].self, from: data) {
            archive = decoded
        }

        let clean = KoeHighlightOperations.sanitized(highlights, textLength: textLength)
        if clean.isEmpty { archive.removeValue(forKey: documentID) }
        else { archive[documentID] = clean }

        if let data = try? JSONEncoder().encode(archive) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
