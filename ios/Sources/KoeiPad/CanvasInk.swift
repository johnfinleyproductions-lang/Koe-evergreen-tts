import SwiftUI
import PencilKit
import UIKit

/// Editing the Idea Canvas from the iPad: Pencil sketches as cards, plus moving,
/// recolouring and deleting cards. Writes the same documents the Mac reads;
/// StateSync pushes them, and the Mac shows the sketch within a minute.
@MainActor
enum CanvasWriter {
    enum Failure: LocalizedError {
        case empty, tooLarge, encoding
        var errorDescription: String? {
            switch self {
            case .empty: return "Draw something first."
            case .tooLarge: return "This sketch is too detailed to sync (the limit is 1 MB). Try splitting it into two cards."
            case .encoding: return "The sketch could not be saved."
            }
        }
    }

    static func notes() -> [CanvasNote] {
        guard let data = UserDefaults.standard.data(forKey: KoeStateKeys.canvasNotes) else { return [] }
        return (try? JSONDecoder().decode([CanvasNote].self, from: data)) ?? []
    }
    private static func save(_ notes: [CanvasNote]) {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        UserDefaults.standard.set(data, forKey: KoeStateKeys.canvasNotes)
        NotificationCenter.default.post(name: .koeStateChanged, object: KoeStateKeys.canvasNotes)
    }

    /// A new sketch card below the existing cards. The card is saved before its
    /// ink document so a pull in between never garbage-collects the drawing.
    @discardableResult
    static func addSketch(_ drawing: PKDrawing) throws -> UUID {
        let id = UUID()
        let key = KoeStateKeys.inkKey(for: id)
        let doc = try inkDocument(drawing, id: id)
        var all = notes()
        let n = all.count
        let maxY = all.map(\.y).max() ?? 120
        let note = CanvasNote(id: id, text: "", source: "iPad sketch",
                              x: 320 + Double((n * 47) % 360), y: maxY + 60 + Double((n * 31) % 90),
                              colorIndex: n % MacDocuments.canvasColors.count, tilt: Double((n % 5) - 2) * 0.8, ink: key)
        all.append(note)
        save(all)
        KoeStateLocal.set(doc, forKey: key)
        NotificationCenter.default.post(name: .koeStateChanged, object: key)
        return id
    }

    static func updateSketch(_ id: UUID, drawing: PKDrawing) throws {
        guard let key = notes().first(where: { $0.id == id })?.ink else { return }
        let doc = try inkDocument(drawing, id: id)
        KoeStateLocal.set(doc, forKey: key)
        NotificationCenter.default.post(name: .koeStateChanged, object: key)
    }

    static func move(_ id: UUID, to point: CGPoint) {
        var all = notes()
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].x = max(0, point.x); all[i].y = max(0, point.y)
        save(all)
    }

    static func recolor(_ id: UUID) {
        var all = notes()
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].colorIndex = (all[i].colorIndex + 1) % MacDocuments.canvasColors.count
        save(all)
    }

    static func setCaption(_ id: UUID, _ text: String) {
        var all = notes()
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        save(all)
    }

    /// Remove a card and the links that touch it; a sketch's document is deleted on the server too.
    static func remove(_ id: UUID, sync: StateSync) {
        var all = notes()
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        let ink = all[i].ink
        all.remove(at: i)
        save(all)
        if let data = UserDefaults.standard.data(forKey: KoeStateKeys.canvasLinks),
           var links = try? JSONDecoder().decode([CanvasLink].self, from: data) {
            let before = links.count
            links.removeAll { $0.from == id || $0.to == id }
            if links.count != before, let encoded = try? JSONEncoder().encode(links) {
                UserDefaults.standard.set(encoded, forKey: KoeStateKeys.canvasLinks)
                NotificationCenter.default.post(name: .koeStateChanged, object: KoeStateKeys.canvasLinks)
            }
        }
        if let ink { Task { await sync.delete(ink) } }
    }

    /// PencilKit strokes plus an opaque JPEG preview, kept under Core's document cap.
    static func inkDocument(_ drawing: PKDrawing, id: UUID) throws -> [String: Any] {
        guard !drawing.strokes.isEmpty else { throw Failure.empty }
        let bounds = drawing.bounds.insetBy(dx: -16, dy: -16)
        let strokes = drawing.dataRepresentation()
        var scale = min(2, 900 / max(bounds.width, 1))
        var quality: CGFloat = 0.72
        for _ in 0..<4 {
            guard let jpeg = preview(drawing, bounds: bounds, scale: scale, quality: quality) else { throw Failure.encoding }
            let doc = KoeCanvasInk.document(id: id, width: bounds.width, height: bounds.height, drawing: strokes, preview: jpeg)
            if KoeCanvasInk.encodedSize(doc) <= KoeCanvasInk.maxDocumentBytes { return doc }
            scale *= 0.6; quality = 0.5
        }
        throw Failure.tooLarge
    }

    /// Strokes composited on paper, always in light appearance (dark mode would invert black ink).
    private static func preview(_ drawing: PKDrawing, bounds: CGRect, scale: CGFloat, quality: CGFloat) -> Data? {
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1; format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        var strokes = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { strokes = drawing.image(from: bounds, scale: scale) }
        let image = renderer.image { ctx in
            UIColor(red: 0.99, green: 0.98, blue: 0.95, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            strokes.draw(in: CGRect(origin: .zero, size: size))
        }
        return image.jpegData(compressionQuality: quality)
    }
}

/// Sketch images for the canvas, decoded once per document revision.
@MainActor
final class InkImages: ObservableObject {
    @Published private(set) var version = 0
    private var images: [String: UIImage] = [:]
    private var observers: [NSObjectProtocol] = []

    init() {
        for name in [Notification.Name.koeStateDidPull, .koeStateChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let key = note.object as? String, KoeStateKeys.isInk(key) else { return }
                Task { @MainActor in self?.images[key] = nil; self?.version += 1 }
            })
        }
    }

    func image(_ key: String) -> UIImage? {
        if let hit = images[key] { return hit }
        let doc = KoeStateLocal.value(forKey: key)
        var image: UIImage?
        if let data = KoeCanvasInk.preview(in: doc) { image = UIImage(data: data) }
        if image == nil, let drawing = drawing(key), !drawing.bounds.isEmpty {
            image = drawing.image(from: drawing.bounds.insetBy(dx: -16, dy: -16), scale: 2)
        }
        if let image { images[key] = image }
        return image
    }

    func drawing(_ key: String) -> PKDrawing? {
        guard let data = KoeCanvasInk.drawing(in: KoeStateLocal.value(forKey: key)) else { return nil }
        return try? PKDrawing(data: data)
    }
}

/// Full-screen Pencil surface with the system tool picker. Save hands back the drawing.
struct SketchSheet: View {
    let title: String
    let onSave: (PKDrawing) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var drawing: PKDrawing
    @State private var hasStrokes: Bool

    init(title: String, initial: PKDrawing = PKDrawing(), onSave: @escaping (PKDrawing) -> Void) {
        self.title = title; self.onSave = onSave
        _drawing = State(initialValue: initial)
        _hasStrokes = State(initialValue: !initial.strokes.isEmpty)
    }

    var body: some View {
        NavigationStack {
            PencilCanvas(drawing: $drawing) { hasStrokes = !$0.strokes.isEmpty }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { onSave(drawing); dismiss() }.bold().disabled(!hasStrokes)
                    }
                }
        }
        .interactiveDismissDisabled(hasStrokes)
    }
}

struct PencilCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var onChange: (PKDrawing) -> Void = { _ in }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.drawing = drawing
        canvas.drawingPolicy = .anyInput
        canvas.isScrollEnabled = false
        canvas.backgroundColor = UIColor(red: 0.99, green: 0.98, blue: 0.95, alpha: 1)
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = context.coordinator
        DispatchQueue.main.async { context.coordinator.showPicker(for: canvas) }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        context.coordinator.parent = self
        if canvas.window != nil { context.coordinator.showPicker(for: canvas) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: PencilCanvas
        private let picker = PKToolPicker()
        private var pickerShown = false
        init(_ parent: PencilCanvas) { self.parent = parent }

        func showPicker(for canvas: PKCanvasView) {
            guard !pickerShown, canvas.window != nil else { return }
            pickerShown = true
            picker.setVisible(true, forFirstResponder: canvas)
            picker.addObserver(canvas)
            canvas.becomeFirstResponder()
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            parent.drawing = canvasView.drawing
            parent.onChange(canvasView.drawing)
        }
    }
}
