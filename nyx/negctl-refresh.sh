#!/usr/bin/env bash
# Refresh the TEST-* fixtures used by RQ-17 negative controls.
# Test grants only: scope 127.0.0.1, tool nmap, never an engagement scope.
set -Eeuo pipefail
GATE=/lab/bin/gate
T=/lab/state/test
mkdir -p "$T"

exp=$(python3 -c 'import json;print(json.load(open("/lab/state/test/valid.json"))["grant"]["exp"])' 2>/dev/null || echo 0)
if (( exp - $(date +%s) <= 600 )); then
  out=$("$GATE" issue --objective "readiness negative controls (TEST)" \
        --include 127.0.0.1 --tools nmap --ttl 480)
  p=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["grant_path"])' <<<"$out")
  install -m 644 "$p" "$T/valid.json"
  python3 - <<'PY'
import json
d = json.load(open('/lab/state/test/valid.json'))
d['grant']['objective'] = 'widened by tamper test'
json.dump(d, open('/lab/state/test/tampered.json', 'w'), indent=2, sort_keys=True)
PY
  echo "negctl: TEST grant refreshed"
else
  echo "negctl: TEST grant valid"
fi

if [[ ! -f "$T/expired.json" ]]; then
  out=$("$GATE" issue --objective "expired fixture (TEST)" \
        --include 127.0.0.1 --tools nmap --ttl 1)
  p=$(python3 -c 'import json,sys;print(json.load(sys.stdin)["grant_path"])' <<<"$out")
  install -m 644 "$p" "$T/expired.json"
  echo "negctl: expired fixture created (valid in 60s of expiry)"
fi
