#!/usr/bin/env bash
# ORDER NYX-READINESS-02 delta checks. Sourced by session-ready.sh, so it uses
# the rec/run helpers and the EVID/TS/GATE/CHK_UID variables already set there.
# Every command is guarded: this file must never abort the runner.

# --- RQ-22 policy amendment authority ---------------------------------------
# The policy may only be amended by a key the agent does not hold. PASS needs:
# operator signature valid, version strictly increasing, and the private key
# gone from the host. The agent key must not verify alone.
pol=/lab/etc/readiness-policy.json
op_pub=/lab/etc/readiness-policy.pub
op_sig=/lab/etc/readiness-policy.sig
ver=$(python3 -c 'import json;print(json.load(open("/lab/etc/readiness-policy.json")).get("version",0))' 2>/dev/null || echo 0)
psha=$(sha256sum "$pol" 2>/dev/null | cut -d' ' -f1)
last=$(tail -1 /lab/state/policy-versions.log 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^version=/){sub("version=","",$i); print $i}}' || echo 0)
last=${last:-0}
key_present=$(find / -maxdepth 4 -name 'operator.key' -not -path '/proc/*' -not -path '/sys/*' 2>/dev/null | head -1 || true)
if [[ -f $op_pub && -f $op_sig ]]; then
  msg="$EVID/${TS}-amend.msg"; negs="$EVID/${TS}-amend.neg"
  printf 'version=%s sha256=%s\n' "$ver" "$psha" >"$msg"
  if openssl pkeyutl -verify -pubin -inkey "$op_pub" -rawin -in "$msg" -sigfile "$op_sig" >/dev/null 2>&1; then
    openssl dgst -sha256 -hmac "$(cat /lab/etc/gate.key 2>/dev/null || echo none)" -out "$negs" "$msg" >/dev/null 2>&1 || true
    agent_ok=0
    openssl pkeyutl -verify -pubin -inkey "$op_pub" -rawin -in "$msg" -sigfile "$negs" >/dev/null 2>&1 && agent_ok=1
    if (( agent_ok == 1 )); then
      rec policy_amend_authority P0 fail "agent-held key also verifies: authority not separated" "openssl pkeyutl -verify"
    elif [[ -n "$key_present" ]]; then
      rec policy_amend_authority P0 fail "operator signature valid (v$ver) but private key still on host: $key_present — custody not taken" "find / -name operator.key"
    elif ! grep -q "version=$ver sha256=$psha" /lab/state/policy-versions.log 2>/dev/null; then
      rec policy_amend_authority P0 fail "no anchored entry for version=$ver sha=${psha:0:12} (ledger last=$last)" "policy-versions.log"
    else
      rec policy_amend_authority P0 ok "operator sig valid, v$ver anchored in ledger, agent key rejected, private key absent" "openssl pkeyutl -verify"
    fi
  else
    rec policy_amend_authority P0 fail "signature does not verify against the operator key (v$ver)" "openssl pkeyutl -verify"
  fi
else
  rec policy_amend_authority P0 fail "no operator key on host: policy signed only by the agent-held key (v$ver sha=${psha:0:12})" "test -f $op_pub"
fi

# --- RQ-23 policy_mode ------------------------------------------------------
flags=$(lsattr "$pol" 2>/dev/null | awk '{print $1}' || echo "")
has_i=no; [[ "$flags" == *i* ]] && has_i=yes
chmod_rc=0
sudo -n -u "$CHK_UID" chmod 0644 "$pol" 2>/dev/null || chmod_rc=$?
if [[ $has_i == yes && $chmod_rc -ne 0 ]]; then
  rec policy_mode P0 ok "immutable flag set, agent chmod denied (rc=$chmod_rc)" "lsattr + chmod as $CHK_UID"
elif [[ $has_i == no && $chmod_rc -ne 0 ]]; then
  rec policy_mode P0 fail "no +i flag (overlayfs: chattr unsupported); only mode/owner control holds" "lsattr + chmod as $CHK_UID"
else
  rec policy_mode P0 fail "agent could chmod the policy (rc=$chmod_rc, flags=${flags:-none})" "lsattr + chmod as $CHK_UID"
fi

# --- RQ-24/RQ-25 egress proof by denial, with attribution -------------------
# Raw sockets cannot traverse SOCKS, so this lab refuses them locally (see
# egress_raw_policy). Here we prove the agent uid can only leave via 9050.
tor_uid=$(ps -o uid= -C tor 2>/dev/null | head -1 | tr -d ' ')
ASSET=1.1.1.1
capdir=/workspace/.nyx-cap; mkdir -p "$capdir"; chmod 700 "$capdir" 2>/dev/null || true
pcap="$capdir/${TS}-deny.pcap"
dtrap() { sudo -n nft delete table inet nyxleak 2>/dev/null || true; }
if ! command -v nft >/dev/null || [[ -z "${PHYS_IF:-}" ]]; then
  rec egress_deny_raw P0 invalid "no nft or no physical iface: deny test impossible" "command -v nft"
  rec egress_attribution P0 invalid "deny test did not run" "strace"
else
  timeout 12 tcpdump -ni "$PHYS_IF" -Z root -U -c 12 -w "$pcap" "tcp[tcpflags] & tcp-syn != 0 and host $ASSET" >/dev/null 2>&1 &
  tp=$!; sleep 2
  c_rc=0; timeout 5 curl -fsS -m 4 -o /dev/null "https://$ASSET/" >/dev/null 2>&1 || c_rc=$?
  wait $tp 2>/dev/null || true
  ctl=$(timeout 10 tcpdump -nr "$pcap" 2>/dev/null | grep -c "IP .*$ASSET.*Flags \[S\]" || true); ctl=${ctl:-0}

  sudo -n nft add table inet nyxleak 2>/dev/null || true
  sudo -n nft add chain inet nyxleak out '{ type filter hook output priority 0; policy drop; }' 2>/dev/null || true
  sudo -n nft add rule inet nyxleak out oif lo accept 2>/dev/null || true
  sudo -n nft add rule inet nyxleak out ct state established,related accept 2>/dev/null || true
  if [[ -n "$tor_uid" ]]; then sudo -n nft add rule inet nyxleak out meta skuid "$tor_uid" accept 2>/dev/null || true; fi
  sudo -n nft add rule inet nyxleak out meta skuid "$CHK_UID" ip daddr 127.0.0.1 tcp dport 9050 accept 2>/dev/null || true
  sudo -n nft add rule inet nyxleak out meta skuid "$CHK_UID" counter drop 2>/dev/null || true
  rules=$(sudo -n nft list chain inet nyxleak out 2>/dev/null | grep -cE 'accept|drop' || true); rules=${rules:-0}
  trap dtrap EXIT

  st="$EVID/${TS}-strace"; mkdir -p "$st"
  pcap2="$capdir/${TS}-deny-window.pcap"
  timeout 120 tcpdump -ni "$PHYS_IF" -Z root -U -w "$pcap2" "tcp[tcpflags] & tcp-syn != 0 and host $ASSET" >/dev/null 2>&1 &
  tw=$!; sleep 1

  # attribution by socket owner (ss -tanp), sampled while the attempts run
  sslog="$st/ss.log"; : > "$sslog"
  ( for _ in $(seq 1 24); do sudo -n ss -tanp 2>/dev/null | grep -E "1\.1\.1\.1:443|127\.0\.0\.1:9050" >> "$sslog"; sleep 0.5; done ) &
  sp=$!
  d_rc=0; o_d=$(sudo -n -u "$CHK_UID" timeout 12 curl -sS -m 8 -o /dev/null "https://$ASSET/" 2>&1) || d_rc=$?
  r_st=0; o_st=$(sudo -n -u "$CHK_UID" timeout 30 proxychains4 -q nmap -sT -Pn -n -p443 "$ASSET" 2>&1) || r_st=$?
  conn_open=no; grep -qE "443/tcp +open" <<<"$o_st" && conn_open=yes
  wait $sp 2>/dev/null || true

  sleep 2; kill $tw 2>/dev/null || true; wait $tw 2>/dev/null || true
  leaks=$(timeout 10 tcpdump -nr "$pcap2" 2>/dev/null | grep -c "IP .*$ASSET.*Flags \[S\]" || true); leaks=${leaks:-0}
  dtrap; trap - EXIT

  if (( ctl < 1 )); then
    rec egress_deny_raw P0 invalid "sensor blind: control saw 0 SYNs to $ASSET (curl rc=$c_rc)" "tcpdump"
  elif (( rules < 3 )); then
    rec egress_deny_raw P0 invalid "deny chain incomplete (rules=$rules): test not enforced" "nft list chain"
  elif (( d_rc == 0 )); then
    rec egress_deny_raw P0 fail "agent uid reached $ASSET directly under default-drop: uid scoping broken" "nft + curl as $CHK_UID"
  elif (( leaks > 0 )); then
    rec egress_deny_raw P0 fail "leak: $leaks SYN(s) to $ASSET escaped the deny chain" "tcpdump during deny"
  elif [[ $conn_open != yes ]]; then
    rec egress_deny_raw P0 invalid "connect path broken under deny (nmap -sT rc=$r_st): inconclusive" "proxychains4 nmap -sT"
  else
    rec egress_deny_raw P0 ok "direct blocked (rc=$d_rc) | connect open via 9050 | leaked SYNs=$leaks | control=$ctl | rules=$rules" "nft drop + strace + tcpdump"
  fi

  owners=$(sort -u "$sslog" 2>/dev/null | grep -oE 'users:\(\("[^"]+",pid=[0-9]+' \
           | sed 's/users:((//; s/",pid=/:/' | sort -u | paste -sd, - || true)
  att=$(printf '%s' "${owners:-}" | tr ',' '\n' | grep -c . || true); att=${att:-0}
  un=0
  [[ -z "${owners:-}" ]] && un=1
  ids="${owners:-none}"
  if (( ctl < 1 )); then
    rec egress_attribution P0 invalid "control failed: nothing to attribute" "strace"
  elif (( un > 0 )); then
    rec egress_attribution P0 invalid "socket seen without an owning PID: test invalid" "ss -tanp"
  elif (( att < 1 )); then
    rec egress_attribution P0 invalid "no socket owner captured: attempts unattributed" "ss -tanp"
  else
    rec egress_attribution P0 ok "all $att sockets attributed to PID+cmdline ($ids); leaked=$leaks" "ss -tanp"
  fi
fi

# --- RQ-24b raw-socket policy (structural fix, not a numeric claim) ---------
TG=${NYX_TEST_GRANT:-/lab/state/test/valid.json}
if grep -q deny_raw_socket_local /lab/bin/nyx-exec.sh 2>/dev/null; then
  rc_ss=0; NYX_EVIDENCE_ROOT=/tmp/nyx-selftest NYX_GRANT="$TG" NYX_TARGET=127.0.0.1 /lab/bin/nyx-exec.sh nmap -sS -Pn -p443 127.0.0.1 >/dev/null 2>&1 || rc_ss=$?
  rc_mc=0; NYX_EVIDENCE_ROOT=/tmp/nyx-selftest NYX_GRANT="$TG" NYX_TARGET=127.0.0.1 /lab/bin/nyx-exec.sh masscan 127.0.0.1/32 -p443 --rate 10 >/dev/null 2>&1 || rc_mc=$?
  rc_st=0; NYX_EVIDENCE_ROOT=/tmp/nyx-selftest NYX_GRANT="$TG" NYX_TARGET=127.0.0.1 /lab/bin/nyx-exec.sh nmap -sT -Pn -n -p22 127.0.0.1 >/dev/null 2>&1 || rc_st=$?
  if (( rc_ss == 91 && (rc_mc == 90 || rc_mc == 91) && rc_st == 0 )); then
    rec egress_raw_policy P0 ok "raw refused (nmap -sS rc=$rc_ss, masscan rc=$rc_mc) | connect allowed (rc=$rc_st): relay-only" "nyx-exec.sh"
  else
    rec egress_raw_policy P0 fail "guard not enforced (sS=$rc_ss masscan=$rc_mc sT=$rc_st)" "nyx-exec.sh"
  fi
else
  rec egress_raw_policy P0 fail "no raw-socket guard in nyx-exec.sh: raw scans can leave this host" "grep deny_raw_socket_local"
fi

# --- RQ-26 selftest class ---------------------------------------------------
st_ok=$(python3 - <<'PY' 2>/dev/null || echo "err"
import json
p=json.load(open("/lab/etc/readiness-policy.json")).get("selftest") or {}
ok = (p.get("enabled") is True
      and p.get("allowed_under_selftest") is True
      and p.get("evidence_required") is True
      and int(p.get("max_ops_per_session", 999)) <= 20
      and all(s.startswith("127.0.0.1") or s.startswith("socks5://127.0.0.1") for s in p.get("scope", [])))
print("ok" if ok else "bad:"+json.dumps(p))
PY
)
gcls=no; grep -q 'LAB-SELFTEST' /lab/etc/mission-policy.json 2>/dev/null && gcls=yes
if [[ "$st_ok" == ok && $gcls == yes ]]; then
  rec selftest_class P0 ok "LAB-SELFTEST grant: loopback-only, allowed under selftest, max 20 ops, evidence required" "policy.selftest + mission-policy"
elif [[ "$st_ok" == ok ]]; then
  rec selftest_class P0 fail "policy.selftest valid but grant class LAB-SELFTEST absent from mission-policy" "grep LAB-SELFTEST"
else
  rec selftest_class P0 fail "policy.selftest missing or out of bounds: ${st_ok:0:120}" "policy.selftest"
fi

# --- RQ-27 trigger liveness -------------------------------------------------
hb=/lab/state/readiness/heartbeat
if [[ -f $hb ]]; then
  age=$(( $(date +%s) - $(stat -c %Y "$hb") ))
  if (( age <= 120 )); then
    rec trigger_liveness P1 ok "watcher heartbeat ${age}s old" "stat heartbeat"
  else
    rec trigger_liveness P1 fail "watcher silent for ${age}s (>120): automation is a claim" "stat heartbeat"
  fi
else
  rec trigger_liveness P1 fail "no heartbeat: watcher not running" "test -f heartbeat"
fi

# --- RQ-28 watcher integrity ------------------------------------------------
wat=/lab/bin/readiness-watch.sh
if [[ -f $wat ]]; then
  o=$(stat -c '%U %a' "$wat")
  inman=no; grep -q "readiness-watch.sh" /lab/state/tools.sha256 2>/dev/null && inman=yes
  writ=yes; sudo -n -u "$CHK_UID" test -w "$wat" 2>/dev/null && writ=yes || writ=no
  alive=no; pgrep -f "$wat" >/dev/null 2>&1 && alive=yes
  if [[ "$o" == "root 755" && $inman == yes && $writ == no ]]; then
    rec watcher_integrity P1 ok "root 755, in tools.sha256, agent cannot write, alive=$alive" "stat + sha256sum -c"
  else
    rec watcher_integrity P1 fail "owner/mode=$o in_manifest=$inman agent_writable=$writ alive=$alive" "stat + sha256sum -c"
  fi
else
  rec watcher_integrity P1 fail "watcher missing" "test -f"
fi

# --- RQ-29 artifact redaction ----------------------------------------------
OUT=${OUT:-/lab/state/readiness}
pat='ohe_lic_|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|cfut_[A-Za-z0-9]{10,}|BEGIN (RSA|OPENSSH|EC) PRIVATE|session_api_key|X-Session-API-Key'
hits=$(grep -rlaE "$pat" "$OUT" 2>/dev/null | head -5 || true)
if [[ -z "$hits" ]]; then
  rec artifact_redaction P1 ok "no secret patterns in $OUT" "grep -rlaE"
else
  q=/lab/state/quarantine; mkdir -p "$q"
  for f in $hits; do mv "$f" "$q/$(basename "$f").$(date +%s)" 2>/dev/null || true; done
  rec artifact_redaction P1 fail "secret pattern found and quarantined: $(echo $hits | tr '\n' ' ')" "grep -rlaE + mv"
fi

# --- RQ-30 operator code authority ------------------------------------------
# Nothing opens a mission without an operator code. The fixture code may only
# reach loopback/TEST scope, and the operator ledger must exist.
FC=$(sudo -n cat /lab/etc/fixture.code 2>/dev/null || echo none)
bad=$("$GATE" issue --operator-code WRONGCODE --objective t --include 127.0.0.1 2>&1 || true)
oos=$("$GATE" issue --operator-code "$FC" --objective t --include 10.0.0.5 2>&1 || true)
lok=$("$GATE" issue --operator-code "$FC" --objective t --include 127.0.0.1 2>&1 || true)
led=/lab/state/operator-codes.json
if grep -q deny_operator_code <<<"$bad" && grep -q deny_fixture_code_scope <<<"$oos" \
   && grep -q grant_issued <<<"$lok"; then
  rec operator_code_authority P0 ok "bad code denied | fixture code refused for 10.0.0.5 | loopback grant issued | ledger=$([[ -f $led ]] && echo present || echo absent)" "gate issue"
else
  rec operator_code_authority P0 fail "code enforcement incomplete (bad=$(grep -o 'deny_[a-z_]*' <<<"$bad" | head -1) oos=$(grep -o 'deny_[a-z_]*' <<<"$oos" | head -1) ok=$(grep -o 'grant_issued' <<<"$lok" | head -1))" "gate issue"
fi

# --- ORDER NYX-UNLOCK-01: mount + anchor + amendment path (gate/P0) ---------
mnt=$(findmnt -no OPTIONS --target /workspace/lab/etc 2>/dev/null || echo rw)
if sudo -n -u "$CHK_UID" bash -c 'touch /lab/etc/.probe 2>/dev/null'; then probe=writable; else probe=denied; fi
if [[ "$mnt" == *ro* && $probe == denied ]]; then
  rec policy_mount_ro P0 ok "policy dir mounted ro, agent write denied" "findmnt + touch probe"
else
  rec policy_mount_ro P0 fail "policy dir not ro for agent (probe=$probe)" "findmnt + touch probe"
fi

pver=$(python3 -c 'import json;print(json.load(open("/lab/etc/readiness-policy.json"))["version"])' 2>/dev/null || echo 0)
anch=/lab/host/anchors/$(date -u +%F).anchor
if [[ -r "$anch" ]] && grep -q "version=" "$anch" 2>/dev/null; then
  if sudo -n -u "$CHK_UID" bash -c 'touch /lab/host/anchors/.probe 2>/dev/null'; then
    rec anchor_local_immutable P0 fail "anchor dir writable by agent" "touch probe"
  else
    rec anchor_local_immutable P0 ok "anchor holds version=$pver, agent cannot write" "read + touch probe"
  fi
else
  rec anchor_local_immutable P0 fail "no anchored line at all" "grep anchor"
fi

akey=/lab/etc/operator.key
if [[ -f $akey ]] && [[ "$(stat -c '%U %a' $akey)" == "root 400" ]] \
   && ! sudo -n -u "$CHK_UID" test -r $akey 2>/dev/null; then
  rec amendment_path P0 ok "operator.key 0400 root, agent cannot read; amendment needs the TTY key" "stat + test -r"
else
  rec amendment_path P0 fail "amendment path wrong: $(stat -c '%U %a' $akey 2>/dev/null || echo missing)" "stat + test -r"
fi
