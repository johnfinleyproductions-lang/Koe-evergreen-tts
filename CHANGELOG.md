# Changelog

All notable changes to **Koe** (internal module name `ReadFlow`) — the macOS
read-aloud accessibility app: natural local TTS with a moving word-by-word
highlight, usable on any selected text.

Format loosely follows [Keep a Changelog](https://keepachangelog.com/). Dates are
the commit dates on `main`.

## [Unreleased]

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
