# Read in Koe — browser extension

Highlight text on any web page → a red **声 Read in Koe** button appears → click it →
the Koe app reads it aloud. This covers the one place the native floating chip can't
reach: inside Chrome / Arc / Edge / Brave (browsers hide their text from macOS
accessibility, so web reading needs an in-page button).

## How it works
- `content.js` shows the chip on text selection and sends the text to the background worker.
- `background.js` POSTs the text to the Koe app's local listener at `http://127.0.0.1:8765/read`.
- The Koe app (must be running) receives it and reads it aloud — same voices, same window.

The listener is **loopback-only** (127.0.0.1), accepts only a text "read" request, and is
never reachable from outside your Mac.

## Install (Chrome / Arc / Edge / Brave)
1. Make sure the **Koe app is running** (`open ReadFlow.app`).
2. Open `chrome://extensions` (Arc: `arc://extensions`, Edge: `edge://extensions`).
3. Turn on **Developer mode** (top-right).
4. Click **Load unpacked** and choose this `browser-extension` folder.
5. Go to any page, highlight text → click the **声 Read in Koe** chip.

If the chip says "Koe not open", launch the Koe app and try again.

## Safari
Safari needs the extension wrapped as a small app via Xcode's
`safari-web-extension-converter` (not included here). Chrome/Arc/Edge work directly.
