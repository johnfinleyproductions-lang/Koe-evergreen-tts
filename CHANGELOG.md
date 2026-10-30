# Changelog

All notable changes to **Koe** (internal module name `ReadFlow`) — the macOS
read-aloud accessibility app: natural local TTS with a moving word-by-word
highlight, usable on any selected text.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/). Dates are
the commit dates on `main`.

## [Unreleased]

### Added — PDF book highlighting (2026-10-05)
- Select PDF text and highlight it in yellow, green, pink or blue. Mark area
  supports scanned pages and illustrations with page-relative rectangles.
- Each book saves its marks atomically beside its private copy, bound to the
  original source hash. PDF and audio bytes remain unchanged.
- Open the highlights list to return to a marked page or remove a mark. Invalid
  saved files are preserved and save failures are shown, without reporting
  unsaved marks as saved.

### Added — Kokoro option for Books (2026-10-05)
- **Book voice picker.** Choose Audiobook Narrator or Koe's configured Kokoro
  voice. Kokoro can read imported chapters before recorded narration is ready.
- **Kokoro resume and page following.** Seek by source word, retain that position
  across relaunches, and follow original PDF pages with Kokoro's own word timing.
- **Private passage cache.** Resume from stable cached chunks, keep profiles
  separate by voice and server, and replay cached passages offline. An unavailable
  passage stops with an error instead of skipping book content. Original chapter
  recordings and their timing remain intact.

### Added — native book pages and recorded narration (2026-10-05)
- **Books in the Mac sidebar.** Open original PDF pages alongside a chapter
  list and recorded narration, with Fit/zoom, page navigation, seeking and speed.
- **Saved book position.** Restore the chapter, PDF page, listening time, zoom,
  speed and page-following preference after leaving or relaunching Koe.
- **Follow narrated pages.** Prepared per-page text is mapped to the exact
  recorded chapter source and existing word timings; manual navigation disables
  following until selected again. Uncertain mappings remain manual.
- **Offline books and finished-chapter refresh.** Verified prepared books reuse
  original PDFs and MP3s. Koe's own Evergreen sign-in retrieves newly completed
  chapters without rerunning OCR or narration.
- **Recoverable app installation.** Verify the signed bundle before replacing
  the installed app and retain its previous version as a backup.

### Added — persistent highlights and editable export
- **Manual passage highlighting in Capture.** Select any text and mark it yellow,
  green, pink, or blue from the small selection popover. Highlights are stored
  by a stable fingerprint of the source text, survive relaunches, and can be
  cleared from a selected range.
- **Highlight access from The Quiet Hour.** A visible `Highlight & export` action
  returns to the selectable Capture document instead of leaving the feature
  discoverable only by changing sidebar views.
- **Two-format export.** `Export PDF + editable RTF` creates a clean, paginated,
  selectable-text PDF and a matching RTF with the same highlights. The RTF opens
  for editing in Pages, Microsoft Word, or TextEdit. Export now sits in the
  compact reading-action strip beside Listen and Add to canvas.
- **Native long-document text selection.** Capture uses a focused `NSTextView`
  bridge so mouse/trackpad selection, scrolling, saved highlights, and Koe's live
  spoken-word highlight can coexist without flattening the text into an image.

### Fixed / Changed (2026-08-15 review follow-up)
- **Reader no longer hangs on long text.** The Quiet Hour / Capture views rendered
  one live view per word in a custom `Layout` (non-lazy); a long article/PDF
  realized tens of thousands of subviews and beachballed. Reads over 2500 words now
  render only a sliding window (±800) around the current word — you follow the
  highlight, so the window is exactly what you read (`WordFlowView.displayedWords`).
- **System-voice highlight is faster on long reads.** The boundary→word mapping was
  O(n²) per callback (≈O(n³) per read); the System engine now precomputes UTF-16
  word offsets once (O(n)) and binary-searches per callback — verified
  behavior-identical to the old `WordTokenizer.wordIndex` across all offsets.
- **The font preference now works, including OpenDyslexic.** `fontName` was declared
  but never applied (the reader was always Hiragino Mincho). It's now honored via
  `KoeFont.reader(_:_:)`, and any `.otf`/`.ttf` bundled in `Resources/` is registered
  at launch — drop `OpenDyslexic-Regular.otf` there to ship the dyslexia face.
- **Loopback server hardened** (partially covers the planned auth-token item).
  `KoeLocalServer` now rejects any request carrying an `Origin` header — a web page's
  cross-origin POST always sends one; the extension's service worker does not — and
  drops the wildcard `Access-Control-Allow-Origin`, so a visited page can no longer
  make Koe speak. A negative `Content-Length` (which trapped `prefix(_:)` and aborted
  the process) is now clamped.

### Added — reading experience (2026-08-15 accessibility pass)
- **Stable, non-jumping highlight.** The current word no longer grows/bolds (which
  reflowed the paragraph as it advanced — disorienting for dyslexic reading);
  emphasis is now carried by a fixed-metrics background pill + text color only.
- **Current-sentence band (dual highlight).** A soft `sentenceBand` wash sits behind
  the whole current sentence, beneath the word pill — the "sentence + word"
  Read&Write aid for keeping your place. Sentences split on terminal punctuation
  (`.!?…`), with trailing quotes/brackets tolerated.
- **Click-to-read-from-here.** Tap any word to restart the read from there; the full
  passage stays on screen and the highlight resumes at the tapped word
  (`ReaderHUDModel.onSeekToWord` → `TTSEngineManager.readFromWord`, which speaks the
  substring and offsets the engine's 0-based indices back to global — verified exact).

### Added — read the whole thing (2026-08-15)
- **Read a whole PDF, off the main thread.** "Open PDF…" already extracted the full
  document; extraction now runs on a background queue (no beachball on large/scanned
  OCR PDFs — review finding M9) and reads via the resume-aware path. The long-text
  render fix makes book-length PDFs viable.
- **Read a whole web article.** ⌥⇧K in the browser extension extracts the page's main
  content (Readability-style heuristic: prefer `<article>`/`<main>`, else the densest
  paragraph block; strip nav/header/footer/aside) and reads it — not just a selection.
- **Resume position.** New `ReadingPositionStore` persists the furthest word reached
  per document (keyed by a stable content hash). Re-opening the same PDF/article
  resumes where you left off; pause→play resumes at the paused word; finishing clears
  the position. Only documents (≥120 words) resume — short selections always start at
  the top (`TTSEngineManager.readDocument` is the resume-aware entry).

### Planned (from the 2026-06-25 multi-agent review)
- Shared-secret auth token on the loopback server (`KoeLocalServer`) so only the
  browser extension — not arbitrary websites — can trigger a read.
- Debounced notebook persistence (currently re-encodes the whole library per
  keystroke in the Library editor).
- First unit tests for the pure word-timing seams: `WordTokenizer`,
  `KokoroEngine.alignTimestamps`, `ChatterboxEngine.estimateTimestamps`,
  `makeChunks`, and the Azure boundary alignment.
- Extract a shared `StreamingChunkedEngine` base (Kokoro and Chatterbox share
  ~300 lines of identical streaming machinery).

## 2026-06-25

### Fixed (multi-agent review — top findings)
- **Switching voice mid-read could cut the audio.** `TTSEngineManager` held the
  active engine weakly, so an in-app voice/engine change (which rebuilds and
  replaces the cached engine for that kind) could deallocate the engine that was
  currently playing, stopping audio mid-sentence and leaving state stuck at
  `.speaking`. The active engine is now held strongly for the life of an
  utterance and cleared on `stop()`/`windDown()`.
- **Word highlight drifted on punctuation-only tokens.** Kokoro and Azure
  alignment consumed a real server timing boundary for tokens that normalize to
  empty (`—`, `…`, lone quotes, emoji), pushing every following word in the
  chunk one word early. Such tokens now get a zero-width timestamp without
  advancing the server cursor.
- **A transient LAN worker-box failure froze the UI** behind a modal alert even
  though the app auto-falls-back to the System voice. Transient
  `engineUnavailable`/`badResponse` errors now recover quietly; the blocking
  alert is reserved for decision-required cases (e.g. a missing credential).

### Changed (quick wins)
- User-facing alerts say "Koe" instead of "ReadFlow".
- `KoeLog` is gated behind `#if DEBUG` and writes to the per-user temp dir
  (no logging I/O in release builds; off world-shared `/tmp`).
- Kokoro `prewarm()` pings `/health` instead of the POST-only synthesis route.
- `build_app.sh` quits and atomically swaps `/Applications/Koe.app` instead of
  `rm -rf`-ing the live app in place.
- Image drag-drop only registers a gallery entry if the file actually wrote.
- Fixed a stale hardcoded path in `kokoro/README.md`.

## 2026-06-23

### Added
- **App icon** — a cream 声 on Koe's vermilion seal (`Resources/AppIcon.icns`),
  baked into the bundle via `CFBundleIconFile`.
- **Installed to `/Applications/Koe.app`** with display name "Koe" (bundle ID
  stays `com.readflow.app`, preserving the Accessibility grant), added as a
  **Login Item** so the global ⌥R hotkey is always available, and `build_app.sh`
  now refreshes the installed copy in place on every rebuild.

### Changed
- **GPU placement split.** Kokoro (default, tiny) now runs on **m90t** `:8880`;
  Chatterbox (optional, ~4.8 GB working set) stays on **Framerstation** `:8004`.
  Putting both on m90t pushed it to 94% VRAM next to the resident VoxStation
  service, so they were split for headroom. See `kokoro/GPU-WORKER.md`.

## 2026-06-22

### Added
- **Chatterbox** (Resemble "Chatterbox Turbo") as an **optional** engine in the
  voice switcher — Kokoro remains the default. OpenAI-compatible
  `/v1/audio/speech` over the LAN; no native word timestamps, so the highlight
  is estimated from each chunk's measured audio duration.
- **Kokoro on a GPU worker box** with a Blackwell-ready (CUDA 12.8) image so
  reads start in ~1 s and play gaplessly, replacing the ~real-time CPU path.

### Fixed
- **Kokoro mid-playback stalls + slow start** — serialized requests (≤2 in
  flight), ramped chunk sizes, and pre-loaded `AVAudioPlayer`s eliminate the
  start delay and mid-read pauses.

## 2026-06-21 and earlier

### Added
- **Library** — cozy "study desk" workspace with a bookshelf of notebooks:
  shelf mode vs. open (~full-screen) mode, per-notebook tabs (add/rename/delete
  pages), click-anywhere-to-write, and drag-in images.
- **Idea Canvas**, **Boards**, and **The Quiet Hour** reading view.
- Core read-anywhere capture: Accessibility + clipboard fallback, a floating
  "声 Read in Koe" chip, a macOS Services menu item, the global ⌥R hotkey, a PDF
  reader, and a loopback listener for the MV3 browser extension.
- The `TTSEngine` abstraction (System / Kokoro / Chatterbox / Azure) with
  graceful System-voice fallback, plus a stable self-signed "Koe Signing" cert
  so the Accessibility/TCC grant persists across rebuilds.
