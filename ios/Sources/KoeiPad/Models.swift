import Foundation

// Shapes of Core's native book routes (app/api/reader/books/**/native).

struct LibraryResponse: Decodable { var schema: String; var books: [BookSummary] }

struct BookSummary: Decodable, Identifiable, Hashable {
    var id: String
    var title: String
    var author: String
    var createdAt: String?
    var count: Int
    var ready: Int
}

struct BookDetailResponse: Decodable {
    var schema: String
    var book: BookInfo
    var chapters: [Chapter]
    var reading: Reading?
}

struct BookInfo: Decodable, Hashable {
    var id: String
    var title: String
    var author: String
    var contentHash: String
    var sourceSha256: String
    var pageCount: Int?
    var reviewPolicy: String?
    var sourceUrl: String?
}

struct Chapter: Decodable, Identifiable, Hashable {
    var id: String
    var position: Int
    var title: String
    var readingId: String
    var status: String
    var sourcePages: [Int]
    var reviewPages: [Int]?
    var completedSentences: Int?
    var totalSentences: Int?
    var errorMessage: String?
    var durationSeconds: Double?

    /// A narrator recording exists. Every chapter can still be read by Kokoro.
    var isReady: Bool { status == "completed" }
    var firstPage: Int { sourcePages.min() ?? 1 }
    var statusLabel: String {
        switch status {
        case "completed": return "Ready"
        case "running": return "Narrating"
        case "queued": return "Queued"
        case "failed": return "Failed"
        default: return status.capitalized
        }
    }
}

struct Reading: Decodable {
    var id: String
    var sourceText: String
    var textHash: String
    var voiceId: String?
    var durationSeconds: Double?
    var tokens: [Token]
    var audioUrl: String?
}

/// Word timing. Offsets are UTF-16 (JavaScript) offsets into `sourceText`,
/// which is exactly what NSRange wants.
struct Token: Decodable {
    var text: String?
    var charStart: Int
    var charEnd: Int
    var audioStart: Double?
    var audioEnd: Double?
}

/// Where the listener left off, kept on this iPad. Core's progress route gets
/// the same seconds; the native route doesn't return it yet (Phase 2).
struct Place: Codable {
    var chapterId: String
    var seconds: Double
    var page: Int
    var rate: Float
    var followPages: Bool
    var updatedAt: Date
    // Optional so places saved before the Kokoro option still decode.
    var voiceSource: VoiceSource?
    var kokoroWord: Int?
}

enum VoiceSource: String, Codable, CaseIterable {
    case recorded, kokoro
    var label: String { self == .recorded ? "Audiobook Narrator" : "Kokoro" }
}

/// Kokoro runs on the think box; same keys the Mac app uses, iPad namespace.
enum KokoroSettings {
    static var baseURL: URL {
        get { URL(string: UserDefaults.standard.string(forKey: "koe.kokoroURL") ?? "") ?? URL(string: "http://192.168.4.200:8880")! }
        set { UserDefaults.standard.set(newValue.absoluteString, forKey: "koe.kokoroURL") }
    }
    static var voice: String {
        get { UserDefaults.standard.string(forKey: "koe.kokoroVoice") ?? "af_heart" }
        set { UserDefaults.standard.set(newValue, forKey: "koe.kokoroVoice") }
    }
    /// "af_heart" → "Heart", like the Mac's KoeBookVoiceSource.kokoroVoiceName.
    static func voiceName(_ identifier: String) -> String {
        let parts = identifier.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, parts[0].count == 2 else { return identifier }
        return parts[1].replacingOccurrences(of: "_", with: " ").capitalized
    }
}

enum PlaceStore {
    private static let key = "koe.places"
    static func load(_ bookId: String) -> Place? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let all = try? JSONDecoder().decode([String: Place].self, from: data) else { return nil }
        return all[bookId]
    }
    static func save(_ bookId: String, _ place: Place) {
        var all = (UserDefaults.standard.data(forKey: key)).flatMap { try? JSONDecoder().decode([String: Place].self, from: $0) } ?? [:]
        all[bookId] = place
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: key) }
    }
}

enum KoeError: LocalizedError {
    case signIn, unsafeURL, tooLarge, missingAudio, network(String), http(Int)
    var errorDescription: String? {
        switch self {
        case .signIn: return "Sign in to Evergreen to see your books."
        case .unsafeURL: return "The recording must come from your connected Evergreen server."
        case .tooLarge: return "This download is too large for Koe's cache."
        case .missingAudio: return "This chapter's audio is still being prepared."
        case .network(let why): return why
        case .http(let code): return "Evergreen answered HTTP \(code)."
        }
    }
}
