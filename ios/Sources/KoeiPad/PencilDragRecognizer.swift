import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Tracks one Apple Pencil touch and reports its location and barrel roll.
/// Begins only after the tip has moved a little, so a Pencil tap still goes
/// to the tap recognizer. Finger touches are ignored (they scroll).
final class PencilDragRecognizer: UIGestureRecognizer {
    private(set) var point: CGPoint = .zero
    /// Barrel roll in radians (Pencil Pro, iOS 17.5+); 0 elsewhere.
    private(set) var rollAngle: CGFloat = 0
    private var tracked: UITouch?
    private var startPoint: CGPoint = .zero
    private var moved = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches where touch.type != .pencil || tracked != nil { ignore(touch, for: event) }
        guard tracked == nil, let touch = touches.first(where: { $0.type == .pencil }) else { return }
        tracked = touch
        startPoint = touch.location(in: view)
        moved = false
        update(touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = tracked, touches.contains(touch) else { return }
        update(touch)
        if !moved {
            guard hypot(point.x - startPoint.x, point.y - startPoint.y) > 8 else { return }
            moved = true
            state = .began
        } else {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = tracked, touches.contains(touch) else { return }
        update(touch)
        state = moved ? .ended : .failed
        tracked = nil
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = tracked, touches.contains(touch) else { return }
        state = moved ? .cancelled : .failed
        tracked = nil
    }

    override func reset() {
        tracked = nil
        moved = false
    }

    private func update(_ touch: UITouch) {
        point = touch.location(in: view)
        if #available(iOS 17.5, *) { rollAngle = touch.rollAngle }
    }
}

/// Pencil Pro haptics (iOS 17.5+): a tick when the selection snaps to a word
/// boundary or the colour steps, a firmer tick when a mark is laid down.
final class PencilHaptics {
    private var generator: Any?
    init(view: UIView) {
        if #available(iOS 17.5, *) { generator = UICanvasFeedbackGenerator(view: view) }
    }
    func tick(at point: CGPoint) {
        if #available(iOS 17.5, *), let g = generator as? UICanvasFeedbackGenerator { g.alignmentOccurred(at: point) }
    }
    func done(at point: CGPoint) {
        if #available(iOS 17.5, *), let g = generator as? UICanvasFeedbackGenerator { g.pathCompleted(at: point) }
    }
}
