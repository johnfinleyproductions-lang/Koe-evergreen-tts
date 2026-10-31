# Koe for iPad — companion plan

Written 2026-10-29, revised the same day after Tyler set the scope.

**Scope.** The iPad is a *companion* to what Koe already holds: the Books that
come from Evergreen Core, and the Boards, Library notebooks, Idea Canvas,
highlights and reading positions that live in the Mac app. It listens, shows,
marks up and resumes. It does **not** capture: no select-text-anywhere chip, no
Services/⌥R, no browser extension, no Share extension, no book import or drop,
no camera scanning. Those stay on the Mac.

## 1. The device (verified)

- **iPad Air 11-inch (M2), 2024**, Starlight, 128 GB, Wi-Fi — part number
  MUWE3LL/A. Running **iPadOS 26.5.2** (checked 2026-10-29). **Hold the iPadOS 27 update** until
  the Mac has Xcode 27 — a device newer than the installed Xcode cannot be
  debugged. Turn off automatic updates on the iPad (Settings → General →
  Software Update → Automatic Updates) until then.
- **Pencil hover: yes** (iPad Air M2 is on Apple's hover list).
- **Compatible pencils: Apple Pencil Pro or Apple Pencil (USB-C) only.** The
  2nd-generation Pencil does not pair with the M2 Air.
  - Pencil Pro: pressure, tilt, hover, double-tap, squeeze, barrel roll,
    haptics, Find My. Every Pencil feature below works.
  - Pencil (USB-C): hover and tilt only. No pressure, no double-tap, no
    squeeze. Gesture features below fall back to on-screen buttons.
- Tyler has the **Pencil Pro** (confirmed 2026-10-29): every gesture below works.

## 2. What carries over (measured on the repo, 33 Swift files, 14 AppKit)

| Folder   | files | AppKit | Verdict |
|----------|------:|-------:|---------|
| Core/    | 4 | 0 | as-is (ReadingPosition, ReadingHighlights, tokenizer) |
| TTS/     | 5 | 1 | as-is: KokoroEngine (URLSession + AVAudioPlayer; LAN `/dev/captioned_speech` word timestamps), SystemAVSpeechEngine; the AppKit file is the Mac voice switcher |
| Books/   | 9 | 3 | store, models, Core connection (WKWebView sign-in), player, highlights model as-is; `KoePDFPageView` becomes `UIViewRepresentable` (PDFView exists on iOS); BooksView + HighlightControls get UIKit twins |
| UI/      | 8 | 5 | WordFlowView, HighlightingTextView (NSTextView→UITextView), KoeTheme fonts (NSFont→UIFont), HUD window → iPad twins |
| Capture/ | 4 | 2 | **not ported** (scope) |
| App/     | 3 | 3 | new SwiftUI `App` entry for iPad |

## 3. Sync is the centre of this port

Books already sync: Core serves them and stores per-user progress
(`/api/reader/books/{id}/progress`). Everything else the companion needs lives
**only in the Mac's UserDefaults**: `readflow.boards` (31 KB), `canvasNotes`
(34 KB), `canvasLinks`, `notebooks`, `librarySections`,
`readingHighlights.v1`, `readingPositions`.

Decision: **Core is the sync server.** Reasons: Koe already signs into Core
with its own session; Core already holds book progress; a free Personal Team
cannot use iCloud/CloudKit entitlements; the house keeps data on the LAN.

Shape (a Core PR, Tyler merges): `GET/PUT /api/koe/state/{key}` per user and
workspace, JSON blob + `updatedAt` + `revision`, last-writer-wins with the
losing copy kept as `{key}.conflict`. Mac Koe pushes on change (debounced);
iPad pulls on launch and when a view opens. Keys = the UserDefaults names
above plus `pencilInk/{bookId}/{page}` later. Size cap 1 MB per key.

## 4. Tooling (the Mac on 2026-10-29)

- Mac: Apple silicon, **macOS 26.2**, 96 GB free. `/Applications/Xcode.app` is
  **16.3** (iOS 18.4 SDK), `xcode-select` points at the CLT, 0 signing
  identities, no Apple ID in Xcode. Tyler's iPhone 16 is paired; the iPad is not.
- **Toolchain rule: the installed Xcode must be at least as new as the iPad's
  OS.** Two paths; **Path A chosen 2026-10-29**:
  - **Path A (now, no download at all): iPad on 26.5.2, Mac on macOS 26.2,
    the already-installed Xcode 16.3 + xtool.** Verified 2026-10-29: Xcode 16.3
    passes its first-launch check, has the iOS 18.4 SDK, and after a 3-line
    concurrency fix the whole package builds with its Swift 6.1 as well as the
    CLT's 6.2.3. Apps built against the 18.4 SDK run on iPadOS 26.5.2. Run
    xtool with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` rather
    than switching `xcode-select`, so the Mac app keeps building with the CLT's
    Swift 6.2.3. Limits: no iOS 26-only APIs in the iPad target until the
    toolchain moves on; `xtool launch` is broken on iOS 17+ (issue #44) — tap
    the icon. Upgrade later: Xcode 26.6 (needs macOS ≥ 26.2, no restart) or
    Path B.
  - **Path B (later): iPad → iPadOS 27 needs Xcode 27.1, which requires macOS
    26.6+.** Software Update offers macOS 26.7.2 (7.3 GB) and 27.2 (11.1 GB);
    take 26.7.2 first (same major, lowest risk to the Koe signing cert,
    Accessibility grants, Docker and the Studio worker). Restart ends the
    other Claude sessions. Do B as one deliberate maintenance window.
- Then: `sudo xcode-select -s /Applications/Xcode.app`, open Xcode once, sign
  in with the Apple ID
  → **Personal Team (free) — decided 2026-10-29.** Installs on Tyler's own
  iPad, signature expires every 7 days (re-run from Xcode), no iCloud/push.
  Revisit the $99/yr program (1-year signatures, TestFlight over the air)
  after Phase 1, once the companion is daily-use. Xcode 16.3 can go.
- **Build driver: xtool first (no .xcodeproj at all).** `xtool` (MIT, active)
  builds a SwiftPM package straight into an iOS app, signs it, installs and
  launches it on the iPad from the terminal — the same shape as
  `scripts/build_app.sh` on the Mac. Xcode.app must still be installed and
  launched once for the iOS SDK + toolchain; its GUI is never used after that.
  Login: free Apple ID = password + 2FA through private Apple APIs (xtool's
  docs suggest a throwaway Apple ID; the Personal Team then belongs to that
  ID, which is fine for installing on Tyler's iPad), or an API key with the
  paid program. Fallback if xtool chokes on our package: `xcodebuild` +
  `xcrun devicectl` from the CLI with an XcodeGen project (`ios/project.yml`;
  watch open issue #1575 about local packages).
- **7-day re-sign without the cable: AltServer** (altstoreio/AltStore) on the
  Mac re-signs free-account apps in the background over Wi-Fi. Add after
  Phase 1 if the weekly re-run from Xcode gets annoying.
- **Package split.** `Package.swift` → `platforms: [.macOS(.v13), .iOS(.v17)]`;
  targets `KoeCore` (neutral), `KoeMac` (today's executable), `KoeiPad`.
  `scripts/build_app.sh` unchanged.

## 4b. Phase 4 picks (Tyler, 2026-10-30): Save to Board · Pencil Pro extras · Offline books

**A. Highlights that go somewhere.** The highlight menu (and the colour menu)
gains **Save to Board ▸** with the Mac's board names. Saving appends a
`BoardItem` (text = the selected passage, source = "Book · Chapter",
kind = "read") to the local `readflow.boards` document, posts
`.koeStateChanged`, and StateSync pushes it with `baseRevision`. Boards are
now edited on both devices, so `KoeStateLocal.merge` learns a board merge:
union of boards by id, and per board a union of items by id (remote order,
local additions appended). The Mac gets the same merge through the shared
protocol file and reloads BoardStore on pull. Deletions made on one device
between the other's pull and push can reappear once; acceptable for v1.

**B. Pencil Pro extras.** A custom `PencilDragRecognizer` (UIGestureRecognizer
subclass tracking the single Pencil touch) replaces the pan recognizer so the
drag sees `rollAngle` (iOS 17.5). Rolling the barrel ±30° per step while
dragging cycles the colour of the selection wash; lifting after a roll
applies that colour with no menu, lifting without a roll shows the menu as
today. `UICanvasFeedbackGenerator` (iOS 17.5) ticks on every word-boundary
snap (`alignmentOccurred`) and on a completed mark (`pathCompleted`). Pro only;
the USB-C Pencil keeps the menu path.

**C. Offline books.** "Keep on this iPad" per book (toggle in the book
screen). Koe's cache moves from Caches/ to Application Support/Koe/cache
(not purged by iPadOS; excluded from backup). Keeping a book prefetches the
PDF, every narrated chapter's audio, and every chapter's detail JSON (text +
word timings), with progress and cancel. The library list and book details
are cached too; when a live fetch fails, screens fall back to the cached copy
and show an *Offline copy* badge. Launch while offline uses the last known
sign-in state instead of showing the login. Away from home: put the
think box's Tailscale address in Server; the session cookie is per host, so
that host needs one Google sign-in of its own.

Order: A → B → C. **All three built 2026-10-30** (commits aa25db2 Save to Board
+ board merge, 0b95aba Pencil Pro roll/haptics, fed7d16+8ea7b70 offline); one
iPad install carries them. Mac rebuild needed for the board merge (shared file).

## 4c. Phase 5 (Tyler, 2026-10-30): Ask the book · Draw on the canvas

**Ask the book (Core + both apps).** Core's two retrieval stacks could not serve books at $0
(pgvector RAG embeds with OpenAI; the Knowledge Service is an unscoped shared corpus), so Core
gets a small dedicated route: `POST /api/reader/books/{id}/ask` `{question, chapterId?, device}`
→ chapter text straight from `readings.source_text`, lexical passage ranking (+ the local
reranker when `RERANKER_URL` is set), answer from the house llama.cpp model (`READER_ASK_MODEL`,
default order hemmingway-1 → gemma-4) with the release-assets call pattern. Reply
`{schema:"koe-ask/1", answer, model, scope, passages[{chapterId, chapterTitle, position, excerpt}], elapsedMs}`;
503 when no local model is configured, 504 on model timeout. The answer is written for a voice:
2–5 plain sentences, no lists.
- iPad: `AskBookView` (question field takes Scribble, chapter/whole-book scope, answer read by
  `TextSpeaker` with word highlight, auto-read toggle, Save to Board, "Where this came from").
  Entry: the reader's toolbar bubble, and the book page for whole-book questions.
- Mac: `KoeAskBookView` sheet from "Ask the book…" in the chapter header; reads through the main
  reading voice (`.readFlowReadExternalText`), Save to Board via `BoardStore`.
- Both send `Origin` on POST (Core checks Origin vs Host on mutating routes); 90 s client timeout.

**Draw on the canvas (iPad → Mac).** Each sketch is its own sync document `canvasInk.<note id>`
(`KoeCanvasInk`: PKDrawing data + opaque JPEG preview, kept under 950 KB), referenced by a
`CanvasNote.ink` field. `canvasNotes` stays small; cards union-merge by id on conflict.
- iPad `CanvasView` is editable: New sketch (PKCanvasView + tool picker, finger or Pencil), tap a
  sketch to keep drawing, drag any card to move it, context menu recolour/delete. `CanvasWriter`
  saves the card before the ink document so a pull in between never garbage-collects it.
- Mac `StickyNoteView` renders the preview (PencilKit fallback renders strokes); `text` is a caption.
- Both syncs: `KoeStateKeys.isSynced` (fixed keys + ink prefix), seed local ink docs, GC ink files
  that are gone from the server and unreferenced, `delete(key)` → Core DELETE.
- Ink documents live as files (Application Support/Koe/canvas-ink), never in UserDefaults.

## 5. iPad landmines (verified)

- `NSLocalNetworkUsageDescription` in Info.plist or LAN calls to
  `192.168.4.200` (Kokoro :8880, Core :3000) fail. Prompt shows on first call.
- ATS exempts IP-literal `http://` on the LAN, same as the Mac. Away from
  home → Tailscale; never expose Core or Kokoro publicly.
- `AVAudioSession` `.playback` + `UIBackgroundModes: audio`, or reading stops
  at screen lock. Add Now Playing + remote controls.
- Pencil over PDF pages: `PDFPageOverlayViewProvider` (iOS 16+, WWDC22 10089)
  returning one `PKCanvasView` per page. Set `usePageViewController = false`
  *before* assigning the document or touches scroll instead of draw; match
  `contentScaleFactor` to the zoom or ink blurs.
- Ink never touches the PDF bytes: `PKDrawing` data per page, saved beside
  `highlights.json` in the `.koebook` folder and synced via `pencilInk/…`.

- **Sign-in is a magic link by email, and a tapped link opens Safari, not
  Koe.** The iPad app therefore signs in natively: email → Core sends the
  link → *paste* it into Koe → Koe GETs `/api/auth/magic-link/verify` itself
  (redirect stopped) → cookie in the app's persistent jar. Every launch and
  foreground hits `/api/auth/get-session`, which extends the session (Better
  Auth defaults: 7-day session, refreshed after a day of use), so the iPad
  stays signed in as long as Koe is opened within any 7-day window.

## 6. Phases

**Status 2026-10-29 (end of day 1).** Phase 0 done. Phase 1 done except Core-side
resume (native route lacks `progress`) and per-word page spans. Phase 3 slice 1
done: drag-to-select + colour menu, quick highlighter, Highlights list, reading
pen (opt-in), hover ruler, squeeze/double-tap play-pause, PencilKit ink per
page. Phase 2 BUILT 2026-10-30 (Core PR #241 = koe_state store; Mac pushes on
save + pulls on activate; iPad pulls on launch/foreground and shows Boards,
Library, Canvas read-only with a snippet reader; highlights/positions merge
both ways). Waiting on: merge #241 → deploy → migration 0136; install the new
Mac Koe (`scripts/build_app.sh --install`); install the iPad build.
Install recipe: Tyler force-closes Koe + unlocks → `xtool dev build --sign
--ipa && xtool install --usb xtool/KoeiPad.ipa` (live app id is the
double-prefixed one; never `xtool dev`, never uninstall without a probe).
Sign-in = Google on Core's web page inside Koe (Core has no email provider).

**Phase 0 — Tooling (an hour, nothing to download but xtool).** Xcode 16.3
as-is → `brew install xtool-org/tap/xtool` → `xtool setup` with Tyler's real
Apple ID (decided 2026-10-29; password + 2FA; if no code arrives, see xtool
issue #407 — Advanced Data Protection — and fall back to Xcode's Accounts
pane + `xcodebuild`) → cable the iPad, trust the Mac, turn on
Developer Mode (Settings → Privacy & Security → Developer Mode, restarts the
iPad) → `ios/` package (DONE 2026-10-29: `cd ios && xtool dev build` → arm64 iOS
`xtool/KoeiPad.app`, unsigned) → `xtool dev` signs + installs. Exit: Koe icon on
the iPad, and it still opens after unplugging.

**Phase 1 — Books companion (no Core change needed).** Sign into Core from
the iPad, pull the two pilot books, original PDF pages, Audiobook Narrator +
Kokoro voices with word highlight, follow pages, show existing colour
highlights, offline cache, progress through Core so Mac and iPad agree.
Exit: ACQ Closer Handbook resumes at the saved word on both devices.

**Phase 2 — Boards, Library, Canvas companion (needs the Core sync PR).**
Boards list → play a saved snippet with the highlight; notebooks and
librarySections read-only; Idea Canvas pannable with ▶ playable cards;
readingPositions and readingHighlights shared. Exit: a Board saved on the Mac
plays on the iPad within a minute.

**Phase 3 — Pencil.**
- Tap a word → read from here (model already has `onSeekToWord`).
- **Reading pen**: hover or drag the tip along a line and Koe reads the words
  under it (`UIHoverGestureRecognizer`; this iPad supports hover with either
  pencil). Reading ruler / line focus follows the pen.
- Double-tap / squeeze → play/pause via `UIPencilInteraction`, honouring the
  Settings preference. **Pencil Pro only**; USB-C falls back to a button.
- Pencil-select a passage on a book page → colour mark (same four colours as
  the Mac) or "Save to Board".
- Ink layer per PDF page (above), synced.
- Scribble in note fields is free; PencilKit on the Idea Canvas later.

**Phase 4 — iPad polish.** Lock-screen controls, Shortcuts "Continue my
book" / "Play Board …", a "Continue reading" widget, Stage Manager sizes,
Split View beside Notes or Safari as a listen-along.

## 7. Repos and references (checked 2026-10-29)

| What | Use it for | Notes |
|------|------------|-------|
| mlalma/kokoro-ios (`KokoroSwift`) | on-device Kokoro when off the LAN | MLX Swift, iOS 18+, MIT, token timestamps since 1.0.8; experimental; model file supplied by us |
| mattmireles/kokoro-coreml (HF) | Core ML Kokoro fallback | author claims faster than MLX; no timestamps mentioned |
| k2-fsa/sherpa-onnx | offline TTS, many voices | Swift API for Kokoro (#1803) + iOS demo (#1812) in its changelog; `ios-swiftui/` TtsLexicon/TtsPhonemize examples; heavier |
| AndyHCode/EchoText | packaging reference | offline iOS TTS app on sherpa-onnx |
| Apple WWDC22 10089 + `PDFPageOverlayViewProvider` | Pencil ink over PDF pages | canonical pattern; traps in §5 |
| joshuabourke/pdfeditorsdk | SwiftUI PDFKit + Pencil example | MIT, tiny; read, don't depend |
| Apple `UIPencilInteraction`, Apple Pencil docs, support 120123 / HT211029 | gestures, hover, compatibility | double-tap, squeeze, `UIPencilHoverPose`, `onPencilSqueeze` |
| xtool-org/xtool | SwiftPM → signed iOS app → iPad, all CLI | MIT, 14k★, commit 2026-10-28; needs Xcode installed for the SDK; free-ID login uses private APIs |
| altstoreio/AltStore (AltServer) | weekly Wi-Fi re-sign of free-account apps | Mac menu-bar app; takes the Apple ID |
| yonaskolb/XcodeGen · tuist/tuist | project generation, only if xtool fails | XcodeGen first, Tuist fallback |
| antijingoist/opendyslexic | reader font | still unshipped on Mac (`Resources/` has only the icon) — ship on both |
| Hacking with Swift: AVSpeechSynthesizer highlight | `willSpeakRangeOfSpeechString` | already what `SystemAVSpeechEngine` does |

## 8. NEEDS YOU

- Which Pencil: **Pro** or **USB-C**? (Settings → Apple Pencil shows it.)
- Run `brew install xtool-org/tap/xtool` (Claude is not allowed to install
  external code) and `xtool setup` with the real Apple ID (interactive 2FA).
  Signing = free Personal Team (decided). Keep the iPad on 26.5.2 and switch
  off its automatic updates.
- Later, as one maintenance window: macOS 26.7.2 → Xcode 27.1 → then iPadOS 27.
- The Core sync endpoint (§3) is a Core PR you merge; say when to open it.
