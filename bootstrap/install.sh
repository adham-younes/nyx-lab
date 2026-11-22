#!/usr/bin/env bash
# NYX lab bootstrap: rebuild the gate on a fresh sandbox. Idempotent.
# Usage: sudo bash bootstrap/install.sh
set -Eeuo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
AGENT_USER="${AGENT_USER:-openhands}"
PY="${PY:-/usr/local/bin/python3}"
[[ -x "$PY" ]] || PY=$(command -v python3)

if [[ "$(id -u)" != 0 ]]; then
  exec sudo -n "$0" "$@"
fi

log() { printf '[nyx] %s\n' "$*"; }

log "layout"
install -d -m 0755 /lab /lab/bin /lab/etc /lab/state /lab/state/grants \
  /lab/state/anchors /lab/state/readiness /lab/state/test /lab/outbox \
  /lab/var /lab/share /lab/share/wordlists /lab/share/feeds
chown root:root /lab /lab/bin /lab/etc
chmod 0755 /lab /lab/bin /lab/etc
chmod g-s /lab /lab/bin /lab/etc

log "service user"
id -u nyx >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin -d /nonexistent nyx

log "binaries"
install -m 0755 -o root -g root \
  "$REPO/nyx/mission_gate.py" \
  "$REPO/nyx/nyx-exec.sh" \
  "$REPO/nyx/session-ready.sh" \
  "$REPO/nyx/negctl-refresh.sh" \
  "$REPO/nyx/runtime-boot.sh" \
  "$REPO/nyx/gate" \
  "$REPO/router/nyx-router.py" \
  "$REPO/evals/refusal_probe.py" /lab/bin/
ln -sfn /lab/bin/runtime-boot.sh /workspace/runtime-boot.sh
if [[ -f "$REPO/relay/og-relay.mjs" ]]; then
  install -m 0644 -o root -g root "$REPO/relay/og-relay.mjs" /workspace/og-relay.mjs
fi

log "policy (0444 root)"
install -m 0444 -o root -g root \
  "$REPO/nyx/mission-policy.json" \
  "$REPO/nyx/tool-policy.json" \
  "$REPO/nyx/actions.json" \
  "$REPO/nyx/envelope.md" \
  "$REPO/nyx/refusal_suite.json" \
  "$REPO/nyx/readiness-policy.json" \
  "$REPO/nyx/egress.json" \
  "$REPO/nyx/root-exception.md" /lab/etc/

log "signing key"
if [[ ! -s /lab/etc/gate.key ]]; then
  "$PY" /lab/bin/mission_gate.py init
fi
chown root:root /lab/etc/gate.key
chmod 400 /lab/etc/gate.key
if [[ ! -s /lab/etc/relay.key ]]; then
  openssl rand -hex 32 > /lab/etc/relay.key 2>/dev/null \
    || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > /lab/etc/relay.key
  chown root:root /lab/etc/relay.key
  chmod 600 /lab/etc/relay.key
fi

log "seal"
"$PY" /lab/bin/mission_gate.py seal

log "state ownership"
for d in /lab/state /lab/outbox /lab/var /lab/share; do
  chown -R "$AGENT_USER":"$AGENT_USER" "$d"
done

log "test fixtures"
/lab/bin/negctl-refresh.sh || log "fixtures: skipped (gate not ready)"

log "arsenal fingerprint"
find /usr/local/bin /lab/bin -maxdepth 1 -type f -print0 \
  | sort -z | xargs -0 sha256sum > /lab/etc/tools.sha256
chmod 0444 /lab/etc/tools.sha256

log "repo manifest"
bash "$REPO/nyx/seal.sh" >/dev/null

log "readiness (as $AGENT_USER)"
sudo -n -u "$AGENT_USER" env NYX_TEST_GRANT=/lab/state/test/valid.json \
  /lab/bin/session-ready.sh || true
