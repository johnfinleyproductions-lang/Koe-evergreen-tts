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
