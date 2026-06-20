//
//  MenuBarController.swift
//  ReadFlow
//
//  Owns the NSStatusItem and its menu (Read Selection, Read Clipboard, Stop,
//  Engine submenu, Speed submenu, Open PDF…, Settings, Quit). Reflects
//  TTSPlaybackState in the status-item icon and bridges menu actions to the
//  manager / notifications.
//
//  All members are @MainActor — this type is UI-bound.
//

import AppKit
import UniformTypeIdentifiers

@MainActor
final class MenuBarController {

    private let manager: TTSEngineManager
    private let settings: Settings

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    // Menu items we mutate when state / settings change.
    private var readItem: NSMenuItem!
    private var readClipboardItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var autoChipItem: NSMenuItem!
    private var engineSubmenu: NSMenu!
    private var speedSubmenu: NSMenu!

    // Discrete speed presets surfaced in the menu.
    private let speedPresets: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    private var currentState: TTSPlaybackState = .idle

    init(manager: TTSEngineManager, settings: Settings) {
        self.manager = manager
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        configureStatusButton()
        buildMenu()
        statusItem.menu = menu

        updateState(.idle)

        // Reflect settings changes (engine/rate/voice) live in the menu's
        // checkmarks. Posted on the main thread by Settings.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: .readFlowSettingsChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public state reflection

    /// Reflect the current playback state in the icon and enabled/disabled
    /// menu items. Called by the manager via its `onStateChange`.
    func updateState(_ state: TTSPlaybackState) {
        currentState = state

        let isActive: Bool
        switch state {
        case .preparing, .speaking, .paused:
            isActive = true
        case .idle, .finished:
            isActive = false
        }

        // Icon: filled while actively reading, outline while idle.
        if let button = statusItem.button {
            let symbol = isActive ? "speaker.wave.2.fill" : "speaker.wave.2"
            let description = isActive ? "ReadFlow — reading" : "ReadFlow"
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description) {
                image.isTemplate = true
                button.image = image
            } else {
                // Fallback if SF Symbols are unavailable: a text glyph.
                button.image = nil
                button.title = isActive ? "▶︎" : "RF"
            }
        }

        stopItem.isEnabled = isActive
    }

    // MARK: - Setup

    private func configureStatusButton() {
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "speaker.wave.2",
                                   accessibilityDescription: "ReadFlow") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "RF"
            }
        }
    }

    private func buildMenu() {
        menu.autoenablesItems = false

        // --- Read actions ---
        readItem = NSMenuItem(title: "Read Selection",
                              action: #selector(readSelection),
                              keyEquivalent: "")
        readItem.target = self
        menu.addItem(readItem)

        readClipboardItem = NSMenuItem(title: "Read Clipboard",
                                       action: #selector(readClipboard),
                                       keyEquivalent: "")
        readClipboardItem.target = self
        menu.addItem(readClipboardItem)

        stopItem = NSMenuItem(title: "Stop",
                              action: #selector(stopReading),
                              keyEquivalent: "")
        stopItem.target = self
        menu.addItem(stopItem)

        menu.addItem(.separator())

        // --- Read on Highlight (auto floating chip) ---
        autoChipItem = NSMenuItem(title: "Read on Highlight",
                                  action: #selector(toggleAutoChip),
                                  keyEquivalent: "")
        autoChipItem.target = self
        let chipOn = UserDefaults.standard.object(forKey: SelectionChipController.enabledKey) as? Bool ?? true
        autoChipItem.state = chipOn ? .on : .off
        menu.addItem(autoChipItem)

        menu.addItem(.separator())

        // --- Open PDF… ---
        let openPDFItem = NSMenuItem(title: "Open PDF…",
                                     action: #selector(openPDF),
                                     keyEquivalent: "")
        openPDFItem.target = self
        menu.addItem(openPDFItem)

        menu.addItem(.separator())

        // --- Engine submenu ---
        let engineParent = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        engineSubmenu = NSMenu(title: "Engine")
        engineSubmenu.autoenablesItems = false
        for kind in EngineKind.allCases {
            let item = NSMenuItem(title: kind.displayName,
                                  action: #selector(selectEngine(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            engineSubmenu.addItem(item)
        }
        engineParent.submenu = engineSubmenu
        menu.addItem(engineParent)

        // --- Speed submenu ---
        let speedParent = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
        speedSubmenu = NSMenu(title: "Speed")
        speedSubmenu.autoenablesItems = false
        for preset in speedPresets {
            let item = NSMenuItem(title: speedLabel(preset),
                                  action: #selector(selectSpeed(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = preset
            speedSubmenu.addItem(item)
        }
        speedParent.submenu = speedSubmenu
        menu.addItem(speedParent)

        menu.addItem(.separator())

        // --- Quit ---
        let quitItem = NSMenuItem(title: "Quit ReadFlow",
                                  action: #selector(quit),
                                  keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        refreshChecks()
    }

    // MARK: - Menu actions

    @objc private func readSelection() {
        // Capture happens in the AppDelegate's notification handler so the
        // hotkey and menu share one code path.
        NotificationCenter.default.post(name: .readFlowReadSelection, object: nil)
    }

    @objc private func readClipboard() {
        let pasteboard = NSPasteboard.general
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            presentInfo(title: "Nothing to Read",
                        message: "The clipboard doesn't contain any text.")
            return
        }
        manager.read(text)
    }

    @objc private func stopReading() {
        manager.stop()
        NotificationCenter.default.post(name: .readFlowStop, object: nil)
    }

    @objc private func toggleAutoChip() {
        let cur = UserDefaults.standard.object(forKey: SelectionChipController.enabledKey) as? Bool ?? true
        UserDefaults.standard.set(!cur, forKey: SelectionChipController.enabledKey)
        autoChipItem.state = !cur ? .on : .off
    }

    @objc private func openPDF() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let pdfType = UTType(filenameExtension: "pdf") {
            panel.allowedContentTypes = [pdfType]
        }
        panel.prompt = "Read"
        panel.message = "Choose a PDF to read aloud."

        // Bring the panel to the front since we're an accessory app.
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let text = PDFReader.extractText(from: url),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            presentInfo(title: "Couldn't Read PDF",
                        message: "No readable text was found in \(url.lastPathComponent).")
            return
        }
        manager.read(text)
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = EngineKind(rawValue: raw) else { return }
        settings.engineKind = kind
        // Settings posts .readFlowSettingsChanged → refreshChecks() runs.
        // Warm the newly selected engine so the next read is instant.
        manager.prewarm()
    }

    @objc private func selectSpeed(_ sender: NSMenuItem) {
        guard let rate = sender.representedObject as? Double else { return }
        settings.rate = rate
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Settings reflection

    @objc private func settingsChanged() {
        refreshChecks()
    }

    private func refreshChecks() {
        // Engine checkmarks.
        let currentEngine = settings.engineKind.rawValue
        for item in engineSubmenu.items {
            if let raw = item.representedObject as? String {
                item.state = (raw == currentEngine) ? .on : .off
            }
        }

        // Speed checkmark — mark the preset closest to the stored rate.
        let currentRate = settings.rate
        let nearest = speedPresets.min(by: { abs($0 - currentRate) < abs($1 - currentRate) })
        for item in speedSubmenu.items {
            if let preset = item.representedObject as? Double {
                item.state = (preset == nearest) ? .on : .off
            }
        }
    }

    // MARK: - Helpers

    private func speedLabel(_ rate: Double) -> String {
        if rate == 1.0 { return "Normal (1.0×)" }
        // Trim trailing zero for clean labels: 1.5 not 1.50.
        let formatted = String(format: "%g", rate)
        return "\(formatted)×"
    }

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
