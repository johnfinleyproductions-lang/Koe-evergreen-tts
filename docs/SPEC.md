# ReadFlow — Authoritative Build Spec

ReadFlow is a Read&Write-Gold-style read-aloud tool for a user with reading
difficulty (dyslexia-friendly). It speaks selected text aloud with natural
voices and a moving, word-by-word highlight in a floating HUD, usable anywhere
on macOS. It is a **menu-bar agent** (`LSUIElement`, no Dock icon).

**User value above everything: reliable, never silently fails, works the
instant it launches.** The System voice is the instant-on default so the app is
useful before Kokoro or Azure are configured.

---

## 0. Hard environment constraints (verified)

- Swift **6.2.3**, **Command Line Tools only**. No full Xcode → **no
  `xcodebuild`, no `.xcodeproj`, no `pbxproj`.** Do not generate them.
- Build is a **SwiftPM executable** (`swift build`) assembled into a `.app`
  bundle by `scripts/build_app.sh`.
- macOS **26.2**, Apple Silicon (**arm64**). Deployment target **`.macOS(.v13)`**
  (required for the SwiftUI `Layout` API used by `WrappingHStack`).
- **No external SwiftPM dependencies.** Apple frameworks only: AppKit, SwiftUI,
  AVFoundation, PDFKit, Vision, Carbon, Security, Combine.
- Project path **contains a space**:
  `"/Users/tylerfreund/Desktop/Coding Projects/ReadFlow"`. Always quote it.

---

## 1. File manifest

Every path is relative to the project root. Files marked **DONE** already exist
and compile; the rest are to be implemented by downstream agents **against the
exact public surface listed in §3** so the module links.

```
Package.swift                                   DONE
docs/SPEC.md                                    DONE (this file)
README.md
scripts/build_app.sh
kokoro/docker-compose.yml
Sources/ReadFlow/
  Core/
    Contracts.swift                             DONE — single source of truth
    Settings.swift
  App/
    ReadFlowApp.swift                           @main entry point
    MenuBarController.swift
    HotKeyManager.swift
  Capture/
    AccessibilityBridge.swift
    PDFReader.swift
  TTS/
    TTSEngineManager.swift
    SystemAVSpeechEngine.swift
    KokoroEngine.swift
    AzureNeuralEngine.swift
  UI/
    ReaderHUDWindow.swift
    WordFlowView.swift
```

---

## 2. The shared contract (already fixed — do not renegotiate)

`Core/Contracts.swift` is the **single source of truth**. It compiles on its own
(verified with `swift build`). All shared types live there:

- `Word` — `{ text: String, range: Range<String.Index>, index: Int }`.
- `WordTokenizer` — `tokenize(_:) -> [Word]` and
  `wordIndex(forUTF16Offset:in:words:) -> Int?`. **This is the canonical
  word-splitting rule (§4). Manager AND HUD MUST both go through it.**
- `WordTimestamp` — `{ wordIndex, start, end }` (file-engine timing).
- `TTSResult` — `{ audioData: Data, timestamps: [WordTimestamp] }` (internal
  plumbing for Kokoro/Azure only; the manager never sees it).
- `EngineKind` — `.system | .kokoro | .azure` (+ `displayName`). Default
  `.system`.
- `TTSPlaybackState` — `.idle | .preparing | .speaking | .paused | .finished`.
- `TTSError` — actionable `LocalizedError` cases.
- `TTSEngine` — the one protocol (exact signatures in §3.7).
- `Notification.Name` extensions: `.readFlowReadSelection`, `.readFlowStop`,
  `.readFlowTogglePlayPause`, `.readFlowSettingsChanged`.
- `SettingsKey` — all UserDefaults keys + Azure Keychain service/account.

**The `Int` in `onWord` is an index into the `[Word]` array the manager
computes once from the source text and shares with the HUD.** All three engines
emit indices in that same space.

---

## 3. Per-file responsibilities + exact public surface

Each file must expose AT LEAST the public/internal types and members below so
the module links. Implementers may add private helpers freely.

### 3.1 `Core/Settings.swift`
**Responsibility:** UserDefaults-backed `ObservableObject` holding all user
preferences (engine, rate, voices, region, font/spacing, Kokoro base URL) plus
the only gateway to the Azure key in the Keychain. Posts
`.readFlowSettingsChanged` when playback-affecting values change.

```swift
@MainActor
final class Settings: ObservableObject {
    static let shared: Settings
    @Published var engineKind: EngineKind
    @Published var rate: Double                 // 0.5...2.0, clamped
    @Published var systemVoiceID: String        // "" => default voice
    @Published var kokoroVoice: String          // e.g. "af_sky"
    @Published var azureVoice: String           // e.g. "en-US-JennyNeural"
    @Published var azureRegion: String          // e.g. "eastus"
    @Published var fontName: String             // "" => system; "OpenDyslexic"
    @Published var fontSize: Double
    @Published var lineHeight: Double            // multiplier
    @Published var letterSpacing: Double         // pt
    @Published var kokoroBaseURL: String         // default "http://localhost:8880"

    func loadAzureKey() -> String?               // Keychain read; never logs
    @discardableResult func saveAzureKey(_ key: String) -> Bool
    @discardableResult func deleteAzureKey() -> Bool
}
```
Uses `SettingsKey.*` constants. Keychain via `Security` with service
`SettingsKey.azureKeychainService`, account `…azureKeychainAccount`. **The
Azure key is NEVER written to UserDefaults and NEVER logged.**

### 3.2 `App/ReadFlowApp.swift`
**Responsibility:** Process entry point. AppKit lifecycle (NOT SwiftUI `App`
scene, so we control `LSUIElement` + no main window). Owns the
`MenuBarController`, `HotKeyManager`, and `TTSEngineManager`; calls
`prewarm()` on launch; sets activation policy to `.accessory`.

```swift
@main
enum ReadFlowMain {
    static func main()                          // builds NSApplication + delegate, runs
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification)
    func applicationWillTerminate(_ notification: Notification)
}
```
Sets `NSApp.setActivationPolicy(.accessory)`. Instantiates and retains the
controllers/manager. Registers observers for `.readFlowReadSelection` /
`.readFlowStop` / `.readFlowTogglePlayPause`.

### 3.3 `App/MenuBarController.swift`
**Responsibility:** Owns the `NSStatusItem` and its menu (Read Selection,
Stop, engine picker, rate, Open PDF…, Settings, Quit). Reflects
`TTSPlaybackState` in the menu/icon. Bridges menu actions to notifications /
the manager.

```swift
@MainActor
final class MenuBarController {
    init(manager: TTSEngineManager, settings: Settings)
    func updateState(_ state: TTSPlaybackState)
}
```

### 3.4 `App/HotKeyManager.swift`
**Responsibility:** Registers the global hotkey **Option-R** via Carbon
`RegisterEventHotKey` and posts `.readFlowReadSelection` when fired.
Unregisters cleanly on deinit. No retain cycles in the Carbon callback.

```swift
final class HotKeyManager {
    init()
    func register()                             // Option-R
    func unregister()
}
```
Uses `kVK_ANSI_R` + `optionKey`. Carbon event handler posts the notification on
the main thread.

### 3.5 `Capture/AccessibilityBridge.swift`
**Responsibility:** Returns the user's currently selected text. **Try AX first**
(`AXUIElementCreateSystemWide` → `kAXFocusedUIElementAttribute` →
`kAXSelectedTextAttribute`); **clipboard-copy fallback** that saves the user's
clipboard, sends ⌘C, reads, then **restores the clipboard** (never lose user
data). Reports whether Accessibility permission is granted.

```swift
enum AccessibilityBridge {
    static func selectedText() -> String?        // AX first, clipboard fallback
    static func isAccessibilityTrusted() -> Bool
    static func promptForAccessibilityIfNeeded()  // opens System Settings pane
}
```

### 3.6 `Capture/PDFReader.swift`
**Responsibility:** Extract readable text from a PDF via **PDFKit**; fall back
to **Vision `VNRecognizeTextRequest` OCR** for scanned/image pages that yield no
text. Returns plain text ready for tokenization.

```swift
enum PDFReader {
    static func extractText(from url: URL) -> String?
    static func extractText(from url: URL, pageIndex: Int) -> String?
}
```
OCR fallback rasterizes the page (`PDFPage.thumbnail`/`CGImage`) and runs
`VNRecognizeTextRequest` (`.accurate`, language correction on).

### 3.7 `TTS/TTSEngineManager.swift`
**Responsibility:** The orchestrator the rest of the app talks to. Picks the
active engine from `Settings.engineKind`, **tokenizes the text ONCE** with
`WordTokenizer.tokenize`, shares the `[Word]` with the HUD, starts the engine,
and forwards engine callbacks to the HUD/menu. Handles graceful degradation
(Kokoro/Azure failure → user message + offer System voice). **Does not own any
audio file** — each engine owns its own playback.

```swift
@MainActor
final class TTSEngineManager {
    init(settings: Settings, hud: ReaderHUDWindow)
    var state: TTSPlaybackState { get }

    func prewarm()                               // prewarm active engine
    func read(_ text: String)                    // tokenize → HUD → engine.speak
    func togglePlayPause()
    func stop()

    // State observation for the menu/icon:
    var onStateChange: ((TTSPlaybackState) -> Void)?
}
```
Flow of `read(_:)`:
1. `let words = WordTokenizer.tokenize(text)`; if empty → surface
   `TTSError.emptyText` and stop.
2. `hud.present(words: words, sourceText: text)`.
3. `engine.speak(text:rate:onWord:onStateChange:onFinish:onError:)`.
4. `onWord` → `hud.highlight(index:)`; `onStateChange` → update menu + HUD
   controls; `onError` → `presentError` (offer System fallback when the failing
   engine isn't already System).

The manager constructs engines lazily and caches them. It selects the engine by
`Settings.engineKind`; on `.azure` with no Keychain key it surfaces
`TTSError.missingCredential(.azure)` BEFORE attempting playback.

### 3.8 `TTS/SystemAVSpeechEngine.swift`
**Responsibility:** Instant-on default. Wraps `AVSpeechSynthesizer`; maps
`speechSynthesizer(_:willSpeakRangeOfSpeechString:utterance:)` `NSRange`s to
shared word indices via `WordTokenizer.wordIndex(forUTF16Offset:in:words:)`.
Honors `systemVoiceID` and `rate`.

```swift
final class SystemAVSpeechEngine: NSObject, TTSEngine, AVSpeechSynthesizerDelegate {
    var kind: EngineKind { .system }
    init(voiceID: String?)
    func prewarm()
    func speak(text:rate:onWord:onStateChange:onFinish:onError:)   // per protocol
    func stop()
}
```
Tokenizes the SAME `text` internally to resolve indices. Maps `rate` (1.0
natural) onto `AVSpeechUtterance.rate` (`AVSpeechUtteranceDefaultSpeechRate`
scaled, clamped to min/max). Fires callbacks on `DispatchQueue.main`.

### 3.9 `TTS/KokoroEngine.swift`
**Responsibility:** Natural-voice upgrade via **local Kokoro-FastAPI**
`POST {baseURL}/dev/captioned_speech` → base64 WAV + native word timestamps.
Decodes audio, aligns server tokens to the shared tokenization, plays via an
internal `AVAudioPlayer`, and drives `onWord` from a high-frequency timer off
the player's clock.

```swift
final class KokoroEngine: NSObject, TTSEngine, AVAudioPlayerDelegate {
    var kind: EngineKind { .kokoro }
    init(baseURL: URL, voice: String)
    func prewarm()                               // ping server; non-blocking
    func speak(text:rate:onWord:onStateChange:onFinish:onError:)   // per protocol
    func stop()
}
```
Build `TTSResult { audioData, timestamps }` (timestamps `wordIndex` aligned to
shared `[Word]`). State: `.preparing` during fetch/decode → `.speaking` on
play. Server down → `TTSError.engineUnavailable(.kokoro, …)`. **High-frequency
word timer (~30–60 Hz) compares `player.currentTime` to each `start` and fires
the next pending `onWord`; invalidate the timer in `stop()` / on finish; use
`[weak self]`.**

### 3.10 `TTS/AzureNeuralEngine.swift`
**Responsibility:** Optional cloud upgrade via **Azure Neural TTS REST**: one
call for audio, one for `WordBoundary` JSON (100-ns ticks → seconds). Key read
from **Keychain only** (`Settings.loadAzureKey()`); **never hardcoded, never
logged.** Plays via internal `AVAudioPlayer` with the same timer-driven
`onWord` approach as Kokoro.

```swift
final class AzureNeuralEngine: NSObject, TTSEngine, AVAudioPlayerDelegate {
    var kind: EngineKind { .azure }
    init(region: String, voice: String, keyProvider: @escaping () -> String?)
    func prewarm()
    func speak(text:rate:onWord:onStateChange:onFinish:onError:)   // per protocol
    func stop()
}
```
`keyProvider` is `Settings.shared.loadAzureKey`. Convert WordBoundary ticks
(`audioOffset / 10_000_000.0` seconds) to `WordTimestamp` and align `wordIndex`
to the shared tokenization. No key → `TTSError.missingCredential(.azure)`.

### 3.11 `UI/ReaderHUDWindow.swift`
**Responsibility:** A borderless, **non-activating, click-through** floating
HUD (`NSWindow` + `NSVisualEffectView` frosted glass, high window level,
`.canJoinAllSpaces`) hosting the SwiftUI `WordFlowView`. Owns the
`ObservableObject` view model that the manager pushes words/highlight/state
into. Shows play/pause + speed.

```swift
@MainActor
final class ReaderHUDWindow {
    init(settings: Settings)
    func present(words: [Word], sourceText: String)   // load + show, reset highlight
    func highlight(index: Int)                         // move highlight
    func setState(_ state: TTSPlaybackState)
    func hide()

    // Controls forwarded to the manager:
    var onTogglePlayPause: (() -> Void)?
    var onRateChange: ((Double) -> Void)?
}
```
Window: `styleMask = [.borderless]`, `level = .floating`+ (or
`.statusBar`/`.screenSaver`-class high level), `isOpaque = false`,
`backgroundColor = .clear`, `ignoresMouseEvents` toggled so the text area is
interactive but the window never steals focus (`canBecomeKey = false` via a
non-activating panel or `NSWindow` subclass). Appears across Spaces via
`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`.

### 3.12 `UI/WordFlowView.swift`
**Responsibility:** The SwiftUI surface that renders the words and the moving
per-word background highlight. Per-word backgrounds require a **custom
`Layout` (`WrappingHStack`)** — `Text`+`AttributedString` cannot track per-word
backgrounds. Honors OpenDyslexic font hook, size, line-height, letter-spacing.

```swift
struct WordFlowView: View {
    @ObservedObject var model: ReaderHUDModel     // words + currentIndex + state
    var body: some View { … }
}

/// SwiftUI Layout for wrapping word chips (macOS 13+).
struct WrappingHStack: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize,
                      subviews: Subviews,
                      cache: inout ()) -> CGSize
    func placeSubviews(in bounds: CGRect,
                       proposal: ProposedViewSize,
                       subviews: Subviews,
                       cache: inout ())
}

@MainActor
final class ReaderHUDModel: ObservableObject {
    @Published var words: [Word]
    @Published var currentIndex: Int?            // highlighted word
    @Published var state: TTSPlaybackState
    // font/spacing read from Settings
}
```
Each word renders as a chip; the chip at `currentIndex` gets a highlight
background. `ReaderHUDModel` is owned by `ReaderHUDWindow` and the same instance
is mutated by `highlight(index:)`.

---

## 4. Word-tokenization rule (shared by manager + HUD)

**Defined once in `WordTokenizer.tokenize` (Contracts.swift). Both the manager
and the HUD MUST use it so indices line up.**

- A **word** = a maximal run of characters that are NOT whitespace/newline
  (`CharacterSet.whitespacesAndNewlines`).
- Leading/trailing whitespace is skipped and never becomes a word.
- Attached punctuation stays glued (`"Hello,"` is one word).
- `Word.range` is computed against the **exact** string passed in — no
  normalization, no trimming of the source. **If any component normalizes the
  text (e.g. collapsing whitespace before sending to an engine), it MUST
  tokenize the SAME normalized string it passes to the engine.** The manager
  tokenizes the exact string it hands to `engine.speak`.
- Engines convert their native units to a word index:
  - **System:** delegate `NSRange.location` →
    `WordTokenizer.wordIndex(forUTF16Offset:in:words:)`.
  - **Kokoro/Azure:** align their returned per-word token sequence positionally
    to the shared `[Word]` (same order); fill `WordTimestamp.wordIndex`. If a
    server token cannot be aligned, map to the nearest index rather than drop
    the callback.

This guarantees `onWord(i)` always refers to `model.words[i]` in the HUD.

---

## 5. Build & bundle plan

### 5.1 Compile
```sh
cd "/Users/tylerfreund/Desktop/Coding Projects/ReadFlow"
swift build -c release
```
Produces `.build/release/ReadFlow` (arm64 executable).

### 5.2 Assemble `ReadFlow.app` (`scripts/build_app.sh`)
The script (quote the space-containing path everywhere):
1. `swift build -c release`.
2. Create bundle layout:
   ```
   ReadFlow.app/Contents/MacOS/ReadFlow      (copied executable)
   ReadFlow.app/Contents/Info.plist
   ReadFlow.app/Contents/Resources/          (icon, OpenDyslexic font if bundled)
   ```
3. Write **Info.plist** with:
   - `CFBundleExecutable = ReadFlow`,
     `CFBundleIdentifier = com.readflow.app`,
     `CFBundleName = ReadFlow`, `CFBundlePackageType = APPL`,
     `CFBundleShortVersionString`, `CFBundleVersion`.
   - **`LSUIElement = true`** (agent app, no Dock icon).
   - `LSMinimumSystemVersion = 13.0`.
   - `NSMicrophoneUsageDescription` not required; **no** mic. (TTS only.)
4. **Ad-hoc codesign** (CLT only — no Developer ID needed for local use):
   ```sh
   codesign --force --deep --sign - \
     --entitlements ReadFlow.entitlements "ReadFlow.app"
   ```
   Entitlements file enables Apple Events / Accessibility client usage as
   needed (e.g. `com.apple.security.automation.apple-events`). Keep the app
   **unsandboxed** so AX + global hotkey + clipboard work.
5. Print Accessibility-grant instructions (see §5.3).

### 5.3 Accessibility grant (first run)
ReadFlow needs **Accessibility** permission to read selected text via AX and to
send the ⌘C fallback:
> System Settings → Privacy & Security → **Accessibility** → enable
> **ReadFlow**.

`AccessibilityBridge.promptForAccessibilityIfNeeded()` triggers the system
prompt and can open the pane. The app must degrade gracefully if denied (clear
message; still works on text passed via Open PDF…).

### 5.4 Kokoro (optional, `kokoro/docker-compose.yml`)
Runs Kokoro-FastAPI locally on **:8880** exposing
`/dev/captioned_speech`. `docker compose up -d` in `kokoro/`. The app's
`kokoroBaseURL` defaults to `http://localhost:8880`. If the container isn't
running, `KokoroEngine.prewarm()`/`speak` fail with
`engineUnavailable(.kokoro, …)` and the manager offers the System voice.

---

## 6. Quality bar (enforced in review)

- **All UI mutations on the main thread.** Engines dispatch all four callbacks
  on `DispatchQueue.main`.
- **No retain cycles:** `[weak self]` in closures, timers, Carbon/AV delegates;
  `invalidate()` every timer in `stop()`/finish/`deinit`.
- **Graceful degradation:** Kokoro/Azure down → clear message + offer System
  voice; AX denied → guide to System Settings.
- **No secrets in code or logs.** Azure key only in Keychain, only via
  `Settings`.
- **Swift 6 concurrency:** `@MainActor` on UI-bound types; avoid data races;
  keep it **compiling under the default CLT toolchain** (no special flags).
- **Never silently fail:** every failure path reaches `onError` → user-visible
  message.

---

## 7. Implementation order (suggested for downstream agents)

1. `Core/Settings.swift` (everything reads it).
2. `UI/WordFlowView.swift` + `UI/ReaderHUDWindow.swift` (visible surface).
3. `TTS/SystemAVSpeechEngine.swift` (instant-on; unblocks end-to-end).
4. `TTS/TTSEngineManager.swift` (wires capture → engine → HUD).
5. `Capture/AccessibilityBridge.swift`, `App/HotKeyManager.swift`,
   `App/MenuBarController.swift`, `App/ReadFlowApp.swift` (make it launchable).
6. `TTS/KokoroEngine.swift`, `TTS/AzureNeuralEngine.swift` (upgrades).
7. `Capture/PDFReader.swift`.
8. `scripts/build_app.sh`, `kokoro/docker-compose.yml`, `README.md`.

After step 5 the app launches and reads with the System voice and live
highlight — the minimum that delivers user value.
