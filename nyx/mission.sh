#!/usr/bin/env bash
# Approved entrypoint:  mission start --targets "a,b" --code <code> --hours 24
set -uo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || exec sudo -n "$0" "$@"
GATE=/lab/bin/mission_gate.py
PY=$(command -v python3 || echo /usr/local/bin/python3)
cmd=${1:-status}; shift || true

case "$cmd" in
  start)
    targets=""; code=""; hours=24; objective="operator mission"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --targets|-t) targets="$2"; shift 2 ;;
        --code|-c)   code="$2"; shift 2 ;;
        --hours|-h)  hours="$2"; shift 2 ;;
        --objective|-o) objective="$2"; shift 2 ;;
        *) targets="${targets:+$targets }$1"; shift ;;
      esac
    done
    [[ -z "$targets" ]] && { echo '{"code":"deny_no_target"}'; exit 2; }
    if [[ -z "$code" || "$code" == "-" ]]; then read -r code; fi
    [[ -z "$code" ]] && { echo '{"code":"deny_no_code"}'; exit 2; }
    read -r -a inc <<<"$(printf '%s' "$targets" | tr ',' ' ')"
    ttl=$(( hours * 60 ))
    out=$(printf '%s' "$code" | "$PY" "$GATE" issue --operator-code-stdin \
          --objective "$objective" --include "${inc[@]}" --tools '*' --ttl "$ttl" 2>&1)
    printf '%s\n' "$out"
    grep -q '"code": "grant_issued"' <<<"$out" || exit 3
    "$PY" - <<'PY'
import json,time
d=json.load(open("/lab/state/mission/active.json"))
print("MISSION ACTIVE | grant=%s | targets=%s | expires=%sZ | hours_left=%.1f" % (
  d["grant_id"], ",".join(d["scope"]["include"]), time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(d["exp"])),
  (d["exp"]-time.time())/3600))
PY
    ;;
  status)
    [[ -f /lab/state/mission/active.json ]] || { echo "no active mission"; exit 1; }
    "$PY" - <<'PY'
import json,time
d=json.load(open("/lab/state/mission/active.json"))
print("MISSION ACTIVE | grant=%s | targets=%s | hours_left=%.1f | code=%s" % (
  d["grant_id"], ",".join(d["scope"]["include"]), (d["exp"]-time.time())/3600, d.get("code_sha256")))
PY
    ;;
  end)
    "$PY" "$GATE" end ;;
  check|up|boot)
    bash /lab/bin/session-init.sh ;;
  *)
    echo "usage: mission {start --targets \"a,b\" --code <code> --hours 24 | status | end | check}"; exit 2 ;;
esac
