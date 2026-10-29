# Koe for iPad — port plan

Written 2026-10-29 from a live look at the repo, the Mac's Xcode state and the
Core Books lane. Not a 1:1 port: the iPad gets Listen, Books and Pencil-native
reading, plus iPad-only extras. Capture (AX chip, Services, ⌥R, the browser
extension's loopback server) stays Mac-only.

## 1. What carries over (measured)

33 Swift files; 14 import AppKit/Cocoa.

| Folder   | files | AppKit | Verdict |
|----------|------:|-------:|---------|
| Core/    | 4 | 0 | as-is (ReadingPosition, ReadingHighlights, tokenizer) |
| TTS/     | 5 | 1 | as-is: KokoroEngine (URLSession + AVAudioPlayer, LAN `/dev/captioned_speech` word timestamps), SystemAVSpeechEngine; the one AppKit file is the Mac switcher UI |
| Books/   | 9 | 3 | store, models, connection (WKWebView sign-in + URLSession), player, highlights model as-is; `KoePDFPageView` (NSViewRepresentable→UIViewRepresentable, PDFView exists on iOS), BooksView, HighlightControls need UIKit twins |
| UI/      | 8 | 5 | WordFlowView, HighlightingTextView (NSTextView→UITextView), KoeTheme fonts (NSFont→UIFont), HUD window need twins |
| Capture/ | 4 | 2 | dropped on iPad (Share extension + paste + Files instead) |
| App/     | 3 | 3 | new SwiftUI `App` entry for iPad |

The browser extension's `extractArticle()` in `browser-extension/content.js`
can run unchanged inside a WKWebView on iPad for "read this page".

## 2. Tooling (what the Mac has on 2026-10-29)

- `/Applications/Xcode.app` = **16.3** (iOS 18.4 SDK). `xcode-select` points at
  the Command Line Tools. **0** codesigning identities. No Apple ID signed into
  Xcode. Tyler's iPhone 16 is paired to Xcode; the iPad is not.
- **Need Xcode 26.x**: an iPad on iPadOS 26 is not deployable from Xcode 16,
  and App Store uploads have required Xcode 26 since 2026-04-28. macOS 26.2 is
  fine. Keep 16.3 around; nothing else needs it.
- **Signing**: sign in with the Apple ID in Xcode → "Personal Team" (free):
  installs on your own iPad, app expires every 7 days, no iCloud/push. The
  $99/yr program gives 1-year profiles + TestFlight. Decide in Phase 0.
- **Project**: SwiftPM cannot produce an iOS app bundle, so add an Xcode
  project with an iPad app target that depends on the local package.
  Try **XcodeGen** (`ios/project.yml`, local package via `packages: … path:`)
  first; its issue #1575 (open, Aug 2025, 2.44.1) reports local packages
  generated as plain file references. If it bites: a hand-made `.xcodeproj`
  committed once, or Tuist.
- **Package split**: `Package.swift` → `platforms: [.macOS(.v13), .iOS(.v17)]`
  and three targets: `KoeCore` (platform-neutral), `KoeMac` (AppKit, today's
  executable), `KoeiPad` (UIKit/SwiftUI). `scripts/build_app.sh` unchanged.

## 3. iPad landmines (verified against Apple docs/forums)

- **Local network privacy**: add `NSLocalNetworkUsageDescription` to Info.plist
  or calls to `192.168.4.200` (Kokoro :8880, Core :3000) fail. iPadOS shows
  the prompt on the first LAN call.
- **ATS**: IP-literal `http://` to the LAN is exempt, same as on the Mac.
  Away from home → Tailscale (house rule: no public exposure).
- **Audio**: set `AVAudioSession` to `.playback` and add `UIBackgroundModes:
  audio`, or reading stops when the screen locks. Add Now Playing + remote
  controls (lock screen play/pause).
- **Pencil model matters**: 1st-gen / USB-C Pencil = no gestures; Pencil 2 =
  double-tap; Pencil Pro = squeeze (iPadOS 17.5+), haptics, barrel roll;
  **hover** needs iPad Air M2/M3 (or iPad Pro) with Pencil 2/Pro.
- **Pencil on PDF pages**: use PDFKit's `PDFPageOverlayViewProvider` (iOS 16+,
  WWDC22 session 10089) returning one `PKCanvasView` per page. Set
  `usePageViewController = false` *before* assigning the document or touches go
  to scrolling; match `contentScaleFactor` to the zoom or ink blurs.
- **No loopback server**: the extension/`KoeLocalServer` capture path has no
  iPad equivalent. Use a Share extension and the system paste.

## 4. Phases

**Phase 0 — Tooling (half a day).** Install Xcode 26, sign in, pair the iPad,
record iPad model/iPadOS/Pencil model, generate the project, run an empty
KoeiPad app on the device. Exit: app icon on the iPad.

**Phase 1 — Listen.** Paste or share text → The Quiet Hour on iPad: word
highlight + sentence band, Kokoro over the LAN with System-voice fallback, live
speed, resume position, Boards read-only, lock-screen controls.
Exit: a 2,500-word article reads gaplessly with the highlight tracking.

**Phase 2 — Books.** Sign into Core from the iPad, pull the two pilot books,
original PDF pages, Audiobook Narrator + Kokoro voices, follow pages, colour
highlights, offline cache in the app sandbox. Book progress goes through Core's
existing `/api/reader/books/{id}/progress` so Mac and iPad share it.
Exit: ACQ Closer Handbook resumes at the saved word on both devices.

**Phase 3 — Pencil.**
- Tap a word → read from here (model already supports `onSeekToWord`).
- **Reading pen**: drag (or hover, where supported) the tip along a line and
  Koe reads the words under it — `UIHoverGestureRecognizer` on hover-capable
  iPads, pencil-type touch drag everywhere.
- Double-tap / squeeze → play/pause via `UIPencilInteraction`, honouring the
  user's Settings preference (`preferredTapAction` / `preferredSqueezeAction`).
- Drag-select a passage with the Pencil → colour highlight or "Save to Board".
- Ink layer per PDF page: `PKCanvasView` overlay, `PKDrawing` data saved beside
  `highlights.json` in the `.koebook` folder; never touches the PDF bytes.
- Reading ruler / line focus that follows the pen.
- Scribble in note fields (free); PencilKit on the Idea Canvas (later).

**Phase 4 — iPad-only extras.** VisionKit camera page scan → read aloud;
Safari Share extension "Read in Koe"; App Intents/Shortcuts "Read my
clipboard"; Split View drag-in from Safari; Stage Manager window sizes.

## 5. Sync Mac ↔ iPad

- Book progress: Core (above). Already per-user, already live.
- Boards / canvas / Capture highlights / Pencil ink: local on each device
  first. Later: CloudKit, or a small Core endpoint. Not before Phase 3.

## 6. Repos and references (checked 2026-10-29)

| What | Use it for | Notes |
|------|------------|-------|
| mlalma/kokoro-ios (`KokoroSwift`) | on-device Kokoro when off the LAN | MLX Swift, iOS 18+, MIT, token timestamps since 1.0.8; experimental; needs the model file supplied |
| mattmireles/kokoro-coreml (HF) | Core ML Kokoro fallback | author claims faster than MLX; no timestamps mentioned |
| k2-fsa/sherpa-onnx | offline TTS with many voices | Swift API for Kokoro (#1803) + iOS demo (#1812) in its changelog; `ios-swiftui/` has TtsLexicon/TtsPhonemize examples; heavier xcframework |
| AndyHCode/EchoText | packaging reference | offline iOS TTS app on sherpa-onnx |
| Apple WWDC22 10089 + `PDFPageOverlayViewProvider` | Pencil ink over PDF pages | the canonical pattern; see landmines above |
| joshuabourke/pdfeditorsdk | SwiftUI PDFKit + Pencil example | MIT, tiny; read, don't depend |
| Apple `UIPencilInteraction`, Apple Pencil docs, support 120123 | gestures, hover, model compatibility | double-tap, squeeze, `UIPencilHoverPose`, `onPencilSqueeze` |
| nate-parrott/reeeed | Swift reader mode (iOS+macOS) | alternative to our `extractArticle()`; last release 2022. exyte/ReadabilityKit is archived — skip |
| yonaskolb/XcodeGen · tuist/tuist | project generation | XcodeGen first, Tuist fallback |
| antijingoist/opendyslexic | the reader font | still unshipped on Mac (`Resources/` has only the icon) — ship on both |
| Hacking with Swift: AVSpeechSynthesizer highlight | the `willSpeakRangeOfSpeechString` pattern | already what `SystemAVSpeechEngine` does |

## 7. NEEDS YOU

- iPad Air model, iPadOS version, Pencil model (Settings → General → About;
  Settings → Apple Pencil).
- Free Personal Team (7-day re-install from the Mac) or the $99/yr program.
- Install Xcode 26 and sign in with the Apple ID — the sign-in can't be scripted.
