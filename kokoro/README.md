# Kokoro voices for ReadFlow

Kokoro-FastAPI gives ReadFlow natural-sounding voices that run **on your own
Mac** — nothing is sent to the cloud. ReadFlow talks to it on
`http://localhost:8880`.

You only need this if you want the **Kokoro** voice engine. The built-in
**System** voice works without any of this.

## Start it

You need Docker Desktop installed and running.

```sh
cd "/Users/tylerfreund/Desktop/Coding Projects/ReadFlow/kokoro"
docker compose up -d
```

The first start downloads the voice model. That can take a minute or two. Check
when it is ready:

```sh
docker compose ps          # STATUS should say "healthy"
docker compose logs -f     # watch it load (Ctrl-C to stop watching)
```

To stop it later:

```sh
docker compose down
```

## Verify it returns word timestamps

ReadFlow needs the `/dev/captioned_speech` endpoint, which returns the audio
**plus** the start/end time of every word (that is what drives the moving
highlight). Test it:

```sh
curl -s http://localhost:8880/dev/captioned_speech \
  -H "Content-Type: application/json" \
  -d '{
        "model": "kokoro",
        "input": "Hello from ReadFlow.",
        "voice": "af_sky",
        "response_format": "wav"
      }' | python3 -m json.tool | head -40
```

A working response includes a base64 `audio` field and a `timestamps` array,
each entry shaped like:

```json
{ "word": "Hello", "start_time": 0.0, "end_time": 0.32 }
```

If you see those `start_time` / `end_time` values, Kokoro is ready. Open
ReadFlow's menu and pick the **Kokoro** engine.

## Troubleshooting

- **Connection refused** — the container isn't up yet. Re-run `docker compose
  ps` and wait for `healthy`.
- **404 on `/dev/captioned_speech`** — you may be on an older image. Pull the
  latest: `docker compose pull && docker compose up -d`.
- **A different port** — if you remapped the port, update ReadFlow's *Kokoro
  base URL* in Settings to match.
