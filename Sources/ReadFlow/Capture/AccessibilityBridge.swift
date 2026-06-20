//
//  AccessibilityBridge.swift
//  ReadFlow
//
//  Returns the user's currently selected text from anywhere on macOS.
//
//  Strategy (per SPEC §3.5):
//    1. Accessibility (AX) FIRST: AXUIElementCreateSystemWide ->
//       kAXFocusedUIElementAttribute -> kAXSelectedTextAttribute. This is the
//       reliable, non-destructive path that works in well-behaved apps.
//    2. Clipboard-copy FALLBACK for apps that don't expose AX selected text:
//       SAVE the user's full pasteboard, synthesize Cmd-C, read the copied
//       text, then RESTORE the original pasteboard so we NEVER lose user data.
//
//  Also exposes Accessibility-permission state + a guided prompt that opens the
//  System Settings pane, because both AX reads and the Cmd-C fallback require
//  the app to be trusted as an Accessibility client.
//
//  Apple frameworks only. No retain cycles (no stored closures/timers here).
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum AccessibilityBridge {

    // MARK: - Public surface (SPEC §3.5)

    /// The user's currently selected text, or `nil` if nothing is selected /
    /// could not be obtained. Tries AX first, then the clipboard fallback.
    ///
    /// Returned text is the raw selection with no trimming or normalization, so
    /// the manager can tokenize the exact string it hands to the engine. (Empty
    /// or whitespace-only selections are reported as `nil` so the manager can
    /// surface `TTSError.emptyText`.)
    static func selectedText() -> String? {
        if let viaAX = selectedTextViaAX(), !isEffectivelyEmpty(viaAX) {
            return viaAX
        }
        if let viaClipboard = selectedTextViaClipboard(), !isEffectivelyEmpty(viaClipboard) {
            return viaClipboard
        }
        return nil
    }

    /// Whether ReadFlow is currently trusted as an Accessibility client. Does
    /// NOT prompt. Cheap to call.
    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// NON-DESTRUCTIVE selected-text read: the AX path ONLY, never the
    /// clipboard/Cmd-C fallback. Used by the auto "Read on Highlight" chip, which
    /// polls on every mouse-up — using `selectedText()` there would synthesize a
    /// Cmd-C on every click. Returns `nil` if untrusted, unfocused, empty, or the
    /// app doesn't expose AX selected text.
    static func selectedTextViaAccessibility() -> String? {
        guard let text = selectedTextViaAX(), !isEffectivelyEmpty(text) else { return nil }
        return text
    }

    /// If not yet trusted, trigger the system Accessibility prompt and open the
    /// Privacy & Security -> Accessibility pane so the user can enable ReadFlow.
    /// Safe to call repeatedly; no-op (beyond opening the pane) once trusted.
    static func promptForAccessibilityIfNeeded() {
        // Show the system "grant Accessibility" dialog if we're not trusted yet.
        // kAXTrustedCheckOptionPrompt is a global `var` that Swift 6 flags as
        // non-concurrency-safe; its value is the documented, stable string
        // "AXTrustedCheckOptionPrompt", so we use that literal directly.
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let options: CFDictionary = [promptKey: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            openAccessibilitySettingsPane()
        }
    }

    // MARK: - Optional selection bounds (on-screen)

    /// The on-screen bounds of the current selection, in bottom-left-origin
    /// Cocoa screen coordinates, if the focused element exposes them via AX.
    /// Returns `nil` when unavailable (most non-AX apps). Useful for anchoring
    /// the HUD near the text; never required for reading to work.
    static func selectionBounds() -> CGRect? {
        guard isAccessibilityTrusted() else { return nil }

        guard let focused = copyFocusedElement() else { return nil }

        // Ask for the bounds of the selected text range via the parameterized
        // attribute kAXBoundsForRangeParameterizedAttribute.
        guard let selectedRangeValue = copyAttribute(focused, kAXSelectedTextRangeAttribute as CFString) else {
            return nil
        }
        // The value is an AXValue wrapping a CFRange.
        let axRangeValue = selectedRangeValue as! AXValue // AXValue is the only type AX returns here.
        guard AXValueGetType(axRangeValue) == .cfRange else { return nil }
        var cfRange = CFRange()
        guard AXValueGetValue(axRangeValue, .cfRange, &cfRange) else { return nil }

        var boundsRef: CFTypeRef?
        let paramAttr = "AXBoundsForRange" as CFString // kAXBoundsForRangeParameterizedAttribute
        var mutableRange = cfRange
        guard let rangeArg = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        let err = AXUIElementCopyParameterizedAttributeValue(
            focused, paramAttr, rangeArg, &boundsRef
        )
        guard err == .success, let boundsRef else { return nil }

        let boundsAXValue = boundsRef as! AXValue
        guard AXValueGetType(boundsAXValue) == .cgRect else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(boundsAXValue, .cgRect, &rect) else { return nil }

        // AX returns top-left-origin "flipped" screen coords; convert to Cocoa
        // bottom-left-origin coordinates relative to the primary display.
        return convertFromFlippedScreenRect(rect)
    }

    // MARK: - AX path

    /// Read selected text directly from the focused AX element. Non-destructive
    /// (does not touch the pasteboard). Returns `nil` if untrusted, no focus, or
    /// the element doesn't expose selected text.
    private static func selectedTextViaAX() -> String? {
        guard isAccessibilityTrusted() else { return nil }
        guard let focused = copyFocusedElement() else { return nil }

        if let value = copyAttribute(focused, kAXSelectedTextAttribute as CFString),
           let text = value as? String {
            return text
        }
        return nil
    }

    /// The system-wide focused UI element, if any.
    private static func copyFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        guard let focused = copyAttribute(systemWide, kAXFocusedUIElementAttribute as CFString) else {
            return nil
        }
        // Avoid force casts on AXUIElement; verify the CFTypeID instead.
        guard CFGetTypeID(focused as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    /// Generic AX attribute copy that returns `nil` on any non-success status.
    private static func copyAttribute(_ element: AXUIElement, _ attribute: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard err == .success else { return nil }
        return value
    }

    // MARK: - Clipboard fallback (saves & restores user clipboard)

    /// Fallback for apps that don't expose AX selected text. SAVES the entire
    /// pasteboard, synthesizes Cmd-C, reads what landed, then RESTORES the
    /// original pasteboard contents. The user's clipboard is never lost.
    ///
    /// Requires Accessibility trust to post the synthetic key event; if we're
    /// not trusted we bail (and the caller has already failed the AX path).
    private static func selectedTextViaClipboard() -> String? {
        guard isAccessibilityTrusted() else { return nil }

        // Guard against re-entrant captures: a nested run-loop spin (below) can
        // re-deliver read/stop notifications mid-capture; without this a fresh
        // capture could interleave with one already in flight and corrupt the
        // save/restore handshake. If a capture is already running, decline.
        guard !captureInFlight else { return nil }
        captureInFlight = true
        defer { captureInFlight = false }

        let pasteboard = NSPasteboard.general

        // The destructive Cmd-C fallback CANNOT preserve promised / lazily-provided
        // representations (file promises, NSFilePromiseProvider, lazy data
        // providers used by Finder/Photos/Mail/design apps). Those return nil at
        // snapshot time, so restore would silently drop them. Rather than clobber
        // the user's clipboard, skip the fallback entirely and report "nothing
        // selected" — the AX path already failed, and losing a copied file promise
        // is far worse than not reading the selection.
        if pasteboardHasUnrecoverableContents(pasteboard) {
            return nil
        }

        // 1. Snapshot the current pasteboard so we can restore it verbatim.
        let saved = snapshotPasteboard(pasteboard)
        let changeCountBefore = pasteboard.changeCount

        // 2. Synthesize Cmd-C against the frontmost app.
        sendCopyKeystroke()

        // 3. Poll briefly for the copy to land (the target app processes the
        //    keystroke asynchronously). Bounded wait so we never hang.
        let copied = waitForCopiedString(pasteboard, sinceChangeCount: changeCountBefore)

        // 4. Restore the user's original clipboard no matter what we got.
        restorePasteboard(pasteboard, from: saved)

        // 5. Guard against a LATE synthetic Cmd-C landing AFTER restore (slow /
        //    busy / Electron / Java apps that process the keystroke past our poll
        //    deadline). If the change-count bumps again after we restored, the
        //    late copy clobbered the user's clipboard — re-restore the snapshot so
        //    we never permanently lose the user's original data.
        scheduleLateRestoreGuard(pasteboard, saved: saved,
                                 changeCountAfterRestore: pasteboard.changeCount)

        return copied
    }

    /// Set while a clipboard-fallback capture is running so a re-entrant
    /// read/stop can decline rather than interleave with the in-flight
    /// save/restore handshake. `nonisolated(unsafe)`: `selectedText` and its
    /// callees are only ever invoked from the main thread (AppDelegate's
    /// `@MainActor readCurrentSelection`), so this flag is never touched
    /// concurrently.
    nonisolated(unsafe) private static var captureInFlight = false

    /// Promise UTIs whose backing data is provided lazily and so cannot be
    /// captured by `snapshotPasteboard` / restored verbatim.
    private static let promiseTypeIdentifiers: Set<String> = [
        "com.apple.pasteboard.promised-file-url",
        "com.apple.pasteboard.promised-file-content-type",
        "com.apple.NSFilePromiseItemMetaData",
        "Apple files promise pasteboard type",       // NSFilesPromisePboardType (legacy)
        "NSPromiseContentsPboardType"
    ]

    /// True if the pasteboard holds promised / lazily-provided representations we
    /// cannot snapshot+restore without data loss. If so, the destructive Cmd-C
    /// fallback must be skipped.
    private static func pasteboardHasUnrecoverableContents(_ pasteboard: NSPasteboard) -> Bool {
        guard let items = pasteboard.pasteboardItems else { return false }
        for item in items {
            for type in item.types {
                // A declared promise UTI -> lazy/unrecoverable.
                if promiseTypeIdentifiers.contains(type.rawValue) { return true }
                // A declared type whose data is nil at read time is also lazy /
                // promised (the provider hasn't materialized it), so a restore
                // would drop it.
                if item.data(forType: type) == nil { return true }
            }
        }
        return false
    }

    /// After a clipboard-fallback restore, watch briefly for a LATE synthetic
    /// Cmd-C landing on top of the restored clipboard and, if it does, restore the
    /// saved snapshot once more. Non-blocking (uses async-after, no run-loop spin).
    private static func scheduleLateRestoreGuard(_ pasteboard: NSPasteboard,
                                                 saved: [PasteboardItemSnapshot],
                                                 changeCountAfterRestore: Int) {
        // Re-fetch the singleton inside the closure rather than capturing the
        // non-Sendable `NSPasteboard` instance; `.general` is the same object and
        // the closure always runs on the main thread.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            let pb = NSPasteboard.general
            // If the change-count moved since our restore, a late copy landed and
            // overwrote the user's clipboard — put their data back.
            if pb.changeCount != changeCountAfterRestore {
                restorePasteboard(pb, from: saved)
            }
        }
    }

    /// A retained snapshot of one pasteboard item: every type's raw data.
    /// `Sendable` (its fields are value types) so the late-restore guard closure
    /// can carry it across the main-queue hop without a data-race diagnostic.
    private struct PasteboardItemSnapshot: Sendable {
        let entries: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    /// Capture every item + every representation currently on the pasteboard.
    private static func snapshotPasteboard(_ pasteboard: NSPasteboard) -> [PasteboardItemSnapshot] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            var entries: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                if let data = item.data(forType: type) {
                    entries.append((type, data))
                }
            }
            return PasteboardItemSnapshot(entries: entries)
        }
    }

    /// Restore a previously captured pasteboard snapshot verbatim.
    private static func restorePasteboard(_ pasteboard: NSPasteboard,
                                          from snapshots: [PasteboardItemSnapshot]) {
        pasteboard.clearContents()
        guard !snapshots.isEmpty else { return }
        let newItems: [NSPasteboardItem] = snapshots.map { snapshot in
            let item = NSPasteboardItem()
            for entry in snapshot.entries {
                item.setData(entry.data, forType: entry.type)
            }
            return item
        }
        pasteboard.writeObjects(newItems)
    }

    /// Post a synthetic Cmd-C key down/up to the frontmost application.
    private static func sendCopyKeystroke() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cKey = CGKeyCode(kVK_ANSI_C)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: cKey, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    /// Poll the pasteboard for up to ~0.4s waiting for the synthetic copy to
    /// land (detected via a bumped `changeCount`), then return the string.
    ///
    /// IMPORTANT: this does NOT spin the main run loop. Re-entering the main run
    /// loop here (the previous `RunLoop.current.run`) re-processed events while
    /// inside a notification handler — letting the Kokoro/Azure word timers fire
    /// re-entrantly and queued read/stop notifications be delivered mid-capture,
    /// which could interleave a fresh read()/stop() with the capture and stutter
    /// the UI. The synthetic Cmd-C is delivered to the FRONTMOST app's own run
    /// loop (a separate process), so the target services it regardless of whether
    /// we pump ours; a plain bounded sleep is sufficient and non-reentrant.
    private static func waitForCopiedString(_ pasteboard: NSPasteboard,
                                            sinceChangeCount before: Int) -> String? {
        let deadline = Date().addingTimeInterval(0.4)
        while Date() < deadline {
            if pasteboard.changeCount != before {
                return pasteboard.string(forType: .string)
            }
            // Sleep briefly WITHOUT pumping the main run loop, so no timers or
            // queued notifications fire re-entrantly during the capture.
            usleep(20_000) // 20 ms
        }
        // The change count may not bump in every app; make a final best-effort
        // read in case the string is already there.
        if pasteboard.changeCount != before {
            return pasteboard.string(forType: .string)
        }
        return nil
    }

    // MARK: - Helpers

    /// Treat nil / whitespace-only selections as "no selection".
    private static func isEffectivelyEmpty(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Open the System Settings -> Privacy & Security -> Accessibility pane.
    private static func openAccessibilitySettingsPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Convert an AX (top-left-origin, primary-display-flipped) rect to a Cocoa
    /// bottom-left-origin screen rect.
    private static func convertFromFlippedScreenRect(_ rect: CGRect) -> CGRect {
        guard let primary = NSScreen.screens.first else { return rect }
        let primaryHeight = primary.frame.maxY
        return CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}
