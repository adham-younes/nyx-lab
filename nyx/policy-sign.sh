#!/usr/bin/env bash
# Operator-only: sign the readiness policy with the operator key.
# The agent key must never verify alone (ORDER NYX-READINESS-02, RULE 8).
# usage: policy-sign.sh <operator.key> [policy.json]
set -Eeuo pipefail
KEY="${1:?usage: policy-sign.sh <operator.key> [policy.json]}"
POL="${2:-/lab/etc/readiness-policy.json}"
SIG="${POL%.json}.sig"
LED=/lab/state/policy-versions.log
ver=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$POL")
sha=$(sha256sum "$POL" | cut -d' ' -f1)
msg=$(mktemp); trap 'rm -f "$msg"' EXIT
printf 'version=%s sha256=%s\n' "$ver" "$sha" >"$msg"
openssl pkeyutl -sign -inkey "$KEY" -rawin -in "$msg" -out "$SIG"
chmod 0444 "$SIG"; chown root:root "$SIG" 2>/dev/null || true
openssl pkey -in "$KEY" -pubout -out "${POL%.json}.pub" 2>/dev/null || true
chmod 0444 "${POL%.json}.pub"; chown root:root "${POL%.json}.pub" 2>/dev/null || true
mkdir -p "$(dirname "$LED")"
printf '%s version=%s sha256=%s sig=ok\n' "$(date -u +%FT%TZ)" "$ver" "$sha" >>"$LED"
echo "signed: version=$ver sha=${sha:0:16} -> $SIG"
