# Root exception (RQ-20)

Engagement execution runs as uid 10001 (`openhands`). Root is used only for
activation and for the gate:

- `/workspace/kali/nyx.sh` — mounts, chroot wrappers, docker, Mythic.
- `/lab/bin/gate` — HMAC signing; the key is `0400 root:root` so the agent uid
  cannot read it (RQ-03 passes), which means every gate call runs as root.

Sudo policy on this sandbox is `openhands ... NOPASSWD: ALL`. That is the
platform's policy, not the lab's; removing it breaks tool execution, docker
control and the gate. Recorded here as the documented exception required by
RQ-20.

Residual risk: a compromised agent can escalate to root and read `gate.key`.
Mitigation: the gate is the only execution path, every action is logged with
output hashes, and the audit chain plus daily anchors make silent tampering
detectable after the fact.

Review date: 2026-11-22. Re-review on any sudoers or policy change.
