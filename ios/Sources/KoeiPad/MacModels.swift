import Foundation

// The Mac app's Boards, Canvas and Library documents, decoded from the same
// UserDefaults keys the sync fills. Field names match UI/KoeBoards.swift,
// UI/KoeCanvas.swift and UI/KoeLibrary.swift exactly.

struct BoardItem: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var text: String
    var source: String = ""
    var kind: String = "read"
}
struct Board: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var accentHex: UInt32
    var items: [BoardItem] = []
}
struct CanvasNote: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var text: String
    var source: String = ""
    var x: Double
    var y: Double
    var colorIndex: Int
    var tilt: Double
}
struct CanvasLink: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var from: UUID
    var to: UUID
}
struct LibrarySnippet: Identifiable, Codable, Equatable, Hashable { var id = UUID(); var text: String; var source: String = "" }
struct LibraryImage: Identifiable, Codable, Equatable, Hashable { var id = UUID(); var filename: String }
struct NotebookTab: Identifiable, Codable, Equatable, Hashable { var id = UUID(); var title: String; var body: String = ""; var images: [LibraryImage] = [] }
struct Notebook: Identifiable, Codable, Equatable, Hashable {
    var id = UUID(); var title: String
    var tabs: [NotebookTab] = []
    var activeTabID: UUID?
}

/// Read-only views over the synced documents; refreshed when the sync pulls.
@MainActor
final class MacDocuments: ObservableObject {
    @Published var boards: [Board] = []
    @Published var notes: [CanvasNote] = []
    @Published var links: [CanvasLink] = []
    @Published var notebooks: [Notebook] = []
    @Published var pulled: [LibrarySnippet] = []
    private var observers: [NSObjectProtocol] = []

    init() {
        reload()
        for name in [Notification.Name.koeStateDidPull, .koeStateChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reload() }
            })
        }
    }

    func reload() {
        boards = decode(KoeStateKeys.boards) ?? []
        notes = decode(KoeStateKeys.canvasNotes) ?? []
        links = decode(KoeStateKeys.canvasLinks) ?? []
        notebooks = decode(KoeStateKeys.notebooks) ?? []
        pulled = decode(KoeStateKeys.libraryPulled) ?? []
    }

    private func decode<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static let canvasColors: [UInt32] = [0xFDF3C4, 0xDDE3EC, 0xF4DDD6, 0xE3ECD6, 0xEADDF0, 0xD6E8EC]
}


/// Appends a passage to one of the Mac's boards, locally; StateSync pushes it.
enum BoardWriter {
    @MainActor
    static func save(text: String, source: String, to boardId: UUID) -> Bool {
        let key = KoeStateKeys.boards
        guard let data = UserDefaults.standard.data(forKey: key),
              var boards = try? JSONDecoder().decode([Board].self, from: data),
              let index = boards.firstIndex(where: { $0.id == boardId }) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        boards[index].items.append(BoardItem(text: trimmed, source: source, kind: trimmed.count < 160 ? "clip" : "read"))
        guard let encoded = try? JSONEncoder().encode(boards) else { return false }
        UserDefaults.standard.set(encoded, forKey: key)
        NotificationCenter.default.post(name: .koeStateChanged, object: key)
        return true
    }
}
