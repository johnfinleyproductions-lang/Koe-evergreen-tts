//
//  ReadFlowApp.swift
//  ReadFlow
//
//  Process entry point. We drive the AppKit lifecycle directly (NOT a SwiftUI
//  `App` scene) so we fully control activation policy (.accessory / LSUIElement
//  at runtime) and never get a main window or Dock icon.
//
//  Owns the TTSEngineManager, ReaderHUDWindow, MenuBarController and
//  HotKeyManager. Prewarms the active engine on launch and registers the
//  cross-component notification observers (.readFlowReadSelection /
//  .readFlowStop / .readFlowTogglePlayPause).
//

import AppKit

@main
enum ReadFlowMain {
    static func main() {
        let app = NSApplication.shared
        // Retain the delegate for the lifetime of the process.
        let delegate = AppDelegate()
        app.delegate = delegate
        // Koe is a real windowed app (Dock icon + window) that ALSO reads the
        // current selection from any app via the global ⌥R hotkey.
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // Strong references — these live for the whole process.
    private var settings: Settings!
    private var hud: ReaderHUDWindow!
    private var manager: TTSEngineManager!
    private var menuBar: MenuBarController!
    private var hotKey: HotKeyManager!
    private var chip: SelectionChipController!
    private var localServer: KoeLocalServer!

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Real windowed app (Dock icon + window).
        NSApp.setActivationPolicy(.regular)

        // Build the object graph (order matters: HUD before manager).
        settings = Settings.shared
        hud = ReaderHUDWindow(settings: settings)
        manager = TTSEngineManager(settings: settings, hud: hud)
        menuBar = MenuBarController(manager: manager, settings: settings)
        hotKey = HotKeyManager()

        // Show the Koe window on launch.
        hud.showWindow()

        // Reflect engine state in the menu-bar icon. Manager invokes this on the
        // main thread (it is @MainActor). [weak self] avoids a retain cycle
        // between manager and controller.
        manager.onStateChange = { [weak self] state in
            self?.menuBar.updateState(state)
        }

        // Cross-component signals.
        let center = NotificationCenter.default
        center.addObserver(self,
                           selector: #selector(handleReadSelection),
                           name: .readFlowReadSelection,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(handleStop),
                           name: .readFlowStop,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(handleTogglePlayPause),
                           name: .readFlowTogglePlayPause,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(handleReadExternal(_:)),
                           name: .readFlowReadExternalText,
                           object: nil)

        // Global hotkey (Option-R). Carbon registration does not need AX.
        hotKey.register()

        // "Read on Highlight": a floating "声 Read in Koe" chip appears next to
        // any text you select in any app — no hotkey needed. (User-toggleable.)
        KoeLog.reset()
        KoeLog.d("launch: AXIsProcessTrusted=\(AccessibilityBridge.isAccessibilityTrusted())")
        chip = SelectionChipController()
        chip.onRead = { [weak self] text in self?.manager.read(text) }
        chip.start()

        // "Read in Koe" right-click Service, available in every app's
        // contextual menu / Services menu when text is selected.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // Local loopback listener so the Koe browser extension can send the
        // text you highlight on a web page (browsers hide selection from AX).
        localServer = KoeLocalServer()
        localServer.start()

        // Warm the active engine so the very first read is instant.
        manager.prewarm()

        // Nudge the user toward granting Accessibility on first launch so the
        // selection-reading path works. Non-blocking; degrades gracefully.
        if !AccessibilityBridge.isAccessibilityTrusted() {
            AccessibilityBridge.promptForAccessibilityIfNeeded()
        }
    }

    /// Re-show the Koe window when the user clicks the Dock icon with no window
    /// open (e.g. after closing it).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { hud?.showWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        hotKey?.unregister()
        chip?.stop()
        localServer?.stop()
        manager?.stop()
    }

    // MARK: - Services ("Read in Koe" right-click)

    /// Invoked by macOS when the user picks "Read in Koe" from the Services /
    /// contextual menu with text selected. Reads the pasteboard string aloud.
    @objc func readSelectionService(_ pboard: NSPasteboard,
                                    userData: String?,
                                    error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        guard let text = pboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        manager.read(text)
    }

    // MARK: - Notification handlers
    //
    // These run on the main thread because the notifications are posted on the
    // main thread (hotkey callback hops to main; menu actions are already main).
    // AppDelegate is @MainActor, so these @objc handlers are main-actor-isolated.

    @objc private func handleReadSelection() {
        readCurrentSelection()
    }

    @objc private func handleStop() {
        manager.stop()
    }

    @objc private func handleTogglePlayPause() {
        manager.togglePlayPause()
    }

    /// Text pushed in from the browser extension via the local listener.
    @objc private func handleReadExternal(_ note: Notification) {
        guard let text = note.object as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        manager.read(text)
    }

    // MARK: - Selection capture

    @MainActor
    private func readCurrentSelection() {
        // AX-first capture with clipboard fallback (handled inside the bridge).
        guard let text = AccessibilityBridge.selectedText(),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {

            // Distinguish "no permission" (actionable) from "nothing selected".
            if !AccessibilityBridge.isAccessibilityTrusted() {
                presentAccessibilityGuidance()
            } else {
                presentInfo(title: "Nothing Selected",
                            message: "Select some text, then press Option-R or use the menu.")
            }
            return
        }
        manager.read(text)
    }

    // MARK: - User-facing messaging (never fail silently)

    @MainActor
    private func presentAccessibilityGuidance() {
        let alert = NSAlert()
        alert.messageText = "ReadFlow Needs Accessibility Access"
        alert.informativeText = """
        To read the text you've selected in other apps, enable ReadFlow under:

        System Settings → Privacy & Security → Accessibility.

        You can still read PDFs and the clipboard without it.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            AccessibilityBridge.promptForAccessibilityIfNeeded()
        }
    }

    @MainActor
    private func presentInfo(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
