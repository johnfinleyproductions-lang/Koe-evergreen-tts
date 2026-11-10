//
//  HighlightingTextView.swift
//  ReadFlow / Koe
//
//  A deliberately small AppKit bridge. NSTextView supplies native mouse/trackpad
//  selection while SwiftUI remains the source of truth for saved highlights.
//

import AppKit
import SwiftUI

@MainActor
private final class KoeSelectableTextView: NSTextView {
    var onClickedCharacterOffset: ((Int) -> Void)?

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        let selected = selectedRange()
        if selected.length == 0 {
            onClickedCharacterOffset?(selected.location)
        }
    }
}

extension KoeHighlightColor {
    var nsColor: NSColor {
        switch self {
        case .yellow: return NSColor(calibratedRed: 0.99, green: 0.90, blue: 0.52, alpha: 1)
        case .green:  return NSColor(calibratedRed: 0.72, green: 0.90, blue: 0.70, alpha: 1)
        case .pink:   return NSColor(calibratedRed: 0.97, green: 0.73, blue: 0.79, alpha: 1)
        case .blue:   return NSColor(calibratedRed: 0.68, green: 0.84, blue: 0.97, alpha: 1)
        }
    }

    var swiftUIColor: Color { Color(nsColor: nsColor) }
}

@MainActor
struct KoeHighlightingTextView: NSViewRepresentable {
    let documentID: String
    let text: String
    let highlights: [KoeTextHighlight]
    let currentWordRange: NSRange?
    let fontName: String
    let fontSize: Double
    let lineHeight: Double
    let letterSpacing: Double
    let onSeekToCharacterOffset: (Int) -> Void
    let onApplyHighlight: (KoeHighlightColor) -> Void
    let onClearHighlight: () -> Void
    @Binding var selection: NSRange?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = KoeSelectableTextView()
        textView.onClickedCharacterOffset = onSeekToCharacterOffset
        textView.delegate = context.coordinator
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        scrollView.documentView = textView

        context.coordinator.render(in: textView, forceDocumentRefresh: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? KoeSelectableTextView else { return }
        context.coordinator.parent = self
        textView.onClickedCharacterOffset = onSeekToCharacterOffset
        context.coordinator.render(in: textView, forceDocumentRefresh: false)

        let desired = selection ?? NSRange(location: 0, length: 0)
        if textView.selectedRange() != desired, NSMaxRange(desired) <= (text as NSString).length {
            textView.setSelectedRange(desired)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: KoeHighlightingTextView
        private var lastSignature: RenderSignature?
        private var lastActiveRange: NSRange?
        private var highlightPopover: NSPopover?
        private var selectionPopoverWork: DispatchWorkItem?

        init(parent: KoeHighlightingTextView) {
            self.parent = parent
        }

        func render(in textView: NSTextView, forceDocumentRefresh: Bool) {
            let signature = RenderSignature(
                documentID: parent.documentID,
                highlights: parent.highlights,
                fontName: parent.fontName,
                fontSize: parent.fontSize,
                lineHeight: parent.lineHeight,
                letterSpacing: parent.letterSpacing
            )

            if forceDocumentRefresh || signature != lastSignature {
                rebuildDocument(in: textView)
                lastSignature = signature
                lastActiveRange = nil
            } else if let oldRange = lastActiveRange,
                      oldRange != parent.currentWordRange {
                restoreManualBackground(in: oldRange, textView: textView)
            }

            if let current = valid(parent.currentWordRange), current != lastActiveRange {
                textView.textStorage?.addAttribute(
                    .backgroundColor,
                    value: NSColor(calibratedRed: 0.75, green: 0.26, blue: 0.18, alpha: 0.45),
                    range: current
                )
                lastActiveRange = current
                textView.scrollRangeToVisible(current)
            } else if parent.currentWordRange == nil {
                lastActiveRange = nil
            }
        }

        private func rebuildDocument(in textView: NSTextView) {
            let length = (parent.text as NSString).length
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = max(2, parent.fontSize * max(0, parent.lineHeight - 1.0))
            paragraph.paragraphSpacing = max(4, parent.fontSize * 0.35)

            let font = resolvedFont(name: parent.fontName, size: CGFloat(parent.fontSize))
            let attributed = NSMutableAttributedString(
                string: parent.text,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor(calibratedRed: 0.23, green: 0.20, blue: 0.16, alpha: 1),
                    .paragraphStyle: paragraph,
                    .kern: parent.letterSpacing,
                ]
            )

            for highlight in parent.highlights {
                let range = highlight.range
                guard range.location >= 0, range.length > 0, NSMaxRange(range) <= length else { continue }
                attributed.addAttribute(.backgroundColor, value: highlight.color.nsColor, range: range)
            }
            textView.textStorage?.setAttributedString(attributed)
        }

        private func restoreManualBackground(in range: NSRange, textView: NSTextView) {
            guard let storage = textView.textStorage, let validRange = valid(range) else { return }
            storage.removeAttribute(.backgroundColor, range: validRange)
            for highlight in parent.highlights {
                let overlap = NSIntersectionRange(validRange, highlight.range)
                guard overlap.length > 0 else { continue }
                storage.addAttribute(.backgroundColor, value: highlight.color.nsColor, range: overlap)
            }
        }

        private func valid(_ range: NSRange?) -> NSRange? {
            guard let range,
                  range.location != NSNotFound,
                  range.location >= 0,
                  range.length > 0,
                  NSMaxRange(range) <= (parent.text as NSString).length
            else { return nil }
            return range
        }

        private func resolvedFont(name: String, size: CGFloat) -> NSFont {
            if !name.isEmpty, let preferred = NSFont(name: name, size: size) { return preferred }
            return NSFont.systemFont(ofSize: size)
        }

        private func showHighlightPopover(for range: NSRange, in textView: NSTextView) {
            highlightPopover?.performClose(nil)

            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentSize = NSSize(width: 246, height: 52)
            popover.contentViewController = NSHostingController(
                rootView: KoeHighlightChoicePopover(
                    onChoose: { [weak self] color in
                        guard let self else { return }
                        self.parent.onApplyHighlight(color)
                        self.highlightPopover?.performClose(nil)
                    },
                    onClear: { [weak self] in
                        guard let self else { return }
                        self.parent.onClearHighlight()
                        self.highlightPopover?.performClose(nil)
                    }
                )
            )
            highlightPopover = popover

            guard let window = textView.window else { return }

            // `firstRect(forCharacterRange:)` is screen-space and can return an
            // unusable rect while the text view is still laying out. Use it when
            // valid, then fall back to the visible reading area so the chooser
            // always has an on-screen anchor.
            var localRect = NSRect(
                x: textView.visibleRect.midX - 1,
                y: textView.visibleRect.minY + 8,
                width: 2,
                height: 2
            )
            var actualRange = NSRange()
            let screenRect = textView.firstRect(forCharacterRange: range, actualRange: &actualRange)
            if !screenRect.isEmpty, actualRange.length > 0 {
                let windowRect = window.convertFromScreen(screenRect)
                let candidate = textView.convert(windowRect, from: nil)
                if candidate.intersects(textView.visibleRect) {
                    localRect = candidate
                }
            }
            popover.show(relativeTo: localRect, of: textView, preferredEdge: .maxY)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let range = textView.selectedRange()
            let next: NSRange? = range.length > 0 ? range : nil
            selectionPopoverWork?.cancel()

            guard next != parent.selection else { return }
            parent.selection = next

            guard let next else {
                highlightPopover?.performClose(nil)
                return
            }

            // Wait for the selection gesture/layout pass to settle. This avoids
            // presenting a chooser on the first drag update and also avoids
            // relying on NSTextView's mouse-up override.
            let work = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView,
                      textView.selectedRange() == next,
                      self.valid(next) != nil else { return }
                self.showHighlightPopover(for: next, in: textView)
            }
            selectionPopoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }
    }

    private struct RenderSignature: Equatable {
        let documentID: String
        let highlights: [KoeTextHighlight]
        let fontName: String
        let fontSize: Double
        let lineHeight: Double
        let letterSpacing: Double
    }
}

private struct KoeHighlightChoicePopover: View {
    let onChoose: (KoeHighlightColor) -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Text("Highlight")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(KoeHighlightColor.allCases) { color in
                Button { onChoose(color) } label: {
                    Circle()
                        .fill(color.swiftUIColor)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(.primary.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(color.label)
                .accessibilityLabel("Highlight \(color.label.lowercased())")
            }

            Divider().frame(height: 22)

            Button(action: onClear) {
                Image(systemName: "eraser")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Remove highlight")
            .accessibilityLabel("Remove highlight")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 246, height: 52)
    }
}
