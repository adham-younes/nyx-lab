#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

WS="${WS:-/workspace}"
LOG="${LOG:-/lab/var/log/nyx-relay.log}"
PIDF="/lab/var/run/nyx-relay.pid"
mkdir -p "$(dirname "$LOG")" "$(dirname "$PIDF")"

need() { command -v "$1" >/dev/null || { echo "MISSING:$1" >&2; exit 78; }; }
need node; need curl; need python3

/lab/bin/gate integrity >/dev/null || {
  echo "INTEGRITY_FAIL" >&2; exit 79; }

if [[ -s "$PIDF" ]] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  echo "ALREADY_UP pid=$(cat "$PIDF")"
else
  nohup node "$WS/og-relay.mjs" >>"$LOG" 2>&1 &
  echo $! >"$PIDF"; chmod 600 "$PIDF" "$LOG"
fi

for _ in $(seq 1 40); do
  if curl -fsS -m 2 http://127.0.0.1:8787/healthz 2>/dev/null \
      | python3 -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("ok") is True else 1)' 2>/dev/null; then
      /lab/bin/session-ready.sh || echo "READINESS_BLOCKED mode=$(cat /lab/state/mode 2>/dev/null)"
      echo "BOOT_OK"; exit 0
  fi
  sleep 0.25
done

echo "BOOT_FAIL" >&2
tail -n 25 "$LOG" >&2 || true
exit 69
