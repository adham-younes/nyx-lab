#!/usr/bin/env bash
# NYX execution wrapper: gate -> run -> evidence. No gate, no execution.
set -Eeuo pipefail
umask 077

: "${NYX_GRANT:?NYX_GRANT not set}"
: "${NYX_TARGET:?NYX_TARGET not set}"
TOOL="${1:?tool name required}"; shift

GATE=/lab/bin/gate
args=(verify --grant "$NYX_GRANT" --target "$NYX_TARGET" --tool "$TOOL")
[ -n "${NYX_STEPUP:-}" ] && args+=(--step-up "$NYX_STEPUP")

DEC="$("$GATE" "${args[@]}" 2>&1 || true)"
echo "$DEC"
if ! grep -q '"ok": true' <<<"$DEC"; then
  echo "NYX_DENIED code=$(grep -o '"code": "[^"]*"' <<<"$DEC" | cut -d'"' -f4)" >&2
  exit 90
fi

GID="$(grep -o '"grant_id": "[^"]*"' <<<"$DEC" | cut -d'"' -f4)"
EV="${NYX_EVIDENCE_ROOT:-/lab/outbox/evidence}/$(date -u +%F)/${GID}/$(date -u +%Y%m%dT%H%M%SZ)-${TOOL}"
mkdir -p "$EV"

set +e
"$TOOL" "$@" 2> >(tee "$EV/stderr" >&2) | tee "$EV/stdout"
RC="${PIPESTATUS[0]}"
set -e

python3 - "$EV" "$RC" "$TOOL" "$NYX_TARGET" "$GID" "$*" <<'PY'
import hashlib, json, os, sys, time
ev, rc, tool, target, gid, argv = sys.argv[1:7]
def h(p):
    d = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            d.update(b)
    return d.hexdigest()
meta = {"utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "grant_id": gid, "tool": tool, "target": target, "argv": argv,
        "exit_code": int(rc),
        "stdout": {"sha256": h(os.path.join(ev, "stdout")),
                   "bytes": os.path.getsize(os.path.join(ev, "stdout"))},
        "stderr": {"sha256": h(os.path.join(ev, "stderr")),
                   "bytes": os.path.getsize(os.path.join(ev, "stderr"))}}
with open(os.path.join(ev, "meta.json"), "w") as f:
    json.dump(meta, f, indent=2, sort_keys=True)
print(json.dumps({"evidence": ev, "exit_code": int(rc)}, sort_keys=True))
PY

[[ "$RC" -eq 0 ]] || exit "$RC"
