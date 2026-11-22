#!/usr/bin/env bash
# doctrine.sh — retrieval at the decision point, not at onboarding.
# ORDER: doctrine is mandatory before each phase and after the second failure.
set -Eeuo pipefail
D=${D:-/lab/doctrine}
IDX="$D/index.json"
USAGE=${USAGE:-/lab/state/doctrine/usage.jsonl}
POL=${POL:-/lab/etc/doctrine-policy.json}
mkdir -p "$(dirname "$USAGE")"

hit() { printf '%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$1" "$2" >>"$USAGE"; }

maxl() {
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("max_lines",120))' \
    "$POL" 2>/dev/null || echo 120
}

case "${1:-}" in
  match)
    key="${2:?usage: doctrine.sh match <trigger>}"
    map=$(python3 - "$IDX" "$key" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print("\n".join(d.get("map",{}).get(sys.argv[2],[])))
PY
)
    if [[ -z "$map" ]]; then
      hit "miss" "$key"
      echo "NO_CARD trigger=$key  (journal it before any network action: doctrine.sh fail <card> \"$key\" \"no card matched\")"
      exit 0
    fi
    hit "hit" "$key"
    n=$(maxl)
    while IFS= read -r p; do
      f="$D/$p.md"; [[ -f "$f" ]] || f="$D/cards/$p.md"
      if [[ -f "$f" ]]; then echo "--- $f"; sed -n "1,${n}p" "$f"; fi
    done <<<"$map"
    ;;
  card)
    id="${2:?card id}"
    f="$D/cards/$id.md"
    [[ -f "$f" ]] || { echo "NO_CARD id=$id"; hit "miss" "$id"; exit 0; }
    hit "card" "$id"; sed -n "1,$(maxl)p" "$f"
    ;;
  fail)
    id="${2:?card id}"; what="${3:-unspecified}"; why="${4:-}"
    f="$D/failures/$(date -u +%F)-${id}.md"
    mkdir -p "$D/failures"
    if [[ ! -s "$f" ]]; then
      printf -- '---\nid: F-%s\ncard: %s\nutc: %s\nfailures: %s\n---\n' \
        "$(date -u +%Y%m%d%H%M)" "$id" "$(date -u +%FT%TZ)" "$what" >"$f"
    fi
    { echo; echo "## محاولة فاشلة"; echo "- utc: $(date -u +%FT%TZ)";
      echo "- ما جُرِّب: $what"; echo "- السبب الحقيقي: ${why:-غير محدد}"; } >>"$f"
    hit "fail" "$id"; echo "logged $f"
    ;;
  case)
    id="${2:?case id}"
    f="$D/cases/$(date -u +%F)-${id}.md"
    mkdir -p "$D/cases"
    cat >"$f" <<EOT
---
case: $id
grant: ${NYX_GRANT_ID:-unknown}
utc: $(date -u +%FT%TZ)
hypotheses: 0
tested: 0
---
## ما ثبت
## ما كان قريبًا
## ما يُصلح أولًا
## استدعاءات doctrine
## مكتبة الفشل
EOT
    hit "case" "$id"; echo "created $f"
    ;;
  usage)
    python3 - "$USAGE" <<'PY'
import collections, sys
rows=[]
try:
    for line in open(sys.argv[1]):
        p=line.rstrip("\n").split("\t")
        if len(p)>=2: rows.append(p[1])
except FileNotFoundError:
    print("no usage log"); raise SystemExit(0)
c=collections.Counter(rows); tot=sum(c.values())
good=c.get("hit",0)+c.get("card",0)
print(f"total={tot} hit={c.get('hit',0)} card={c.get('card',0)} "
      f"miss={c.get('miss',0)} fail={c.get('fail',0)} case={c.get('case',0)}")
print(f"doctrine_hit_rate={(good*100/tot if tot else 0):.2f}%")
PY
    ;;
  *) echo "usage: doctrine.sh {match <trigger>|card <id>|fail <id> <what> [why]|case <id>|usage}"; exit 2 ;;
esac
