#!/usr/bin/env bash
# One-command session bring-up. Idempotent, bounded, always exits 0.
#   sudo nyx/session-up.sh          full: mounts, gate, wrappers, tor, docker, mythic, readiness
#   sudo nyx/session-up.sh --fast   skip readiness probe and mythic wait
# Every stage is skipped when already satisfied, so a warm session takes seconds.
set -uo pipefail
SELF=$(readlink -f "$0")
REPO=$(cd "$(dirname "$SELF")/.." && pwd)
KALI=${KALI_ROOT:-/workspace/kali}
LAB=/lab
FAST=0
[[ "${1:-}" == "--fast" ]] && FAST=1

[ "$(id -u)" = 0 ] || exec sudo -n "$SELF" "$@"

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null && exec 3>&- && return 0 || return 1; }
ok=0; bad=0; skip=0
row() { # row <state> <name> <detail>
  case "$1" in
    ok)   ok=$((ok+1));   printf '  ok    %-10s %s\n' "$2" "$3" ;;
    skip) skip=$((skip+1)); printf '  --    %-10s %s\n' "$2" "$3" ;;
    *)    bad=$((bad+1)); printf '  FAIL  %-10s %s\n' "$2" "$3" ;;
  esac
}
t0=$(date +%s)

echo "[nyx] session-up  $(date -u +%FT%TZ)  repo=$REPO"

# 0. stable repo path + lab layout
[[ -e /workspace/nyx-lab ]] || ln -sfn "$REPO" /workspace/nyx-lab
install -d -m 0755 "$LAB"/{bin,etc,state/{grants,test,readiness,anchors},outbox/evidence,var,share/{feeds,wordlists}} 2>/dev/null
[[ -f $LAB/state/mode ]] || echo exec > "$LAB/state/mode"
chown -R openhands:openhands "$LAB/state" "$LAB/outbox" "$LAB/var" "$LAB/share" 2>/dev/null

# 1. chroot mounts (cheap when present)
miss=""
for m in proc sys dev dev/pts; do
  mountpoint -q "$KALI/$m" || { mkdir -p "$KALI/$m"; mount --bind "/$m" "$KALI/$m" 2>/dev/null; }
  mountpoint -q "$KALI/$m" || miss+="$m "
done
[[ -z $miss ]] && row ok mounts "proc/sys/dev bound" || row fail mounts "missing: $miss"

# 2. gate seal
if python3 "$LAB/bin/mission_gate.py" integrity 2>/dev/null | grep -q integrity_ok; then
  row ok gate "hmac seal ok"
else
  row fail gate "run: mission_gate.py seal"
fi

# 3. wrappers: regenerate only when the generator or the tool set changed
stamp=$LAB/state/.wrappers.stamp
want=$(sha256sum "$KALI/setup-wrappers.sh" 2>/dev/null | cut -d' ' -f1)
have=$(cat "$stamp" 2>/dev/null || true)
n_wrap=$(grep -l 'kali/enter.sh' /usr/local/bin/* 2>/dev/null | wc -l)
if [[ "$want" == "$have" && $n_wrap -ge 60 ]]; then
  row skip wrappers "$n_wrap wrappers (unchanged)"
else
  bash "$KALI/setup-wrappers.sh" >/dev/null 2>&1
  n_wrap=$(grep -l 'kali/enter.sh' /usr/local/bin/* 2>/dev/null | wc -l)
  echo "$want" > "$stamp"
  row ok wrappers "$n_wrap wrappers"
fi

# 4. tor (socks 9050)
if port_open 9050; then
  row skip tor "socks 9050 already up"
elif [[ -x "$KALI/opt/tor-up.sh" ]]; then
  chroot "$KALI" sh /opt/tor-up.sh </dev/null >/dev/null 2>&1
  for _ in $(seq 1 10); do port_open 9050 && break; sleep 1; done
  port_open 9050 && row ok tor "socks 9050 up" || row fail tor "see $KALI/var/lib/tor-lab/notices.log"
else
  row fail tor "no /opt/tor-up.sh"
fi

# 5. docker daemon
if docker info >/dev/null 2>&1; then
  row skip docker "$(docker ps -q 2>/dev/null | wc -l) containers"
else
  ( setsid dockerd --data-root=/workspace/docker >/var/log/dockerd.log 2>&1 & )
  for _ in $(seq 1 20); do docker info >/dev/null 2>&1 && break; sleep 1; done
  docker info >/dev/null 2>&1 && row ok docker "daemon up" || row fail docker "see /var/log/dockerd.log"
fi

# 6. mythic (no rebuild; bounded wait)
if [[ -f /workspace/mythic/docker-compose.yml ]] && docker info >/dev/null 2>&1; then
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q mythic_nginx; then
    row skip mythic "teamserver already up"
  elif (( FAST )); then
    row skip mythic "fast mode"
  else
    ( cd /workspace/mythic && ./mythic-cli start >/tmp/mythic-start.log 2>&1 )
    for _ in $(seq 1 60); do
      docker ps --format '{{.Names}}' 2>/dev/null | grep -q mythic_nginx && break; sleep 2
    done
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q mythic_nginx \
      && row ok mythic "teamserver :7443" || row fail mythic "see /tmp/mythic-start.log"
  fi
else
  row skip mythic "not installed"
fi

# 7. arsenal fingerprint (only if it drifted)
man_n=$(wc -l < "$LAB/state/tools.sha256" 2>/dev/null || echo 0)
now_n=$(find /usr/local/bin "$LAB/bin" -maxdepth 1 -type f | wc -l)
if [[ "$man_n" != "$now_n" ]] || ! sha256sum -c --quiet "$LAB/state/tools.sha256" >/dev/null 2>&1; then
  find /usr/local/bin "$LAB/bin" -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum > "$LAB/state/tools.sha256"
  chmod 0644 "$LAB/state/tools.sha256"
  row ok manifest "refreshed $(wc -l < "$LAB/state/tools.sha256") entries"
else
  row skip manifest "$(wc -l < "$LAB/state/tools.sha256") entries intact"
fi

# 8. readiness report
report="skipped (fast mode)"
if (( ! FAST )); then
  report=$(timeout 240 sudo -n -u openhands env NYX_TEST_GRANT=$LAB/state/test/valid.json \
            "$LAB/bin/session-ready.sh" 2>/dev/null | grep -m1 '^NYX-REPORT' || true)
  [[ -n "$report" ]] || report="session-ready.sh produced no report"
fi

dt=$(( $(date +%s) - t0 ))
printf '[nyx] %s\n' "$report"
printf 'SESSION-READY | ok=%d fail=%d skipped=%d | wrappers=%d containers=%d tor=%s | %ss\n' \
  "$ok" "$bad" "$skip" "$n_wrap" "$(docker ps -q 2>/dev/null | wc -l)" \
  "$(port_open 9050 && echo up || echo down)" "$dt"
exit 0
