import Foundation
import CryptoKit

struct KoeBook: Codable, Identifiable, Sendable {
    var schema: String = "koe-native-book/1"
    var id: String
    var title: String
    var author: String
    var contentHash: String
    var sourceSha256: String
    var pageCount: Int
    var coreURL: String
    var reviewPolicy: String
    var chapters: [KoeBookChapter]

    func validate() throws {
        guard schema == "koe-native-book/1", UUID(uuidString: id) != nil,
              (1...2000).contains(pageCount), !title.isEmpty, title.count <= 500,
              Self.isHash(sourceSha256), Self.isHash(contentHash),
              (1...500).contains(chapters.count),
              Set(chapters.map(\.id)).count == chapters.count,
              chapters.reduce(0, { $0 + $1.sourceText.utf16.count }) <= 3_000_000 else {
            throw KoeBookError.invalidPackage
        }
        for chapter in chapters {
            guard UUID(uuidString: chapter.id) != nil, UUID(uuidString: chapter.readingId) != nil,
                  chapter.position > 0, chapter.sourceText.utf8.count <= 250_000,
                  chapter.pages.allSatisfy({ (1...pageCount).contains($0) }),
                  chapter.audioFile == nil || chapter.audioFile == chapter.readingId + ".mp3",
                  chapter.pageSpans.allSatisfy({ (1...pageCount).contains($0.page) && $0.charStart >= 0 && $0.charEnd >= $0.charStart && $0.charEnd <= chapter.sourceText.utf16.count }),
                  chapter.tokens.allSatisfy({ $0.charStart >= 0 && $0.charEnd >= $0.charStart && $0.charEnd <= chapter.sourceText.utf16.count && ($0.audioStart == nil || ($0.audioStart!.isFinite && $0.audioStart! >= 0)) }),
                  chapter.textHash == Self.hash(Data(chapter.sourceText.utf8)) else { throw KoeBookError.invalidPackage }
        }
    }
    static func isHash(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
}

struct KoeBookChapter: Codable, Identifiable, Sendable {
    var id: String
    var readingId: String
    var position: Int
    var title: String
    var status: String
    var sourceText: String
    var textHash: String
    var pages: [Int]
    var pageSpans: [KoeBookPageSpan]
    var mappingConfidence: Double
    var tokens: [KoeBookToken]
    var audioFile: String?
    var audioSha256: String?
    var durationSeconds: Double?

    var canFollowPages: Bool { mappingConfidence >= 0.85 && !pageSpans.isEmpty && tokens.contains { $0.audioStart != nil } }
    func page(at seconds: Double) -> Int? {
        guard canFollowPages else { return nil }
        // Timing offsets are JavaScript/NSString UTF-16 offsets, not Swift grapheme indices.
        let timed = tokens.filter { $0.audioStart != nil }
        var low = 0, high = timed.count
        while low < high { let mid = (low + high) / 2; if timed[mid].audioStart! <= seconds { low = mid + 1 } else { high = mid } }
        guard low > 0 else { return pageSpans.first?.page }
        let offset = timed[low - 1].charStart
        return pageSpans.last(where: { $0.charStart <= offset && offset < $0.charEnd })?.page ?? pageSpans.last?.page
    }
}
struct KoeBookPageSpan: Codable, Sendable { var page: Int; var charStart: Int; var charEnd: Int }
struct KoeBookToken: Codable, Sendable { var charStart: Int; var charEnd: Int; var audioStart: Double?; var audioEnd: Double? }
struct KoeBookPlace: Codable, Sendable {
    var chapterId: String; var page: Int; var seconds: Double
    var zoom: Double = 1; var rate: Float = 1; var followPages: Bool = true
    // Optional fields keep pre-Kokoro places backwards compatible. Seconds
    // always belong to the original recording; Kokoro resumes by source word.
    var voiceSource: KoeBookVoiceSource?
    var kokoroWord: Int?
}
enum KoeBookVoiceSource: String, Codable, CaseIterable, Sendable {
    case recorded, kokoro
    var label: String { self == .recorded ? "Audiobook Narrator" : "Kokoro" }
    static func kokoroVoiceName(_ identifier: String) -> String {
        let parts = identifier.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 2,
              parts[1].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return identifier }
        return parts[1].replacingOccurrences(of: "_", with: " ").capitalized
    }
}
enum KoeBookError: LocalizedError {
    case invalidPackage, missingAudio, identityChanged, signIn, unsafeURL, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidPackage: "This book package could not be verified."
        case .missingAudio: "This chapter's audio is still being prepared. Refresh to get finished chapters."
        case .identityChanged: "The source or recorded text changed. Keep this book and import the new version separately."
        case .signIn: "Connect to Evergreen to get newly finished chapters. Cached chapters remain available."
        case .unsafeURL: "The recording must come from your connected Evergreen server."
        case .tooLarge: "This download is too large for Koe's book cache."
        }
    }
}
