#!/usr/bin/env python3
"""NYX mission gate v3.0 (lab build)

Authorization is computed here. Ownership is warranted by the operator and
never re-litigated by the agent. Append-only hash-chained audit.

Deviations from the v3.0 spec, documented in migration-notes.md:
  * `seal` + signed policy digests replace `chattr +i` (not available here).
  * step-up tokens are `<nonce>.<mac>` so that they can actually be verified.
"""
import argparse
import hashlib
import hmac
import ipaddress
import json
import os
import secrets
import shutil
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

STATE = Path(os.environ.get("NYX_STATE", "/lab/state"))
POLICY_F = Path(os.environ.get("NYX_POLICY", "/lab/etc/mission-policy.json"))
TOOLS_F = Path(os.environ.get("NYX_TOOL_POLICY", "/lab/etc/tool-policy.json"))
KEY_F = Path(os.environ.get("NYX_KEY_FILE", "/lab/etc/gate.key"))
SEAL_F = Path(os.environ.get("NYX_SEAL", "/lab/etc/policy.sha256"))


def utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def out(code, ok, **kw):
    print(json.dumps({"ok": ok, "code": code, "utc": utc(), **kw},
                     ensure_ascii=False, sort_keys=True))
    sys.exit(0 if ok else 1)


def jload(p):
    try:
        return json.loads(Path(p).read_text(encoding="utf-8"))
    except Exception as e:
        out("deny_config_unreadable", False, path=str(p), error=str(e))


def key():
    if not KEY_F.exists():
        out("deny_no_key", False, hint="mission_gate.py init")
    k = bytes.fromhex(KEY_F.read_text().strip())
    if len(k) < 32:
        out("deny_weak_key", False)
    return k


def canon(o):
    return json.dumps(o, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False).encode()


def sign(o, k):
    return hmac.new(k, canon(o), hashlib.sha256).hexdigest()


def sha_file(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def audit(rec):
    STATE.mkdir(parents=True, exist_ok=True)
    f = STATE / "audit.jsonl"
    prev = ""
    if f.exists():
        with f.open("r", encoding="utf-8") as r:
            for line in r:
                line = line.strip()
                if line:
                    prev = json.loads(line).get("self_sha256", "")
    rec = dict(rec, utc=utc(), prev_sha256=prev)
    rec["self_sha256"] = hashlib.sha256(canon(rec)).hexdigest()
    with f.open("a", encoding="utf-8") as w:
        w.write(json.dumps(rec, sort_keys=True, ensure_ascii=False) + "\n")
        w.flush()
        os.fsync(w.fileno())
    return rec


def match(host, pat):
    host = host.strip().lower().rstrip(".")
    pat = pat.strip().lower().rstrip(".")
    if pat.startswith("*."):
        base = pat[2:]
        return host == base or host.endswith("." + base)
    try:
        net = ipaddress.ip_network(pat, strict=False)
    except ValueError:
        return host == pat
    try:
        return ipaddress.ip_address(host) in net
    except ValueError:
        return False


def in_scope(host, scope):
    if any(match(host, e) for e in scope.get("exclude", [])):
        return False, "excluded"
    if any(match(host, i) for i in scope.get("include", [])):
        return True, "included"
    return False, "not_listed"


def load_grant(path, k):
    g = jload(path)
    if not hmac.compare_digest(sign(g["grant"], k), g["sig"]):
        out("deny_grant_signature", False, grant=str(path))
    return g["grant"]


def cmd_init(a):
    KEY_F.parent.mkdir(parents=True, exist_ok=True)
    if KEY_F.exists() and not a.force:
        out("key_exists", False, path=str(KEY_F))
    KEY_F.write_text(secrets.token_hex(32))
    os.chmod(KEY_F, 0o600)
    out("key_created", True, path=str(KEY_F))


def cmd_seal(a):
    k = key()
    digests = {p.name: sha_file(p) for p in (POLICY_F, TOOLS_F)}
    body = {"schema": "nyx.seal/v1", "sha256": digests, "utc": utc()}
    SEAL_F.write_text(json.dumps({"body": body, "sig": sign(body, k)}, indent=2))
    os.chmod(SEAL_F, 0o644)
    audit({"event": "seal", "sha256": digests})
    out("sealed", True, sha256=digests)


def cmd_issue(a):
    pol = jload(POLICY_F)
    k = key()
    ttl = min(a.ttl, pol["defaults"]["max_ttl_minutes"])
    grant = {
        "grant_id": "G-" + secrets.token_hex(6),
        "policy_id": pol["policy_id"],
        "objective": a.objective,
        "scope": {"include": a.include, "exclude": a.exclude or []},
        "tools": a.tools or ["*"],
        "persistence": bool(a.persistence),
        "step_up": list(pol["step_up_actions"]),
        "warrant_ack": True,
        "issued": utc(),
        "exp": int(time.time()) + ttl * 60,
        "nonce": secrets.token_hex(8),
    }
    rec = {"grant": grant, "sig": sign(grant, k),
           "scope_sha256": hashlib.sha256(canon(grant["scope"])).hexdigest()}
    p = STATE / "grants" / (grant["grant_id"] + ".json")
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(rec, indent=2), encoding="utf-8")
    os.chmod(p, 0o600)
    audit({"event": "grant_issue", "grant_id": grant["grant_id"],
           "scope": grant["scope"], "exp": grant["exp"], "sha256": sha_file(p)})
    out("grant_issued", True, grant_path=str(p), grant_id=grant["grant_id"],
        exp=grant["exp"], scope_sha256=rec["scope_sha256"])


def _stepup_check(a, k):
    if "." not in a.step_up:
        out("deny_step_up_invalid", False)
    nonce, mac = a.step_up.split(".", 1)
    exp = hmac.new(k, ("SU|" + nonce).encode(), hashlib.sha256).hexdigest()[:32]
    if not hmac.compare_digest(exp, mac):
        out("deny_step_up_invalid", False)
    used = STATE / "stepup_used.json"
    used_set = set(json.loads(used.read_text())) if used.exists() else set()
    if mac in used_set:
        out("deny_step_up_replayed", False)
    used_set.add(mac)
    used.write_text(json.dumps(sorted(used_set)))
    os.chmod(used, 0o600)


def cmd_verify(a):
    pol = jload(POLICY_F)
    tools = jload(TOOLS_F)
    k = key()
    g = load_grant(a.grant, k)
    if g["policy_id"] != pol["policy_id"]:
        out("deny_policy_mismatch", False)
    if time.time() > g["exp"]:
        out("deny_grant_expired", False, exp=g["exp"])
    ok, why = in_scope(a.target, g["scope"])
    if not ok:
        out("deny_out_of_scope", False, target=a.target, reason=why,
            scope=g["scope"])
    allow = "*" in g.get("tools", []) or a.tool in g.get("tools", [])
    tp = tools["tools"].get(a.tool, {"allow": tools["defaults"]["allow"]})
    if not allow or not tp.get("allow", False):
        out("deny_tool_not_allowed", False, tool=a.tool)
    if tp.get("step_up", False) and not a.step_up:
        out("deny_step_up_required", False, tool=a.tool,
            action="tool:" + a.tool)
    if a.step_up:
        _stepup_check(a, k)
    cnt_f = STATE / "counters" / (g["grant_id"] + ".json")
    cnt_f.parent.mkdir(parents=True, exist_ok=True)
    cnt = json.loads(cnt_f.read_text())["n"] if cnt_f.exists() else 0
    if cnt >= pol["budgets"]["max_ops_per_grant"]:
        out("deny_budget_exhausted", False, ops=cnt)
    cnt_f.write_text(json.dumps({"n": cnt + 1}))
    audit({"event": "exec_authorized", "grant_id": g["grant_id"],
           "target": a.target, "tool": a.tool, "step_up": bool(a.step_up)})
    out("authorized", True, grant_id=g["grant_id"], target=a.target,
        tool=a.tool, ttl_left=max(0, g["exp"] - int(time.time())),
        persistence=g.get("persistence", False))


def cmd_stepup(a):
    k = key()
    mac = hmac.new(k, ("SU|" + a.nonce).encode(), hashlib.sha256).hexdigest()[:32]
    audit({"event": "step_up_issued", "action": a.action, "mac": mac})
    print(a.nonce + "." + mac)


def cmd_ready(a):
    tools = jload(TOOLS_F)
    rows = []
    for name, tp in sorted(tools["tools"].items()):
        b = shutil.which(tp.get("bin", name))
        rows.append({"tool": name, "present": bool(b), "path": b or ""})
    missing = [r["tool"] for r in rows if not r["present"]]
    out("ready" if not missing else "ready_partial", True,
        missing=missing, tools=rows)


def cmd_integrity(a):
    pol = jload(POLICY_F)
    tools = jload(TOOLS_F)
    for p in (POLICY_F, TOOLS_F, Path(__file__)):
        if not os.access(p, os.R_OK):
            out("deny_integrity_unreadable", False, path=str(p))
    if not SEAL_F.exists():
        out("warn_unsealed", False, hint="mission_gate.py seal")
    seal = jload(SEAL_F)
    k = key()
    if not hmac.compare_digest(sign(seal["body"], k), seal["sig"]):
        out("deny_seal_signature", False)
    bad = [n for n, d in seal["body"]["sha256"].items()
           if sha_file(Path("/lab/etc") / n) != d]
    if bad:
        out("deny_policy_tampered", False, files=bad)
    audit({"event": "integrity_ok", "policy_id": pol["policy_id"],
           "tools": len(tools["tools"])})
    out("integrity_ok", True, policy_id=pol["policy_id"])


def main():
    ap = argparse.ArgumentParser(prog="mission_gate")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("init")
    s.add_argument("--force", action="store_true")
    s.set_defaults(fn=cmd_init)

    s = sub.add_parser("seal")
    s.set_defaults(fn=cmd_seal)

    s = sub.add_parser("issue")
    s.add_argument("--objective", required=True)
    s.add_argument("--include", nargs="+", required=True)
    s.add_argument("--exclude", nargs="*")
    s.add_argument("--tools", nargs="*")
    s.add_argument("--ttl", type=int, default=120)
    s.add_argument("--persistence", action="store_true")
    s.set_defaults(fn=cmd_issue)

    s = sub.add_parser("verify")
    s.add_argument("--grant", required=True)
    s.add_argument("--target", required=True)
    s.add_argument("--tool", required=True)
    s.add_argument("--step-up")
    s.set_defaults(fn=cmd_verify)

    s = sub.add_parser("stepup")
    s.add_argument("--action", required=True)
    s.add_argument("--nonce", required=True)
    s.set_defaults(fn=cmd_stepup)

    s = sub.add_parser("ready")
    s.set_defaults(fn=cmd_ready)

    s = sub.add_parser("integrity")
    s.set_defaults(fn=cmd_integrity)

    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
