# Running Kokoro on a GPU worker box (recommended)

Kokoro on **CPU** synthesizes at roughly real time, so long reads start in ~3s and
occasionally stall when synthesis dips below real time. On a **GPU** it runs ~10–20×
real time (≈0.13s per sentence), so playback starts in ~1s and never pauses — same
voice, same word-timing, just fast.

This is the Evergreen pattern: run TTS as a service on a worker box, point the Mac
app at it over the LAN.

## Current setup (2026-06-23)
- **Host:** m90t (`192.168.4.200`, ssh alias `think`) — RTX 5060 Ti, 16 GB.
- **Image:** `koe-kokoro-blackwell` (built from `Dockerfile.blackwell` — the stock
  GPU image needed CUDA 12.8 torch for the Blackwell card). The image was
  `docker save | ssh | docker load`-streamed over from Framerstation rather than
  rebuilt, so it's byte-identical.
- **Container:** `koe-kokoro`, `--restart unless-stopped`, port `8880`.
- **Koe points at it via** the `readflow.kokoroBaseURL` setting:
  `defaults write com.readflow.app readflow.kokoroBaseURL "http://192.168.4.200:8880"`
  then relaunch Koe. (Default is `http://localhost:8880`.)

### GPU split with Chatterbox
Kokoro (~0.85 GB) shares m90t with the resident **VoxStation** voice service
(~9.6 GB) — together ~10.5 GB / 16 GB, comfortable. The **Chatterbox** engine has
a much larger ~4.8 GB working set, so it lives on **Framerstation**
(`192.168.4.176:8004`, 93% idle GPU) instead — putting both on m90t pushed it to
94% VRAM. Chatterbox's image/repo still exist on m90t (`~/chatterbox-server`,
`compose down`) as a dormant fallback. Framerstation is also the rebuild source if
m90t's Kokoro image is ever lost.

## Stand it up on a GPU box
```bash
ssh frame                       # or: think (m90t, the overflow box — also a 5060 Ti)
# copy Dockerfile.blackwell over, then:
docker build -f Dockerfile.blackwell -t koe-kokoro-blackwell .
docker run -d --name koe-kokoro --restart unless-stopped --gpus all -p 8880:8880 koe-kokoro-blackwell
curl http://localhost:8880/health          # {"status":"healthy"}
```
Then on the Mac, set `readflow.kokoroBaseURL` to `http://<box-ip>:8880` and relaunch.

## Notes
- **Blackwell (RTX 50-series):** must use `Dockerfile.blackwell` (CUDA 12.8 torch).
  Older cards (RTX 30/40) work with the stock `ghcr.io/remsky/kokoro-fastapi-gpu`.
- **Rollback / move:** `docker rm -f koe-kokoro` on the box; set `kokoroBaseURL` back
  to `http://localhost:8880` to use the local CPU container again.
- **If the worker is down:** Koe surfaces the error and falls back to the System
  voice automatically — it never goes silent.
- LAN-only service (no auth); fine on the private Evergreen network — do not expose
  port 8880 publicly.
