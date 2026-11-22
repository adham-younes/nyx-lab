#!/usr/bin/env bash
# Cold-start of the whole lab for a new session. Idempotent, never blocks, exit 0.
set -uo pipefail
export NYX_SYSTEM=1
LAB=/lab; KALI=/workspace/kali; REPO=/workspace/nyx-lab; MYTHIC=/workspace/mythic
ok=0; bad=0
row() { if [[ $2 -eq 0 ]]; then ok=$((ok+1)); printf 'ok   %-10s %s\n' "$1" "$3"; else bad=$((bad+1)); printf 'FAIL %-10s %s\n' "$1" "$3"; fi; }

# 0. the container root is ephemeral: /lab is a symlink into the persistent volume
[[ -e /lab ]] || ln -sfn /workspace/lab /lab
mkdir -p "$LAB"/{bin,etc,state/{grants,test,readiness},outbox/evidence,host/anchors}

# 1. gate
python3 "$LAB/bin/mission_gate.py" integrity 2>/dev/null | grep -q integrity_ok; row gate $? "hmac seal"
echo exec > "$LAB/state/mode"

# 2. arsenal: sync automation from the repo, then apply it
for f in nyx.sh setup-wrappers.sh enter.sh install-extras.sh; do
  if [[ -f "$REPO/docker/lab/$f" ]] && ! cmp -s "$REPO/docker/lab/$f" "$KALI/$f"; then
    install -m 0755 -o root -g root "$REPO/docker/lab/$f" "$KALI/$f"
  fi
done
[[ -x "$KALI/setup-wrappers.sh" ]] && bash "$KALI/setup-wrappers.sh" >/dev/null 2>&1
wrappers=$(grep -l 'kali/enter.sh' /usr/local/bin/* 2>/dev/null | wc -l)
row arsenal $(( wrappers < 90 )) "$wrappers tools -> kali chroot"

# 3. docker daemon
if ! docker info >/dev/null 2>&1; then
  (dockerd --data-root=/workspace/docker >/var/log/dockerd.log 2>&1 &)
  for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 1; done
fi
docker info >/dev/null 2>&1; row docker $? "$(docker ps -q 2>/dev/null | wc -l) containers"

# 4. mythic teamserver (recovers from stale layers after an unclean restart)
if docker info >/dev/null 2>&1 && [[ -f "$MYTHIC/docker-compose.yml" ]]; then
  up() { (cd "$MYTHIC" && docker compose up -d >/dev/null 2>&1); }
  wait_up() { for _ in $(seq 1 ${1:-20}); do docker ps --format '{{.Names}}' 2>/dev/null | grep -q mythic_nginx && return 0; sleep 2; done; return 1; }
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q mythic_nginx; then
    up; wait_up 20 || {
      (cd "$MYTHIC" && docker compose down --remove-orphans >/dev/null 2>&1)
      docker ps -aq 2>/dev/null | xargs -r docker rm -f >/dev/null 2>&1
      up; wait_up 45
    }
  fi
fi
docker ps --format '{{.Names}}' 2>/dev/null | grep -q mythic_nginx; row mythic $? "teamserver :7443"

# 5. relay (optional)
if ! ss -ltn 2>/dev/null | grep -q ':9050' && [[ -x "$KALI/enter.sh" ]]; then
  (nohup "$KALI/enter.sh" tor >/var/log/tor-nyx.log 2>&1 &)
  for _ in $(seq 1 15); do ss -ltn 2>/dev/null | grep -q ':9050' && break; sleep 1; done
fi
if ss -ltn 2>/dev/null | grep -q ':9050'; then row relay 0 "socks 9050 up"; else row relay 1 "socks 9050 down (optional)"; fi

# 6. memory reflects measurement
bash "$LAB/bin/memory-close.sh" >/dev/null 2>&1

live=$(python3 -c 'import json;d=json.load(open("/lab/etc/mission-policy.json"));l=json.load(open("/lab/state/operator-codes.json"));print(len(d["operator_codes"]["codes"])-len(l))' 2>/dev/null || echo '?')
printf 'SESSION-READY | gate=%s wrappers=%s containers=%s mythic=%s mode=%s codes_live=%s\n' \
  "$([[ $bad -eq 0 ]] && echo ok || echo degraded:$bad)" "$wrappers" \
  "$(docker ps -q 2>/dev/null | wc -l)" \
  "$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c mythic_)" \
  "$(cat "$LAB/state/mode")" "$live"
exit 0
