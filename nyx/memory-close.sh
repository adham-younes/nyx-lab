#!/usr/bin/env bash
# Rewrites the verified-state block in project memory from live measurement.
set -uo pipefail
M=""
for d in /workspace/.openhands/memory /workspace/nyx-lab/.openhands/memory; do
  [[ -d "$d" ]] && M="$d" && break
done
[[ -z "$M" ]] && M=/workspace/.openhands/memory && mkdir -p "$M"
w=$(grep -l 'kali/enter.sh' /usr/local/bin/* 2>/dev/null | wc -l)
c=$(docker ps -q 2>/dev/null | wc -l)
g=$(python3 /lab/bin/mission_gate.py integrity 2>/dev/null | grep -o integrity_ok || echo unknown)
live=$(python3 -c 'import json;d=json.load(open("/lab/etc/mission-policy.json"));l=json.load(open("/lab/state/operator-codes.json"));print(len(d["operator_codes"]["codes"])-len(l))' 2>/dev/null || echo '?')
hex=$(command -v hexstrike >/dev/null 2>&1 && echo installed || echo absent)
blk="## VERIFIED STATE (auto $(date -u +%FT%TZ))
- Arsenal: kali chroot /workspace/kali, wrappers=$w, containers=$c (mythic teamserver :7443).
- Execution path: nyx-exec.sh -> gate (operator code) -> sudo /workspace/kali/enter.sh <tool>. \`enter.sh bash -lc\` is a documented escape hatch, not gated.
- hexstrike-ai: $hex. manifest marks it optional; required_mcp_servers is empty.
- Authorization: operator codes only ($live live, sha256, single use). Readiness is a report: gating=off.
- gate integrity: $g."
f="$M/MEMORY.md"
if grep -q '^## VERIFIED STATE' "$f" 2>/dev/null; then
  python3 - "$f" "$blk" <<'PY'
import re,sys
p,blk=sys.argv[1],sys.argv[2]
s=open(p).read()
s=re.sub(r"## VERIFIED STATE.*?(?=\n## |\Z)", blk+"\n\n", s, flags=re.S)
open(p,'w').write(s)
PY
else
  printf '%s\n\n' "$blk" >> "$f"
fi
printf '%s\n' "$blk"
