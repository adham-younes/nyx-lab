# NYX Operational Playbook v3.0

## 0. Every run, before anything
1. `python3 /lab/bin/mission_gate.py integrity`
2. `python3 /lab/bin/mission_gate.py ready` -> measured readiness table
3. Emit binding line. No grant -> read-only, no network.
4. All execution: `NYX_GRANT=... NYX_TARGET=... /lab/bin/nyx-exec.sh <tool> <argv...>`
5. Scope gaps: report `deny_out_of_scope` verbatim; request a new grant; never widen.

## 1. Phases
| Phase | Goal | Tools | Success criterion |
|---|---|---|---|
| 1 Recon | target map | amass, httpx, curl, dnsx | infra + stack + vectors in evidence |
| 2 Enumeration | weakest entry | nmap/masscan, nuclei, ffuf, nikto | ranked CVEs with evidence paths |
| 3 Exploitation | foothold | msfconsole, sqlmap, custom PoC | command executed, output returned+hashed |
| 4 Post-Exploitation | control | impacket, hashcat, john, responder | access levels, cred inventory, lateral map |
| 5 Delivery | objective | evidence pack, report, cleanup manifest | objective met, artifacts removed and proven |

## 2. Phase notes
Recon: passive first, then light active. Every probe through `nyx-exec.sh`.
Enumeration: rank by probability x access value; no full-range sweep outside grant.
Exploitation: pre-check version/CPE, fire highest-probability module, verify by
returned output, not by exit code. Staged payloads in scratch, removed after use.
Post: escalation, credential access within objective, lateral only inside scope,
persistence only if grant declares it — registered in the cleanup manifest.
Delivery: pack evidence with hashes, verify cleanup by re-running removal checks,
preserve target logs, write report with reproduction and remediation.

## 3. Hard rules
- No `meta.json` -> not a result.
- Exit code 2 = failure. File existence != verification.
- 3 identical failures -> dump state, switch technique.
- Installing tooling: operator infra only, recorded with hash. Never on target.
- Denial -> one technical line, propose compliant path, do not retry around the gate.

## 4. Anomaly log
Ownership/metadata mismatch -> `00-anomalies.md` in the evidence pack:
OBSERVED <source> <utc> <what>. Continue. Never interrogate the operator.
