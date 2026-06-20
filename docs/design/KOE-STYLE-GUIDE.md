# Koe — Style Guide (extracted from `Koe v2.dc.html`)

Koe (声 = "voice"). A calm, warm, paper-like read-aloud notebook. Japanese-stationery
feeling: washi paper, sumi ink, a single vermilion (shu 朱) accent, handwritten margin notes.

## Scope (current build = "Reader first")
Build now: **Capture (PDF + selection)**, **The Quiet Hour (reading + word highlight)**,
the **persistent player bar**, **read-anywhere hotkey**, **3 voices**.
Defer: Idea Canvas, Boards (design preserved in the HTML for later).

## Color tokens

### Light theme
| token | hex | use |
|---|---|---|
| `--desk` | radial `#e3dccd → #d4ccba → #cabfa9` | window desk/backdrop |
| `--s0` | `#fdfaf4` | brightest paper (PDF page) |
| `--s1` | `#faf4e8` | main surface |
| `--s2` | `#f6eedd` | sidebar / player bar |
| `--s3` | `#f4ecdd` | chips / inset buttons |
| `--canvas` | `#f1e8d6` | canvas bg (later) |
| `--navAct` | `#efe6d2` | active nav item bg |
| `--ink` | `#2c2620` | primary text |
| `--ink2` | `#3f382d` | already-read words |
| `--ink3` | `#544b3d` | body text |
| `--soft` | `#6f6557` | reading body / secondary |
| `--faint` | `#8c8472` | tertiary |
| `--faint2` | `#9a8f7c` | upcoming (un-read) words |
| `--mute` | `#a99f8c` | meta / captions |
| `--line` | `#e6dabf` | borders |
| `--line2` | `#ece0c6` | soft dividers |
| `--dash` | `#d4c4a0` | dashed "new" borders |
| `--readerBg` | `#d6d1c4` | PDF capture backdrop |
| `--readerBar` | `#cbc6b8` | PDF window titlebar |
| accent **shu** | `#c0432d` | play button, highlight, brand 声 |
| highlight fill | `rgba(192,67,45,.26)` | **current spoken word** bg |
| selection fill | `rgba(192,67,45,.15)` + ring `rgba(192,67,45,.3)` | captured selection |
| note blue | `#33455f` | margin note / "clip" kind |
| note green | `#7c8a5b` | margin note / Evergreen board |
| tint shu | `#f4ddd6` | "read" pill bg |
| tint ai | `#dde3ec` | "clip" pill bg |

### Dark theme
desk `#2b2620 → #16130f`; `--s0 #2a251e` `--s1 #252019` `--s2 #201b15` `--s3 #322c23`;
`--ink #f2ece0` `--ink2 #ddd5c6` `--ink3 #cbc2b1` `--soft #b3a994` `--faint2 #857b69`
`--mute #7d7361`; `--line #3a342b`; accent stays `#c0432d`.

## Typography  (bundle these TTFs in Resources + register; fall back to Apple JP fonts)
| role | font | fallback (macOS) |
|---|---|---|
| Headings, reading body | **Shippori Mincho** (700/800) | Hiragino Mincho ProN |
| UI / buttons / nav | **Zen Kaku Gothic New** (400/500/700) | Hiragino Sans |
| Handwritten margin notes, sticky notes | **Klee One** (400/600) | (bundle; else SF Pro italic) |
| Metadata, timestamps, filenames | **DM Mono** (400/500) | SF Mono / Menlo |

Reading view: Shippori Mincho 19px / line-height 34px, color `--soft`, max-width 600px.
Headings: Shippori Mincho 700, 29–30px, `--ink`. Brand "Koe" 22px 800 + 声 15px in shu.

## Word highlight mechanic (the core)
Words split on whitespace. Each word styled by position vs `wordIndex`:
- **current** (`i === wordIndex`): bg `rgba(192,67,45,.26)`, radius 4px, pad `1px 4px`,
  color `--ink`, weight 600, `box-decoration-break: clone`.
- **already read** (`i < wordIndex`): color `--ink2`.
- **upcoming** (`i > wordIndex`): color `--faint2`.
In SwiftUI this is the custom `WrappingHStack` Layout so each word can carry its own
rounded background that wraps inline. Advance index from real TTS word timings.

## Layout
- Window ~1200×770, radius 16, `--s1`, soft long shadow. (Native: resizable main window.)
- **Sidebar** 216px, `--s2`: brand → nav (Capture 読 / The Quiet Hour / [Canvas, Boards later])
  → bottom: theme toggle (☾/☀) + "Now reading" card (blinking shu dot + title + source).
- **Main** swaps views.
  - *Capture*: faux PDF window (3 traffic dots in muted earth tones `#c8836f #d8bd7e #9fb083`,
    filename in DM Mono, "page 3/18 · 124%"). Selected paragraph gets the selection tint +
    a floating **Koe chip** toolbar: shu **Listen** (play/pause), **Highlight** toggle,
    "Add to canvas" ⌗, "Save to board ▾".
  - *The Quiet Hour*: lined-paper bg (`repeating-linear-gradient` blue 8% every 34px),
    title block, the word-highlight text column, handwritten Klee margin notes w/ dashed arrows.
- **Player bar** 84px, `--s2`, persistent: prev/play/next circular buttons (play = 54px shu
  circle w/ 2px paper ring), elapsed (DM Mono), **animated waveform** (first ~5 bars shu,
  animate scaleY via `koeWv`; rest are static `--line` ticks), total, speed pill `1.0×`,
  voice pill (春 Haru avatar). Waveform animates only while playing.

## Motion
- `koeWv`: bar scaleY .3→1→.3 over 1s, staggered 0.12s — playing waveform.
- `koeBlink`: opacity 1→.35 — "now reading" dot.
- toast slide-up; picker pop scale .96→1.

## Iconography / accents (Japanese characters as quiet decoration)
声 voice/brand · 聴 listen · 読 read · 棚 shelf/boards · 字 type · 春 Haru voice.
Use sparingly, in shu or muted ink.
