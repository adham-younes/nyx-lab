#!/bin/bash
# nyx — activate the offensive lab, the gate and the router.
#   nyx          activate (mounts, wrappers, docker, Mythic, gate, relay, router) + report
#   nyx full     activate + start Tor (SOCKS5 127.0.0.1:9050)
#   nyx df       disk report
#   nyx clean    prune caches (chroot tmp/cache/go modcache, apt lists, docker dangling)
set -u
ROOT=/workspace/kali
SELF=$(readlink -f "$0")

disk() { df -h /workspace | awk 'NR==2{printf "disk: %s used / %s total — %s free (%s)\n",$3,$2,$4,$5}'; }

if [ "${1:-}" = df ]; then disk; exit 0; fi

[ "$(id -u)" = 0 ] || exec sudo -n "$SELF" "$@"

case "${1:-}" in
  clean)
    echo "[clean] chroot tmp/caches/apt lists"
    rm -rf "$ROOT"/tmp/* "$ROOT"/root/.cache/* "$ROOT"/root/go/pkg/mod/cache \
           "$ROOT"/var/lib/apt/lists/* "$ROOT"/var/cache/apt/archives/* 2>/dev/null
    docker system prune -f >/dev/null 2>&1 && echo "[clean] docker dangling pruned"
    disk; exit 0;;
esac

bash "$ROOT/bootstrap.sh" status

# NYX gate: /lab must survive root wipes; state dirs belong to the runtime user.
[ -e /lab ] || ln -s /workspace/lab /lab
chown -R openhands:openhands /lab/state /lab/outbox /lab/var /lab/share 2>/dev/null || true
if python3 /lab/bin/mission_gate.py integrity >/dev/null 2>&1; then
  echo "gate: integrity_ok"
else
  echo "gate: INTEGRITY_FAIL (run: mission_gate.py seal)"
fi

# Relay (og-relay.mjs) + router readiness.
if [ -f /workspace/og-relay.mjs ]; then
  bash /lab/bin/runtime-boot.sh 2>/dev/null | tail -1
fi
if python3 /lab/bin/nyx-router.py --dry-run svc_scan 0.0.0.0 >/dev/null 2>&1; then
  echo "router: ready · actions=$(python3 -c 'import json;print(len(json.load(open("/lab/etc/actions.json"))))' 2>/dev/null) (policy-crosschecked)"
else
  echo "router: NOT_READY"
fi

if [ "${1:-}" = full ]; then
  echo "[tor] starting"
  chroot "$ROOT" sh /opt/tor-up.sh 2>&1 | tail -2
fi
echo "arsenal: $(grep -l kali-chroot-wrapper /usr/local/bin/* 2>/dev/null | wc -l) wrappers · $(docker ps -q 2>/dev/null | wc -l) containers"
disk

/lab/bin/session-ready.sh || true
