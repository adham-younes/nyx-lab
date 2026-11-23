#!/usr/bin/env bash
# One-command session bring-up. Idempotent, bounded, always exits 0.
#   sudo nyx/session-up.sh          full: lab layout, mounts, gate, wrappers, tor, docker, mythic, readiness
#   sudo nyx/session-up.sh --fast   skip readiness probe and mythic wait
# Warm session ~10s. A brand-new container (empty root) is detected and rebuilt.
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
row() {
  case "$1" in
    ok)   ok=$((ok+1));     printf '  ok    %-10s %s\n' "$2" "$3" ;;
    skip) skip=$((skip+1)); printf '  --    %-10s %s\n' "$2" "$3" ;;
    *)    bad=$((bad+1));   printf '  FAIL  %-10s %s\n' "$2" "$3" ;;
  esac
}
t0=$(date +%s)

echo "[nyx] session-up  $(date -u +%FT%TZ)  repo=$REPO"

# 0. stable repo path
[[ -e /workspace/nyx-lab ]] || ln -sfn "$REPO" /workspace/nyx-lab

# 0b. agent config dirs must survive a container rebuild (keys live here)
for d in profiles provider-connections; do
  install -d -m 0755 "/workspace/.openhands/$d"
  chown openhands:openhands "/workspace/.openhands/$d" 2>/dev/null
  install -d -m 0700 "/home/openhands/.openhands/$d" 2>/dev/null
  mountpoint -q "/home/openhands/.openhands/$d" 2>/dev/null || \
    mount --bind "/workspace/.openhands/$d" "/home/openhands/.openhands/$d" 2>/dev/null
done

# 0c. repo sync: fast-forward only, never touch local commits
if [[ -d $REPO/.git ]]; then
  if timeout 30 git -C "$REPO" fetch -q origin 2>/dev/null; then
    if timeout 30 git -C "$REPO" merge --ff-only -q origin/main >/dev/null 2>&1; then
      row ok repo "fast-forwarded to $(git -C "$REPO" rev-parse --short HEAD)"
    else
      row skip repo "local commits kept at $(git -C "$REPO" rev-parse --short HEAD)"
    fi
  else
    row skip repo "no network / offline"
  fi
fi

# 1. /lab must live on the persistent volume: the container root is ephemeral
if [[ -d $LAB && ! -L $LAB ]]; then
  install -d -m 0755 /workspace/lab
  cp -a "$LAB/." /workspace/lab/ 2>/dev/null
  rm -rf "$LAB"
fi
[[ -L $LAB ]] || ln -sfn /workspace/lab $LAB
install -d -m 0755 "$LAB"/{bin,etc,state/{grants,test,readiness,anchors},outbox/evidence,var,share/{feeds,wordlists}} 2>/dev/null

# 2. gate layer: rebuilt from the repo when the container came up empty
if [[ ! -x $LAB/bin/gate ]]; then
  timeout 240 bash "$REPO/bootstrap/install.sh" >/tmp/nyx-bootstrap.log 2>&1 &
  bp=$!
  for _ in $(seq 1 60); do [[ -x $LAB/bin/gate ]] && break; sleep 1; done
  sleep 3; kill "$bp" 2>/dev/null
  [[ -x $LAB/bin/gate ]] && row ok lab "rebuilt from bootstrap/install.sh" || row fail lab "see /tmp/nyx-bootstrap.log"
else
  row skip lab "gate present"
fi
[[ -f $LAB/state/mode ]] || echo exec > "$LAB/state/mode"
chown -R openhands:openhands "$LAB/state" "$LAB/outbox" "$LAB/var" "$LAB/share" 2>/dev/null

# 3. chroot mounts (cheap when present)
miss=""
for m in proc sys dev dev/pts; do
  mountpoint -q "$KALI/$m" || { mkdir -p "$KALI/$m"; mount --bind "/$m" "$KALI/$m" 2>/dev/null; }
  mountpoint -q "$KALI/$m" || miss+="$m "
done
[[ -z $miss ]] && row ok mounts "proc/sys/dev bound" || row fail mounts "missing: $miss"

# 4. gate seal
if python3 "$LAB/bin/mission_gate.py" integrity 2>/dev/null | grep -q integrity_ok; then
  row ok gate "hmac seal ok"
else
  row fail gate "run: mission_gate.py seal"
fi

# 5. wrappers: regenerate only when the generator changed
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

# 6. feeds, templates, wordlists: the chroot keeps the originals, /lab gets what the checks read
[[ -s $LAB/share/feeds/known_exploited_vulnerabilities.json ]] || \
  cp -f "$KALI/opt/feeds/kev.json" "$LAB/share/feeds/known_exploited_vulnerabilities.json" 2>/dev/null
[[ -e $LAB/share/nuclei-templates ]] || ln -sfn "$KALI/root/.local/nuclei-templates" "$LAB/share/nuclei-templates"
if ! find "$LAB/share/wordlists" -maxdepth 1 -type f 2>/dev/null | grep -q .; then
  cp -f "$KALI/usr/share/wordlists/rockyou.txt" "$LAB/share/wordlists/rockyou.txt" 2>/dev/null
  cp -f "$KALI/usr/share/seclists/Discovery/Web-Content/common.txt" "$LAB/share/wordlists/common.txt" 2>/dev/null
fi
chown -R openhands:openhands "$LAB/share" 2>/dev/null
row ok feeds "$(ls "$LAB/share/wordlists" 2>/dev/null | wc -l) wordlists · kev $( [[ -s $LAB/share/feeds/known_exploited_vulnerabilities.json ]] && echo present || echo MISSING)"

# 6b. TEST fixtures for the negative controls (they expire) + host proxychains
exp=$(python3 -c 'import json;print(json.load(open("/lab/state/test/valid.json"))["grant"]["exp"])' 2>/dev/null || echo 0)
if (( exp - $(date +%s) <= 600 )); then
  "$LAB/bin/negctl-refresh.sh" >/dev/null 2>&1
  row ok fixtures "TEST grant refreshed"
else
  row skip fixtures "TEST grant valid"
fi
if ! command -v proxychains4 >/dev/null 2>&1; then
  [[ -s /var/lib/apt/lists/partial/../*Packages* ]] || apt-get update -qq >/dev/null 2>&1
  apt-get install -y -qq proxychains4 >/dev/null 2>&1
  sed -i 's/^socks4.*9050/socks5 127.0.0.1 9050/' /etc/proxychains4.conf 2>/dev/null
  row ok proxychains "host binary restored"
else
  row skip proxychains "present"
fi

# 7. tor
if port_open 9050; then
  row skip tor "socks 9050 already up"
elif [[ -x "$KALI/opt/tor-up.sh" ]]; then
  chroot "$KALI" sh /opt/tor-up.sh </dev/null >/dev/null 2>&1
  for _ in $(seq 1 10); do port_open 9050 && break; sleep 1; done
  port_open 9050 && row ok tor "socks 9050 up" || row fail tor "see $KALI/var/lib/tor-lab/notices.log"
else
  row fail tor "no /opt/tor-up.sh"
fi

# 8. docker
if docker info >/dev/null 2>&1; then
  row skip docker "$(docker ps -q 2>/dev/null | wc -l) containers"
else
  ( setsid dockerd --data-root=/workspace/docker >/var/log/dockerd.log 2>&1 & )
  for _ in $(seq 1 20); do docker info >/dev/null 2>&1 && break; sleep 1; done
  docker info >/dev/null 2>&1 && row ok docker "daemon up" || row fail docker "see /var/log/dockerd.log"
fi

# 9. mythic (no rebuild; bounded wait)
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

# 10. arsenal fingerprint (count + content)
man_n=$(wc -l < "$LAB/state/tools.sha256" 2>/dev/null || echo 0)
now_n=$(find /usr/local/bin "$LAB/bin" -maxdepth 1 -type f | wc -l)
if [[ "$man_n" != "$now_n" ]] || ! sha256sum -c --quiet "$LAB/state/tools.sha256" >/dev/null 2>&1; then
  find /usr/local/bin "$LAB/bin" -maxdepth 1 -type f -print0 | sort -z | xargs -0 sha256sum > "$LAB/state/tools.sha256"
  chmod 0644 "$LAB/state/tools.sha256"
  row ok manifest "refreshed $(wc -l < "$LAB/state/tools.sha256") entries"
else
  row skip manifest "$(wc -l < "$LAB/state/tools.sha256") entries intact"
fi

# 11. readiness
install -d -m 0750 /workspace/nyx-anchors
chown openhands:openhands /workspace/nyx-anchors 2>/dev/null
ANCHOR_SINK=${NYX_ANCHOR_SINK:-/workspace/nyx-anchors}
report="skipped (fast mode)"
if (( ! FAST )); then
  report=$(timeout 240 sudo -n -u openhands env NYX_TEST_GRANT=$LAB/state/test/valid.json \
            NYX_ANCHOR_SINK="$ANCHOR_SINK" \
            "$LAB/bin/session-ready.sh" 2>/dev/null | grep -m1 '^NYX-REPORT' || true)
  [[ -n "$report" ]] || report="session-ready.sh produced no report"
fi

dt=$(( $(date +%s) - t0 ))
printf '[nyx] %s\n' "$report"
printf 'SESSION-READY | ok=%d fail=%d skipped=%d | wrappers=%d containers=%d tor=%s | %ss\n' \
  "$ok" "$bad" "$skip" "$n_wrap" "$(docker ps -q 2>/dev/null | wc -l)" \
  "$(port_open 9050 && echo up || echo down)" "$dt"
exit 0
