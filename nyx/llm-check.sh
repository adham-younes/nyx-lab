#!/usr/bin/env bash
# Verify every saved LLM profile against its provider without printing secrets.
#   nyx/llm-check.sh          probe /models and one tiny completion
#   nyx/llm-check.sh --quick  probe /models only
set -uo pipefail
DIR=${NYX_PROFILES:-$HOME/.openhands/profiles}
QUICK=0; [[ "${1:-}" == "--quick" ]] && QUICK=1
[[ -d $DIR ]] || { echo "no profile dir: $DIR"; exit 0; }
printf '%-28s %-44s %-6s %s\n' PROFILE ENDPOINT /models VERDICT
for f in "$DIR"/*.json; do
  name=$(basename "$f" .json)
  read -r model base key < <(python3 - "$f" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print(d.get("model",""), d.get("base_url",""), d.get("api_key",""))
PY
)
  [[ -z ${base:-} ]] && { printf '%-28s %-44s %-6s %s\n' "$name" "-" "-" "no base_url"; continue; }
  code=$(curl -sS -m 25 -o /tmp/.llmcheck.json -w '%{http_code}' \
          -H "Authorization: Bearer $key" "$base/models" 2>/dev/null)
  verdict="ok"
  if [[ "$code" != 2* ]]; then
    verdict=$(python3 -c 'import json;d=json.load(open("/tmp/.llmcheck.json"));e=d.get("error",d);print(str(e.get("message",e))[:80])' 2>/dev/null || echo "http $code")
  elif (( ! QUICK )); then
    ccode=$(curl -sS -m 45 -o /tmp/.llmcheck2.json -w '%{http_code}' \
      -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
      -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}],\"max_tokens\":4}" \
      "$base/chat/completions" 2>/dev/null)
    [[ "$ccode" == 2* ]] || verdict=$(python3 -c 'import json;d=json.load(open("/tmp/.llmcheck2.json"));e=d.get("error",d);print("completion: "+str(e.get("message",e))[:70])' 2>/dev/null || echo "completion http $ccode")
  fi
  printf '%-28s %-44s %-6s %s\n' "$name" "$base" "$code" "$verdict"
done
rm -f /tmp/.llmcheck.json /tmp/.llmcheck2.json
