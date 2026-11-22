#!/usr/bin/env bash
# ORDER NYX-READINESS-01, trigger #2: re-run readiness when the lab changes
# (policy edit, tool install, container change, egress change, clock drift).
# Trigger #1 (session start) is AGENTS.md rule 0 + runtime-boot.sh.
set -uo pipefail

READY=${READY:-/lab/bin/session-ready.sh}
STATE=${STATE:-/lab/state/readiness}
LOG=$STATE/triggers.log
AGENT_USER=${AGENT_USER:-openhands}
INTERVAL=${INTERVAL:-5}
DEBOUNCE=${DEBOUNCE:-3}
MAX_DRIFT=${MAX_DRIFT:-5}
CLOCK_EVERY=${CLOCK_EVERY:-12}

mkdir -p "$STATE"
exec 9>"$STATE/.watch.lock"
flock -n 9 || exit 0

h() { sha256sum | cut -d' ' -f1; }
fp_policy()    { find /lab/etc -maxdepth 1 -type f -printf '%f %s %T@\n' 2>/dev/null | sort | h; }
fp_tools()     { find /lab/bin /usr/local/bin -maxdepth 1 -type f -printf '%p %s %T@\n' 2>/dev/null | sort | h; }
fp_container() { docker ps --format '{{.Names}} {{.Status}} {{.Image}}' 2>/dev/null | sort | h; }
fp_egress()    { { ip route show default 2>/dev/null; grep -v '^#' /etc/resolv.conf 2>/dev/null; } | h; }

drift() {
  local http hs now
  http=$(curl -sI -m 5 https://example.com 2>/dev/null \
    | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r')
  [[ -z "$http" ]] && { echo 0; return; }
  hs=$(date -u -d "$http" +%s 2>/dev/null) || { echo 0; return; }
  now=$(date -u +%s)
  echo $(( now > hs ? now - hs : hs - now ))
}

run() {
  printf '%s trigger=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG"
  sudo -n -u "$AGENT_USER" env NYX_TEST_GRANT=/lab/state/test/valid.json \
    "$READY" >> "$LOG" 2>&1 || true
}

P=$(fp_policy); T=$(fp_tools); C=$(fp_container); E=$(fp_egress)
printf '%s watch=start policy=%s tools=%s containers=%s egress=%s\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$P" "$T" "$C" "$E" >> "$LOG"

n=0
while sleep "$INTERVAL"; do
  p=$(fp_policy); t=$(fp_tools); c=$(fp_container); e=$(fp_egress)
  reason=""
  [[ "$p" != "$P" ]] && reason+="policy "
  [[ "$t" != "$T" ]] && reason+="tools "
  [[ "$c" != "$C" ]] && reason+="container "
  [[ "$e" != "$E" ]] && reason+="egress "
  n=$(( n + 1 ))
  if (( n % CLOCK_EVERY == 0 )); then
    d=$(drift)
    (( d > MAX_DRIFT )) && reason+="clock(+${d}s) "
  fi
  if [[ -n "$reason" ]]; then
    sleep "$DEBOUNCE"
    P=$(fp_policy); T=$(fp_tools); C=$(fp_container); E=$(fp_egress)
    run "${reason% }"
  fi
done
