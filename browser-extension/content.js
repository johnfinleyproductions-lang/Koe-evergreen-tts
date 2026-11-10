// Read in Koe — content script.
// Shows a "声 Read in Koe" chip when you select text on a page, and (on click)
// hands the selection to the Koe app via the background worker.

let chip = null;

function removeChip() {
  if (chip) { chip.remove(); chip = null; }
}

function showChip(rect, text) {
  removeChip();
  chip = document.createElement("div");
  chip.className = "koe-read-chip";
  chip.innerHTML = '<span class="koe-mark">声</span><span class="koe-label">Read in Koe</span>';

  // Position just below the end of the selection, in document coordinates.
  chip.style.top = (window.scrollY + rect.bottom + 8) + "px";
  chip.style.left = (window.scrollX + Math.max(0, rect.left)) + "px";

  // Don't let the mousedown clear the selection or dismiss us before click.
  chip.addEventListener("mousedown", (e) => { e.preventDefault(); e.stopPropagation(); });
  chip.addEventListener("click", (e) => {
    e.preventDefault();
    e.stopPropagation();
    send(text);
  });

  document.body.appendChild(chip);
}

function send(text) {
  try {
    chrome.runtime.sendMessage({ type: "readInKoe", text }, (resp) => {
      if (resp && resp.ok) {
        chip.classList.add("koe-sent");
        chip.querySelector(".koe-label").textContent = "Sent to Koe ✓";
      } else {
        chip.classList.add("koe-error");
        chip.querySelector(".koe-label").textContent = "Koe not open";
      }
      setTimeout(removeChip, 1100);
    });
  } catch (err) {
    removeChip();
  }
}

document.addEventListener("mouseup", () => {
  // Let the selection settle.
  setTimeout(() => {
    const sel = window.getSelection();
    const text = sel ? sel.toString().trim() : "";
    if (!text || !sel.rangeCount) { removeChip(); return; }
    const rect = sel.getRangeAt(0).getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) { removeChip(); return; }
    showChip(rect, text);
  }, 10);
});

// Dismiss on a fresh click elsewhere, on scroll, or on Escape.
document.addEventListener("mousedown", (e) => {
  if (chip && !chip.contains(e.target)) removeChip();
});
document.addEventListener("scroll", removeChip, true);
document.addEventListener("keydown", (e) => { if (e.key === "Escape") removeChip(); });

// --- Whole-article reading (Alt+Shift+K) ---------------------------------
// Extract the page's MAIN content (Readability-style heuristic) and read it in
// Koe — so you can read a full article, not just a selection.

function showToast(message, kind) {
  removeChip();
  const t = document.createElement("div");
  t.className = "koe-read-chip" + (kind ? " " + kind : "");
  t.innerHTML = '<span class="koe-mark">声</span><span class="koe-label"></span>';
  t.querySelector(".koe-label").textContent = message;
  Object.assign(t.style, {
    position: "fixed", top: "16px", left: "50%",
    transform: "translateX(-50%)", zIndex: "2147483647",
  });
  document.body.appendChild(t);
  setTimeout(() => t.remove(), 1600);
}

function extractArticle() {
  // Prefer obvious semantic containers.
  let best =
    document.querySelector("article") ||
    document.querySelector("main") ||
    document.querySelector('[role="main"]');

  // Otherwise pick the block whose paragraphs carry the most text.
  if (!best) {
    let bestScore = 0;
    document.querySelectorAll("article, main, section, div").forEach((el) => {
      if (el.closest("nav, header, footer, aside")) return;
      let score = 0;
      el.querySelectorAll("p").forEach((p) => (score += (p.innerText || "").length));
      if (score > bestScore) { bestScore = score; best = el; }
    });
  }

  const root = best || document.body;
  const parts = [];
  root.querySelectorAll("h1, h2, h3, h4, p, li, blockquote").forEach((el) => {
    if (el.closest("nav, header, footer, aside")) return;
    const text = (el.innerText || "").trim();
    if (text) parts.push(text);
  });

  let text = parts.join("\n\n");
  if (text.trim().length < 200) {
    text = (root.innerText || document.body.innerText || "").trim();
  }
  return text.replace(/\n{3,}/g, "\n\n").trim();
}

function readWholeArticle() {
  const text = extractArticle();
  if (!text || text.length < 40) { showToast("No article text found", "koe-error"); return; }
  try {
    chrome.runtime.sendMessage({ type: "readInKoe", text }, (resp) => {
      const ok = resp && resp.ok;
      showToast(ok ? "Reading article in Koe ✓" : "Koe not open", ok ? "koe-sent" : "koe-error");
    });
  } catch (err) {
    showToast("Koe not open", "koe-error");
  }
}

document.addEventListener("keydown", (e) => {
  // Alt+Shift+K → read the whole article (distinct combo to avoid clashes).
  if (e.altKey && e.shiftKey && (e.key === "K" || e.key === "k")) {
    e.preventDefault();
    readWholeArticle();
  }
});
