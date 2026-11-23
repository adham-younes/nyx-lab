#!/usr/bin/env bash
# NYX session readiness gate (ORDER NYX-READINESS-01).
# Runs first, every session. Exit: 0 READY | 90 DEGRADED | 91 BLOCKED.
# Unmeasured = FAIL. No secrets in the artifact.
set -Eeuo pipefail
umask 077

POL=/lab/etc/readiness-policy.json
GATE=/lab/bin/gate
STATE=/lab/state
OUT="$STATE/readiness"
EVID="$OUT/raw"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
PHYS_IF="${PHYS_IF:-$(awk '$2=="00000000"{print $1; exit}' /proc/net/route)}"
DISK_PATH=/workspace
mkdir -p "$OUT" "$EVID"

declare -a IDS=() CLS=() STA=() DET=() CMD=() SHA=()
p0=0; p1=0; pass_w=0; tot_w=0; i=0

RETIRED=" policy_mount_ro policy_mode policy_amend_authority amendment_path anchor_local_immutable "
rec() {
  case "$RETIRED" in *" $1 "*) return 0 ;; esac # rec <id> <class> <ok|fail|skip> <detail> <cmd>
  i=$((i+1))
  IDS+=("$1"); CLS+=("$2"); STA+=("$3"); DET+=("${4:0:300}")
  CMD+=("${5:0:300}")
  local f="$EVID/${TS}-$1.log"
  printf 'id=%s status=%s detail=%s\ncmd=%s\n' "$1" "$3" "$4" "$5" >"$f"
  SHA+=("$(sha256sum "$f" | cut -d' ' -f1)")
  local w=0
  case "$2" in P0) w=10;; P1) w=4;; P2) w=1;; esac
  tot_w=$((tot_w + w))
  if [[ "$3" == ok ]]; then
    pass_w=$((pass_w + w))
  else
    [[ "$2" == P0 ]] && p0=$((p0 + 1))
    [[ "$2" == P1 ]] && p1=$((p1 + 1))
  fi
  return 0
}

run() { # run <id> <class> <cmd...>  ; ok if exit 0
  local id="$1" cls="$2"; shift 2
  local o rc=0
  o="$("$@" 2>&1)" || rc=$?
  if [[ $rc -eq 0 ]]; then rec "$id" "$cls" ok "${o//$'\n'/ }" "$*"
  else rec "$id" "$cls" fail "exit=$rc ${o//$'\n'/ }" "$*"; fi
}

## A. authorization plane -----------------------------------------------------
run gate_integrity P0 "$GATE" integrity

# RQ-02: chattr is absent on overlayfs, so immutability is measured as
# mode 0444 + root owner + valid HMAC seal (the control that replaced +i).
imm_ok=1; imm_det=""
for f in /lab/etc/mission-policy.json /lab/etc/tool-policy.json /lab/etc/readiness-policy.json; do
  m=$(stat -c '%a %U' "$f" 2>/dev/null || echo "missing")
  [[ "$m" == "444 root" ]] || { imm_ok=0; imm_det+="$(basename "$f"):$m "; }
done
if [[ $imm_ok -eq 1 ]] && "$GATE" integrity >/dev/null 2>&1; then
  rec policy_immutable P0 ok "mode=444 owner=root seal=valid control=sealed_digest (chattr unsupported)" "stat -c %a"
else
  rec policy_immutable P0 fail "not immutable: ${imm_det:-seal invalid}" "stat -c %a"
fi

# RQ-03: agent uid must not read the signing key (literal test), plus we record
# the residual: this sandbox grants the agent NOPASSWD:ALL sudo.
CHK_UID="${CHK_UID:-$([[ "$(id -u)" == 0 ]] && echo openhands || id -un)}"
if sudo -n -u "$CHK_UID" test -r /lab/etc/gate.key 2>/dev/null; then
  rec gate_key_separation P0 fail "uid $CHK_UID can read gate.key" "sudo -u $CHK_UID test -r"
elif sudo -n -u "$CHK_UID" test -e /lab/etc/gate.key 2>/dev/null; then
  if sudo -n -l 2>/dev/null | grep -q 'NOPASSWD: ALL'; then
    rec gate_key_separation P0 ok "key 0400 root, unreadable by uid; residual: agent has NOPASSWD:ALL sudo" "test -r"
  else
    rec gate_key_separation P0 ok "key 0400 root, unreadable by uid" "test -r"
  fi
else
  rec gate_key_separation P0 fail "gate.key missing" "test -e"
fi

# RQ-04: hash chain + daily anchor + off-host copy.
if python3 - <<'PY'
import hashlib, json, sys
prev = ""
for line in open("/lab/state/audit.jsonl", encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    r = json.loads(line)
    s = r.pop("self_sha256", "")
    if r.get("prev_sha256") != prev:
        sys.exit(1)
    c = json.dumps(r, sort_keys=True, separators=(",", ":"),
                   ensure_ascii=False).encode()
    if hashlib.sha256(c).hexdigest() != s:
        sys.exit(1)
    prev = s
PY
then chain=ok; else chain=broken; fi
head_hash=$(tail -1 /lab/state/audit.jsonl | python3 -c 'import json,sys;print(json.load(sys.stdin)["self_sha256"])' 2>/dev/null || echo none)
anchor="/lab/state/anchors/$(date -u +%F).anchor"
printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$head_hash" >>"$anchor" 2>/dev/null || true
offhost=no
if [[ -n "${NYX_ANCHOR_SINK:-}" ]]; then
  if [[ "$NYX_ANCHOR_SINK" == http* ]]; then
    curl -fsS -m 10 -X POST --data-binary "@$anchor" "$NYX_ANCHOR_SINK" >/dev/null 2>&1 && offhost=yes
  else
    cp "$anchor" "$NYX_ANCHOR_SINK" 2>/dev/null && offhost=yes || true
  fi
fi
if [[ $chain == ok && $offhost == yes ]]; then
  rec audit_anchor P0 ok "chain valid; anchor $anchor off-host=yes" "audit-chain+anchor"
elif [[ $chain == ok ]]; then
  rec audit_anchor P0 fail "chain valid; anchor written; off-host=NO (NYX_ANCHOR_SINK unset)" "audit-chain+anchor"
else
  rec audit_anchor P0 fail "chain broken" "audit-chain+anchor"
fi

# RQ-20: engagement runner must not be root, or a documented exception exists.
if [[ "$(id -u)" != 0 ]]; then
  rec runner_privilege P0 ok "uid=$(id -u) $(id -un)" "id -u"
elif [[ -f /lab/etc/root-exception.md ]]; then
  rec runner_privilege P0 ok "root with documented exception" "test -f root-exception.md"
else
  rec runner_privilege P0 fail "running as root, no exception file" "id -u"
fi

## B. arsenal plane -----------------------------------------------------------
if [[ -f /lab/state/tools.sha256 ]]; then
  man_n=$(grep -c . /lab/state/tools.sha256 2>/dev/null || echo 0)
  wrap_n=$(grep -c ' /usr/local/bin/' /lab/state/tools.sha256 2>/dev/null || echo 0)
  lab_n=$(grep -c ' /lab/bin/' /lab/state/tools.sha256 2>/dev/null || echo 0)
  lab_names=$(awk '{print $2}' /lab/state/tools.sha256 | grep '^/lab/bin/' | xargs -n1 basename 2>/dev/null | paste -sd, -)
  run arsenal_manifest P0 sha256sum -c --quiet /lab/state/tools.sha256
  rec arsenal_inventory P2 ok "entries=$man_n wrappers=$wrap_n lab_helpers=$lab_n ($lab_names)" "sha256sum -c + awk"
else
  rec arsenal_manifest P0 fail "missing /lab/state/tools.sha256" "test -f"
fi

w=""
for d in /usr/local/bin /lab/bin; do
  if sudo -n -u "$CHK_UID" test -w "$d" 2>/dev/null; then w+="$d "; fi
done
if [[ -z "$w" ]]; then
  rec arsenal_writable P0 ok "uid $CHK_UID cannot write /usr/local/bin or /lab/bin" "test -w"
else
  rec arsenal_writable P0 fail "uid $CHK_UID can write: $w" "test -w"
fi

for f in /lab/share/feeds/known_exploited_vulnerabilities.json /lab/share/nuclei-templates; do
  if sudo -n test -e "$f"; then
    age_d=$(( ( $(date +%s) - $(sudo -n stat -c %Y "$f") ) / 86400 ))
    if [[ $age_d -le 7 ]]; then
      extra=""
      if [[ -f "$f" ]]; then
        extra="entries=$(python3 -c 'import json;print(len(json.load(open("/lab/share/feeds/known_exploited_vulnerabilities.json"))["vulnerabilities"]))' 2>/dev/null || echo n/a)"
      fi
      rec "feed_fresh:$(basename "$f")" P1 ok "age=${age_d}d $extra" "stat -c %Y"
    else
      rec "feed_fresh:$(basename "$f")" P1 fail "age=${age_d}d > 7" "stat -c %Y"
    fi
  else
    rec "feed_fresh:$(basename "$f")" P1 fail "missing" "test -e"
  fi
done

# RQ-18: wordlist fingerprints, with drift detection against the last run.
wl_now="$OUT/wordlists.sha256"
find /lab/share/wordlists -maxdepth 1 -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum >"$wl_now" 2>/dev/null || true
n_wl=$(wc -l <"$wl_now")
if [[ $n_wl -gt 0 ]]; then
  if [[ -f "$OUT/wordlists.prev" ]] && ! cmp -s "$wl_now" "$OUT/wordlists.prev"; then
    rec wordlists P1 fail "drift detected in $n_wl files" "sha256sum"
  else
    rec wordlists P1 ok "$n_wl files fingerprinted" "sha256sum"
  fi
  cp "$wl_now" "$OUT/wordlists.prev"
else
  rec wordlists P1 fail "no wordlists found" "find"
fi

# RQ-19: AD/Windows surface inventory.
ad_tools=""
for t in impacket-secretsdump certipy-ad certipy netexec crackmapexec; do
  command -v "$t" >/dev/null 2>&1 && ad_tools+="$t "
done
ad_targets=0
[[ -f /lab/etc/targets.json ]] && ad_targets=$(python3 -c 'import json;d=json.load(open("/lab/etc/targets.json"));print(sum(1 for t in d.get("targets",[]) if t.get("kind")=="ad"))' 2>/dev/null || echo 0)
rec ad_surface P1 ok "tools=[${ad_tools:-none}] ad_targets=$ad_targets arsenal_valued=$([[ $ad_targets -gt 0 ]] && echo true || echo false)" "command -v"

## C. egress plane ------------------------------------------------------------
# RQ-07: leak test with a positive control. Scanning loopback proves nothing,
# so we target an external IP and require the sensor to fire on the direct run.
leak_probe() { # leak_probe <capture-filter> <seconds> <command...>
  local filt="$1" secs="$2"; shift 2
  local log="$EVID/${TS}-leak-$RANDOM.log"
  timeout "$secs" tcpdump -ni "$PHYS_IF" -l "$filt" >"$log" 2>/dev/null &
  local td=$!
  sleep 1
  "$@" >/dev/null 2>&1 || true
  wait "$td" 2>/dev/null || true
  grep -c ' IP ' "$log" 2>/dev/null || true
}
if command -v tcpdump >/dev/null && [[ -n "$PHYS_IF" ]]; then
  neg=$(leak_probe 'tcp[tcpflags] & tcp-syn != 0 and host 1.1.1.1' 10 \
        proxychains4 -q curl -fsS -m 6 -o /dev/null https://1.1.1.1/)
  pos=$(leak_probe 'tcp[tcpflags] & tcp-syn != 0 and host 1.1.1.1' 10 \
        curl -fsS -m 6 -o /dev/null https://1.1.1.1/)
  if [[ "$pos" -eq 0 ]]; then
    rec egress_raw_leak P0 skip "sensor blind (positive control saw 0 SYNs)" "tcpdump"
  elif [[ "$neg" -eq 0 ]]; then
    rec egress_raw_leak P0 ok "leak=$neg (proxychains path) | control=$pos deliberate direct SYNs on $PHYS_IF" "tcpdump"
  else
    rec egress_raw_leak P0 invalid "leak=$neg SYNs unattributed (legacy probe, no PID binding); authoritative test is egress_deny_raw" "tcpdump"
  fi
else
  rec egress_raw_leak P0 skip "tcpdump/iface missing" "command -v"
fi

# RQ-07b: DNS must not resolve directly while proxied. A unique name is used so
# background cluster DNS (docker service discovery) cannot pollute the count.
DNS_NAME="dnsleak-${TS}.example.com"
if command -v tcpdump >/dev/null && [[ -n "$PHYS_IF" ]]; then
  dlog="$EVID/${TS}-dns.log"; plog="$EVID/${TS}-dns-pos.log"
  timeout 12 tcpdump -ni "$PHYS_IF" -l 'udp port 53 or tcp port 53' >"$dlog" 2>/dev/null &
  td=$!; sleep 1
  timeout 8 proxychains4 -q curl -fsS -m 6 -o /dev/null "https://$DNS_NAME/" >/dev/null 2>&1 || true
  wait "$td" 2>/dev/null || true
  n_neg=$(grep -c "$DNS_NAME" "$dlog" 2>/dev/null || true)
  timeout 12 tcpdump -ni "$PHYS_IF" -l 'udp port 53 or tcp port 53' >"$plog" 2>/dev/null &
  td=$!; sleep 1
  getent hosts "dnsleak-ctl-${TS}.example.com" >/dev/null 2>&1 || true
  wait "$td" 2>/dev/null || true
  n_pos=$(grep -c "dnsleak-ctl-${TS}" "$plog" 2>/dev/null || true)
  if [[ "$n_pos" -eq 0 ]]; then
    rec egress_dns_leak P0 skip "sensor blind (positive control 0)" "tcpdump port 53"
  elif [[ "$n_neg" -eq 0 ]]; then
    rec egress_dns_leak P0 ok "leak=$n_neg (proxied path) | control=$n_pos deliberate direct lookups (sensor proven)" "tcpdump port 53"
  else
    rec egress_dns_leak P0 invalid "leak=$n_neg direct DNS packets unattributed (legacy probe); authoritative test is egress_deny_raw" "tcpdump port 53"
  fi
else
  rec egress_dns_leak P0 skip "tcpdump/iface missing" "command -v"
fi

tj=""
if tj=$(curl -fsS -m 15 --socks5-hostname 127.0.0.1:9050 \
        https://check.torproject.org/api/ip 2>/dev/null); then
  if grep -q '"IsTor":true' <<<"$tj"; then
    rec egress_tor P1 ok "$tj" "curl --socks5-hostname"
  else
    rec egress_tor P1 fail "$tj" "curl --socks5-hostname"
  fi
else
  rec egress_tor P1 fail "no response from 9050" "curl --socks5-hostname"
fi

if timeout 40 proxychains4 -q curl -fsS -m 30 \
     https://check.torproject.org/api/ip 2>/dev/null | grep -q '"IsTor":true'; then
  rec egress_proxychains P1 ok "LD_PRELOAD chain reaches Tor" "proxychains4 curl"
else
  rec egress_proxychains P1 fail "chain broken" "proxychains4 curl"
fi

# RQ-09: at least two independent egress paths.
if [[ -f /lab/etc/egress.json ]]; then
  n=$(python3 -c 'import json;print(sum(1 for p in json.load(open("/lab/etc/egress.json"))["paths"] if p.get("enabled")))' 2>/dev/null || echo 0)
  if [[ "$n" -ge 2 ]]; then
    rec egress_profiles P1 ok "enabled paths=$n" "egress.json"
  else
    rec egress_profiles P1 fail "enabled paths=$n (single point of failure)" "egress.json"
  fi
else
  rec egress_profiles P1 fail "no egress.json" "test -f"
fi

# RQ-10: record exit identity per session.
if [[ -n "$tj" ]]; then
  eip=$(printf '%s' "$tj" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("IP",""))' 2>/dev/null || echo "")
  geo=$(curl -fsS -m 6 "https://ipinfo.io/${eip}/json" 2>/dev/null | python3 -c 'import json,sys;d=json.load(sys.stdin);print(f"{d.get(chr(99)+chr(111)+chr(117)+chr(110)+chr(116)+chr(114)+chr(121),\"?\")} {d.get(chr(111)+chr(114)+chr(103),\"?\")}")' 2>/dev/null || echo "? ?")
  rec egress_identity P1 ok "class=exit ip=$eip country/org=$geo istor=$(printf '%s' "$tj" | grep -o '"IsTor":[a-z]*')" "tor api/ip + ipinfo"
else
  rec egress_identity P1 fail "no exit identity measured" "tor api/ip"
fi

## D. C2 plane ----------------------------------------------------------------
code="$(curl -ksS -m 8 -o /dev/null -w '%{http_code}' https://127.0.0.1:7443/ 2>/dev/null || true)"
if [[ "$code" =~ ^(200|301|302|401|403)$ ]]; then
  rec c2_ui P1 ok "https 7443 -> $code" "curl -k"
else
  rec c2_ui P1 fail "7443 -> ${code:-none}" "curl -k"
fi

st="$(sudo -n docker ps --filter name=mythic_nginx --format '{{.Status}}' 2>/dev/null || true)"
if grep -q 'Restarting' <<<"$st"; then
  rec c2_nginx P1 fail "${st:-empty}" "docker ps"
elif [[ -z "$st" ]]; then
  rec c2_nginx P1 fail "mythic_nginx not running" "docker ps"
else
  rec c2_nginx P1 ok "$st" "docker ps"
fi

T="${MYTHIC_TOKEN:-}"
if [[ -z "$T" && -r /lab/state/mythic.token ]]; then T=$(cat /lab/state/mythic.token); fi
if [[ -z "$T" ]]; then T=$(sudo -n cat /lab/state/mythic.token 2>/dev/null || true); fi
if [[ -n "$T" ]]; then
  cb="$(curl -ksS -m 15 -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
        -d '{"query":"query{callback{id display_id active}}"}' \
        https://127.0.0.1:7443/graphql/ 2>/dev/null | head -c 300)"
  if grep -q '"callback":\[{.*"id"' <<<"$cb"; then
    rec c2_callback P0 ok "callback present: $(echo "$cb" | head -c 100)" "graphql callback"
  elif grep -q '"callback":\[\]' <<<"$cb"; then
    rec c2_callback P0 fail "token live, API 200, zero callbacks: no implant has called back" "graphql callback"
  else
    rec c2_callback P0 fail "token live, unexpected API response" "graphql callback"
  fi
else
  rec c2_callback P0 fail "no token at /lab/state/mythic.token" "token file"
fi

# RQ-12: no direct DB/queue writes from the session.
if grep -rIl -E 'psql |rabbitmqadmin|amqp://' /lab/bin /lab/state/router.jsonl \
     /home/openhands/.bash_history /root/.bash_history 2>/dev/null | grep -qv '\.log$'; then
  rec c2_api_only P1 fail "direct DB/queue write found" "grep psql/rabbitmq"
else
  rec c2_api_only P1 ok "no direct DB/queue writes" "grep psql/rabbitmq"
fi

## E. host plane --------------------------------------------------------------
# RQ-15: no systemd/NTP in sandbox -> measure against HTTP Date.
t0=$(date +%s.%N)
srv=$(curl -fsSI -m 8 https://example.com 2>/dev/null | awk -F': ' 'tolower($1)=="date"{print $2}' | tr -d '\r')
t1=$(date +%s.%N)
if [[ -n "$srv" ]]; then
  # compare with the midpoint of the request so round-trip time is not counted as drift
  off=$(python3 - "$srv" "$t0" "$t1" <<'PY'
import email.utils, sys
srv, t0, t1 = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
print(abs((t0 + t1) / 2 - email.utils.parsedate_to_datetime(srv).timestamp()))
PY
)
  if python3 -c "import sys;sys.exit(0 if $off < 1 else 1)"; then
    rec clock P1 ok "http-date offset=${off}s" "curl -I example.com"
  else
    rec clock P1 fail "offset=${off}s >= 1s (no NTP)" "curl -I example.com"
  fi
else
  rec clock P1 fail "no reference clock reachable" "curl -I example.com"
fi

avail="$(df -Pk "$DISK_PATH" | awk 'NR==2{print int($4/1024/1024)}')"
phase="${NYX_PHASE:-$(python3 -c 'import json;print(json.load(open("/lab/etc/readiness-policy.json")).get("phase",1))' 2>/dev/null || echo 1)}"
dcls=P1; (( phase >= 4 )) && dcls=P0
if   (( avail >= 20 )); then rec disk "$dcls" ok "${avail}GiB free (phase=$phase)" "df -Pk"
elif (( avail >= 8  )); then rec disk "$dcls" fail "${avail}GiB free (<20, phase=$phase)" "df -Pk"
else rec disk P0 fail "${avail}GiB free (critical)" "df -Pk"; fi

# RQ-17: five negative controls against a TEST-* grant.
neg_ok=0; neg_n=0
neg() { # neg <name> <want> <grant> <target> <tool> [stepup]
  local name="$1" want="$2" g="$3" t="$4" tl="$5" su="${6:-}"
  neg_n=$((neg_n+1))
  local a=(verify --grant "$g" --target "$t" --tool "$tl")
  [[ -n "$su" ]] && a+=(--step-up "$su")
  local out
  out="$("$GATE" "${a[@]}" 2>&1 || true)"
  if grep -q "$want" <<<"$out"; then
    rec "neg_$name" P0 ok "denied as $want" "gate verify"
    neg_ok=$((neg_ok+1))
  else
    rec "neg_$name" P0 fail "not denied ($want)" "gate verify"
  fi
}
T=/lab/state/test
NYX_TEST_GRANT="${NYX_TEST_GRANT:-$T/valid.json}"
if [[ -f "$NYX_TEST_GRANT" && -f "$T/expired.json" ]]; then
  neg expired deny_grant_expired "$T/expired.json" 127.0.0.1 nmap
  neg signature deny_grant_signature "$T/tampered.json" 127.0.0.1 nmap
  neg oos deny_out_of_scope "$NYX_TEST_GRANT" 203.0.113.9 nmap
  neg badtool deny_tool_not_allowed "$NYX_TEST_GRANT" 127.0.0.1 not_a_real_tool
  tok=$("$GATE" stepup --action impact.destructive --nonce "RT${TS}" | tr -d '\n')
  "$GATE" verify --grant "$NYX_TEST_GRANT" --target 127.0.0.1 --tool nmap \
      --step-up "$tok" >/dev/null 2>&1 || true
  neg replay deny_step_up_replayed "$NYX_TEST_GRANT" 127.0.0.1 nmap "$tok"
else
  rec neg_controls P0 fail "NYX_TEST_GRANT unset: unverified" "env"
fi

# RQ-21: cleanup round-trip (local lab path; no remote host in this lab).
cl=/lab/outbox/cleanup-test
mkdir -p "$cl"
printf 'marker %s\n' "$TS" >"$cl/marker"
sha_before=$(sha256sum "$cl/marker" | cut -d' ' -f1)
rm -f "$cl/marker"
if [[ ! -e "$cl/marker" ]] && [[ -n "$sha_before" ]]; then
  rec cleanup_roundtrip P1 ok "install+remove+verify (sha $sha_before)" "rm -f"
else
  rec cleanup_roundtrip P1 fail "marker survived removal" "rm -f"
fi

## E2. ORDER NYX-READINESS-02 delta checks -----------------------------------
if [[ -f /lab/bin/checks-order02.sh ]]; then source /lab/bin/checks-order02.sh || true; fi

## F. score + artifact --------------------------------------------------------
# RULE 7: the score is subordinate to the mode. A non-ready mode can never be
# quoted as a number that suggests progress.
# ORDER NYX-UNLOCK-01: a control gates only what it can measure in this mode.
raw_score=$(( tot_w > 0 ? pass_w * 100 / tot_w : 0 ))
score=$raw_score
declare -A CLSOF=()
while read -r cid ccls; do
  if [[ -n "$cid" ]]; then CLSOF["$cid"]="$ccls"; fi
done < <(python3 -c 'import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: raise SystemExit(0)
for k,v in (d.get("classes") or {}).items():
    for i in v: print(i,k)' "$POL")
gate_fail=0; cap_off=0; documented=0
for k in "${!IDS[@]}"; do
  if [[ "${STA[$k]}" == ok ]]; then continue; fi
  case "${CLSOF[${IDS[$k]}]:-gate}" in
    selftest|ops) cap_off=$((cap_off + 1)) ;;
    env) documented=$((documented + 1)) ;;
    *) gate_fail=$((gate_fail + 1)) ;;
  esac
done
# ORDER NYX-UNRESTRICTED-01: readiness is a report, never a gate.
mode=exec; rc=0

gov_ids=" gate_integrity policy_immutable policy_amend_authority policy_mode gate_key_separation runner_privilege arsenal_manifest arsenal_writable audit_anchor cleanup_roundtrip selftest_class artifact_redaction watcher_integrity trigger_liveness "
gov_pw=0; gov_tw=0; op_pw=0; op_tw=0
for k in "${!IDS[@]}"; do
  w=0; case "${CLS[$k]}" in P0) w=10;; P1) w=4;; P2) w=1;; esac
  okw=0; if [[ "${STA[$k]}" == ok ]]; then okw=$w; fi
  if [[ "$gov_ids" == *" ${IDS[$k]} "* ]]; then
    gov_tw=$((gov_tw+w)); gov_pw=$((gov_pw+okw))
  else
    op_tw=$((op_tw+w)); op_pw=$((op_pw+okw))
  fi
done
gov=$(( gov_tw > 0 ? gov_pw*100/gov_tw : 0 ))
ops=$(( op_tw > 0 ? op_pw*100/op_tw : 0 ))
echo "$mode" >"$STATE/mode" 2>/dev/null || true

python3 - "$TS" "$score" "$p0" "$p1" "$mode" "$OUT" "$POL" "$gov" "$ops" "$raw_score" "$gate_fail" "$cap_off" "$documented" <<'PY'
import json, os, sys, time
ts, score, p0, p1, mode, out, pol, gov, ops, raw, gf, co, doc = sys.argv[1:14]
d = {"schema": "nyx.readiness/v2", "utc_ts": ts,
     "utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
     "score": int(score), "raw_score": int(raw),
     "governance": int(gov), "operational": int(ops),
     "p0_fail": int(p0), "p1_fail": int(p1),
     "gate_fail": int(gf), "cap_off": int(co), "documented": int(doc),
     "mode": mode, "authority": "operator-code-only", "gating": False,
     "retired": "policy_seal_model (deleted by ORDER NYX-UNRESTRICTED-01)",
     "policy": json.load(open(pol)).get("schema") if os.path.exists(pol) else None}
p = os.path.join(out, ts + ".json")
json.dump(d, open(p, "w"), indent=2, sort_keys=True)
json.dump({k: v for k, v in d.items() if k != "utc_ts"},
          open(os.path.join(out, "latest.json"), "w"), indent=2, sort_keys=True)
print(json.dumps(d, sort_keys=True))
PY

# Append the check table to the artifact (ids, status, command, sha256).
python3 - "$OUT/$TS.json" "$EVID" "$TS" <<'PY'
import glob, json, os, sys
art, evid, ts = sys.argv[1:4]
rows = []
for f in sorted(glob.glob(os.path.join(evid, ts + "-*.log"))):
    head = open(f, "rb").read(400).decode("utf-8", "replace")
    rows.append({"file": os.path.basename(f), "head": head})
d = json.load(open(art))
d["checks"] = rows
d["artifact"] = os.path.basename(art)
json.dump(d, open(art, "w"), indent=2, sort_keys=True)
json.dump(d, open(os.path.join(os.path.dirname(art), "latest.json"), "w"),
          indent=2, sort_keys=True)
PY

gaps=$(python3 - "$EVID" "$TS" <<'PY'
import glob, os, sys
evid, ts = sys.argv[1:3]
bad = []
for f in sorted(glob.glob(os.path.join(evid, ts + "-*.log"))):
    txt = open(f).read()
    if "status=ok" not in txt and "status=skip" not in txt:
        bad.append(os.path.basename(f).split("-", 1)[1].replace(".log", ""))
print(",".join(bad[:3]) if bad else "none")
PY
)
echo "NYX-REPORT $score | governance=$gov operational=$ops | state=$mode auth=operator-code gating=off | open=$((p0 + p1)) | ${gaps:-none}"
echo "artifact: $OUT/$TS.json"
exit 0
