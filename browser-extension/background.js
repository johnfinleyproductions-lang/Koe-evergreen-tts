// Read in Koe — background service worker.
// Performs the cross-origin POST to the Koe app's local listener. Running this
// in the worker (which holds the 127.0.0.1 host permission) sidesteps page CORS.

const KOE_ENDPOINT = "http://127.0.0.1:8765/read";

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg && msg.type === "readInKoe" && msg.text) {
    fetch(KOE_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "text/plain;charset=UTF-8" },
      body: msg.text,
    })
      .then((r) => sendResponse({ ok: r.ok }))
      .catch((e) => {
        console.warn("Read in Koe: app not reachable on 127.0.0.1:8765 —", e.message);
        sendResponse({ ok: false });
      });
    return true; // keep the message channel open for the async response
  }
});
