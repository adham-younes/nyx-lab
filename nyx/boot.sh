#!/usr/bin/env bash
# Idempotent session boot. Never blocks. Restores state a new session needs.
set -uo pipefail
LAB=/lab
log() { printf '%s\n' "$*"; }

mkdir -p "$LAB"/{bin,etc,state/{grants,test,readiness,evidence},outbox/evidence,host/anchors}

if [[ ! -s /lab/etc/fixture.code ]]; then
  head -c 5 /dev/urandom | od -An -tx1 | tr -d ' \n' > /lab/etc/fixture.code
  chmod 0600 /lab/etc/fixture.code
  sha256sum /lab/etc/fixture.code | cut -d' ' -f1 | tr -d '\n' > /lab/etc/fixture.sha256
  chmod 0444 /lab/etc/fixture.sha256
fi

mkdir -p /srv/nyx-anchors
if ! findmnt -no TARGET /lab/host/anchors >/dev/null 2>&1; then
  mount --bind /srv/nyx-anchors /lab/host/anchors 2>/dev/null \
    && mount -o remount,ro,bind /lab/host/anchors 2>/dev/null
fi

echo exec > "$LAB/state/mode"
find /usr/local/bin /lab/bin -maxdepth 1 -type f -print0 2>/dev/null \
  | sort -z | xargs -0 sha256sum > /lab/etc/tools.sha256 2>/dev/null
chmod 0444 /lab/etc/tools.sha256 2>/dev/null

python3 /lab/bin/mission_gate.py integrity 2>/dev/null | head -c 120; echo
log "mode=$(cat "$LAB/state/mode") grants=$(ls "$LAB"/state/grants/*.json 2>/dev/null | wc -l) codes_ledger=$([[ -f $LAB/state/operator-codes.json ]] && echo present || echo empty)"
