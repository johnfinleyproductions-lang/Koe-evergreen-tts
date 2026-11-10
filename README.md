# ReadFlow

## Books in the native Koe app

Open **Books** in Koe's sidebar. This is the original-PDF reading view; the
existing **Library** remains your notebook workspace. Choose a book, then a
chapter. Use Previous/Next page, a page number, Fit/zoom and the chapter player.
Koe saves the chapter, PDF page, listening time, zoom and speed when you pause or
leave. Ready adjacent chapters continue in order; unavailable audio is never
silently regenerated.

Select text on a PDF page and choose **Highlight text**. Choose yellow, green,
pink or blue from **Color**. For scanned pages or pictures, turn on **Mark area**
and drag over the passage; turn it off to select text again. **Highlights** lists
saved marks, takes you back to their page, and offers Remove. Highlights save
immediately in each book's private `highlights.json`, matched to the source PDF's
hash, and return when the book reopens. The original PDF and narration stay
unchanged. These book highlights are local to this Mac.

The chapter player's **Voice** picker offers **Audiobook Narrator** (the existing
recording) and **Kokoro** (Koe's configured Kokoro voice and server). Kokoro reads
the imported text immediately, including chapters awaiting a narrator recording.
It generates small passages as needed and keeps them in the book's private
`kokoro-cache`, separately from original MP3s. Already cached passages replay
offline; new passages need the configured Kokoro service. Failures stop visibly
at the unavailable passage rather than skipping book text or changing voices.

Kokoro's progress slider seeks by **word**, with **Back 20 words**; the narrator
slider seeks by time, with Back 15 seconds. Saved places retain the selected
engine and Kokoro word position. Switching voices maps the position through the
source text, because their spoken timings differ. Kokoro follows PDF pages using
its own spoken-word callbacks and the prepared page mapping. The voice name is
shown in the picker; changing Koe's Kokoro settings applies on the next play.

**Follow pages** advances the PDF using the recorded chapter's existing word
timings and prepared page-text mapping. Manual page navigation turns following
off until you re-enable it. Timings are approximate; uncertain mappings remain
manual. Original images and layout stay intact.

Prepared `.koebook` folders contain the unchanged source PDF, versioned chapter
metadata/page spans and existing MP3s. Imported copies live under
`~/Library/Application Support/Koe/Books`, separate from notebooks and
highlights, and remain usable offline. **Connect Evergreen** opens Koe's own
sign-in window. Sign in with your normal Evergreen account, then use **Refresh
chapters**; Koe also checks for finished chapters every minute while Books is
open. It never extracts another browser's cookies or includes internal-worker
credentials. Imports do not rerun OCR or TTS.

Developer builds use `bash scripts/build_app.sh --build-only`; this assembles and
signs the staged app without replacing `/Applications/Koe.app`. After validation,
quit Koe and use `--install` to retain the previous app and install the new one.
`./script/build_and_run.sh` runs a staged viewer rehearsal without competing for
the installed hotkey/loopback listener. The standalone Swift smoke check and
`python3 scripts/test_book_page_map.py` verify real-source playback/position
restore and UTF-16 page offsets without adding a test framework.

ReadFlow reads text out loud for you.

Pick some text anywhere on your Mac. Press a key. ReadFlow speaks it. Each word
lights up as it is read, so your eyes can follow along.

It is built for people who find reading hard. It is calm, simple, and it works
the moment you open it.

ReadFlow lives in the **menu bar** at the top of your screen. There is no Dock
icon and no big window in the way.

## What it can read

- Text you select in almost any app.
- PDFs (open one with **Open PDF…** in the menu). It can even read scanned PDFs.

## The three voices

You choose the voice in the menu bar. You can switch any time.

1. **System** — the built-in Mac voice. It is the default. It works right away,
   with no setup. Start here.
2. **Kokoro** — a natural-sounding voice that runs on your own Mac. Nothing
   goes to the internet. It needs a one-time setup. See
   [`kokoro/README.md`](kokoro/README.md).
3. **Azure** — an optional cloud voice from Microsoft. It needs an account and a
   key. Only set this up if you want it. Your key is stored safely in the Mac
   Keychain. It is never shown and never saved in plain text.

You can use ReadFlow fully with just the System voice.

## How to build it

You need Apple's Command Line Tools (no full Xcode needed).

Open Terminal and run:

```sh
cd "/Users/tylerfreund/Desktop/Coding Projects/ReadFlow"
bash scripts/build_app.sh
```

When it finishes, the app is here:

```
build/ReadFlow.app
```

Open it:

```sh
open "build/ReadFlow.app"
```

Look for the ReadFlow icon in your menu bar.

## One-time permission

The first time, ReadFlow needs permission to see the text you select.

1. Open **System Settings**.
2. Go to **Privacy & Security**, then **Accessibility**.
3. Turn **ON** the switch next to **ReadFlow**.

If ReadFlow is not in the list, click the **+** button and add it from
`build/ReadFlow.app`.

That is it. You only do this once.

If you skip this, ReadFlow still reads PDFs you open with **Open PDF…**.

## The hotkey

Select text. Then press:

> **Option-R**

ReadFlow reads it out loud.

You can also use the menu bar: click the ReadFlow icon, then **Read Selection**.
**Stop** stops it.

## Making it easy to read (the HUD)

When ReadFlow reads, a small floating panel shows the words. The word being
spoken is highlighted. You can change how it looks in **Settings** so it is
easy on your eyes:

- **OpenDyslexic font** — a font made to be easier to read.
- **Bigger text** — set the size you like.
- **More space between lines** — give each line room to breathe.
- **More space between letters** — spread the letters out.
- **Speed** — read slower or faster.

Change these until reading feels comfortable. There is no wrong setting.

## Highlight and export a reading

1. Open **Capture & highlight** in Koe. From **The Quiet Hour**, click
   **Highlight & export** to get there.
2. Drag across any passage, then choose **Yellow**, **Green**, **Pink**, or
   **Blue**. Koe remembers those highlights when you reopen the same text.
3. Click **Export PDF + editable RTF** and choose a filename.

Koe saves two files beside each other:

- a clean, paginated PDF for reading or sharing
- an RTF with the same highlights that you can edit in Pages, Word, or TextEdit

## If something does not work

- **No sound** — make sure a voice is picked in the menu and your Mac volume is
  up. The System voice always works; if Kokoro or Azure is down, ReadFlow tells
  you and offers the System voice.
- **It cannot read my selection** — check the Accessibility permission above.
- **Kokoro voice not working** — see [`kokoro/README.md`](kokoro/README.md).

ReadFlow tries hard to never fail quietly. If something is wrong, it will tell
you what to do.
