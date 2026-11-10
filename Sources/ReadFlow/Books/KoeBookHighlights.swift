import Foundation
import Combine
import AppKit

struct KoeBookMarkRect: Codable, Equatable {
    var x: Double; var y: Double; var width: Double; var height: Double
    init(_ rect: CGRect) { x = rect.minX; y = rect.minY; width = rect.width; height = rect.height }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var valid: Bool { [x, y, width, height].allSatisfy { $0.isFinite && abs($0) < 100_000 } && width > 0 && height > 0 }
}
struct KoeBookHighlight: Codable, Identifiable, Equatable {
    var id = UUID()
    var page: Int
    var rects: [KoeBookMarkRect]
    var text: String
    var color: KoeHighlightColor
    var createdAt = Date()
}

@MainActor
final class KoeBookHighlights: ObservableObject {
    @Published private(set) var marks: [KoeBookHighlight] = []
    @Published var selection: [KoeBookHighlight] = []
    @Published var color: KoeHighlightColor = .yellow
    @Published var areaMode = false
    @Published var error: String?
    private let file: URL
    private let sourceHash: String
    private let pageCount: Int
    private var canSave = true
    private struct Archive: Codable {
        var schema = "koe-book-highlights/1"
        var sourceSha256: String
        var marks: [KoeBookHighlight]
    }
    init(folder: URL, sourceHash: String, pageCount: Int) {
        file = folder.appendingPathComponent("highlights.json")
        self.sourceHash = sourceHash; self.pageCount = pageCount
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 8 * 1024 * 1024 else { throw KoeBookError.tooLarge }
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
            guard archive.schema == "koe-book-highlights/1", archive.sourceSha256 == sourceHash,
                  archive.marks.count <= 10_000, Set(archive.marks.map(\.id)).count == archive.marks.count,
                  archive.marks.allSatisfy(valid) else { throw KoeBookError.invalidPackage }
            marks = archive.marks
        } catch {
            canSave = false
            self.error = "Your saved highlights could not be opened. The saved file has been kept."
        }
    }
    private func valid(_ mark: KoeBookHighlight) -> Bool {
        (1...pageCount).contains(mark.page) && !mark.rects.isEmpty && mark.rects.count <= 1000 && mark.rects.allSatisfy(\.valid) && mark.text.utf8.count <= 100_000
    }
    @discardableResult func add(_ candidates: [KoeBookHighlight]) -> Bool {
        guard !candidates.isEmpty, candidates.allSatisfy(valid) else { return false }
        let additions = candidates.filter { candidate in !marks.contains { $0.page == candidate.page && $0.rects == candidate.rects && $0.color == candidate.color } }
        guard !additions.isEmpty else { selection = []; return true }
        guard persist(marks + additions) else { return false }
        selection = []; return true
    }
    func highlightSelection() { _ = add(selection.map { var mark = $0; mark.color = color; return mark }) }
    @discardableResult func remove(_ id: UUID) -> Bool { persist(marks.filter { $0.id != id }) }
    private func persist(_ next: [KoeBookHighlight]) -> Bool {
        guard canSave else { return false }
        do {
            guard next.count <= 10_000 else { throw KoeBookError.tooLarge }
            let bytes = try JSONEncoder().encode(Archive(sourceSha256: sourceHash, marks: next))
            guard bytes.count <= 8 * 1024 * 1024 else { throw KoeBookError.tooLarge }
            try bytes.write(to: file, options: .atomic)
            marks = next; error = nil; return true
        } catch { self.error = "Koe could not save this highlight. Check the book folder's permissions."; return false }
    }
}

extension KoeHighlightColor {
    var bookColor: NSColor {
        switch self {
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .pink: .systemPink
        case .blue: .systemBlue
        }
    }
}
