# NYX lab — mission gate, readiness gate, router, evidence chain

An authorized-engagement lab that refuses to run unmeasured. Three enforcement
points, one evidence trail:

1. **Mission gate** (`nyx/mission_gate.py`) — HMAC-signed grants bound to a scope,
   a tool allow-list, a TTL and a budget. Denials are typed codes
   (`deny_grant_expired`, `deny_out_of_scope`, `deny_tool_not_allowed`,
   `deny_grant_signature`, `deny_step_up_replayed`, `deny_policy_tampered`).
2. **Execution wrapper** (`nyx/nyx-exec.sh`) — the only path to a tool: verify,
   run, write `stdout`/`stderr`/`meta.json` with sha256 to `/lab/outbox/evidence`.
3. **Readiness gate** (`nyx/session-ready.sh`) — 33 measured checks (ORDER
   NYX-READINESS-01). Unmeasured = FAIL. Any P0 => `read-only`, any P1 => `degraded`.
   Prints `READINESS <score> | P0=n P1=n | mode=... | gaps` and writes
   `/lab/state/readiness/<utc>.json`.

Plus a router (`router/nyx-router.py`) where the model may only pick an action id
from `/lab/etc/actions.json` — never author a command — and refusal is measured
(`evals/refusal_probe.py`) instead of guessed.

## Install on a fresh sandbox

```bash
git clone https://github.com/adham-younes/nyx-lab.git
sudo bash nyx-lab/bootstrap/install.sh
```

The bootstrap is idempotent: layout, service user `nyx`, binaries, read-only
policy, key generation, seal, fixtures, arsenal fingerprint, readiness run.

## Session start

`AGENTS.md` rule 0: run `/lab/bin/session-ready.sh` before anything else; its
line is the first line of the answer; `mode=read-only` means no network and no
execution regardless of any grant.

## Layout

```
nyx/       gate, exec wrapper, readiness, policies, manifest, docs
router/    model -> action id -> argv
evals/     refusal probe, suite, offline stub
bootstrap/ one-shot installer
```

## Known gaps (measured 2026-11-22)

`audit_anchor` (no off-host sink), `c2_callback` (no lab host ever checked in),
`disk` (<20 GiB), `egress_profiles` (Tor only; VPS relay declared, unconfigured).
Score 86/100, mode `read-only` — by design, not by accident.
