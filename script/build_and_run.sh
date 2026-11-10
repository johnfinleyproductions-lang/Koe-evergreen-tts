#!/usr/bin/env bash
set -euo pipefail
KOE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
# Stop only this staged build; leave the user's installed Koe alone.
while IFS= read -r KOE_PREVIEW_PID; do
  [[ -n "$KOE_PREVIEW_PID" ]] && kill -TERM "$KOE_PREVIEW_PID"
done < <(pgrep -f "^${KOE_ROOT}/build/ReadFlow.app/Contents/MacOS/ReadFlow( |$)" || true)
# Use the existing bundler; this never changes /Applications during development.
bash "$KOE_ROOT/scripts/build_app.sh" --build-only
APP="$KOE_ROOT/build/ReadFlow.app"
case "$MODE" in
  run|--verify) /usr/bin/open -n "$APP" --args --books --book-preview ;;
  --debug) lldb -- "$APP/Contents/MacOS/ReadFlow" ;;
  --logs) /usr/bin/open -n "$APP" --args --books --book-preview; /usr/bin/log stream --info --style compact --predicate 'process == "ReadFlow"' ;;
  --telemetry) /usr/bin/open -n "$APP" --args --books --book-preview; /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.readflow.app"' ;;
  *) printf 'usage: %s [run|--verify|--debug|--logs|--telemetry]\n' "$0" >&2; exit 2 ;;
esac
if [[ "$MODE" == "--verify" ]]; then pgrep -x ReadFlow >/dev/null; fi
