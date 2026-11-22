#!/usr/bin/env bash
# Resource/throughput tuning for the lab host. Idempotent, best-effort, exits 0.
set -uo pipefail
KALI=${KALI_ROOT:-/workspace/kali}
[ "$(id -u)" = 0 ] || exec sudo -n "$0" "$@"
say() { printf '  %-22s %s\n' "$1" "$2"; }

# apt: parallel host queues, deeper http pipeline, retries (4 CPU box -> 4 jobs)
cat > /etc/apt/apt.conf.d/99nyx-tune <<'EOF'
Acquire::Queue-Mode "host";
Acquire::http::Pipeline-Depth "10";
Acquire::http::Timeout "20";
Acquire::Retries "3";
APT::Install-Recommends "false";
APT::Install-Suggests "false";
EOF
say apt "queue=host pipeline=10 retries=3"

# file descriptors
cat > /etc/security/limits.d/99-nyx.conf <<'EOF'
*    soft nofile 65535
*    hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF
ulimit -n 65535 2>/dev/null
say ulimits "nofile=65535"

# kernel knobs that matter for scans/containers (ignored if read-only)
for kv in vm.max_map_count=262144 net.core.somaxconn=4096 net.ipv4.ip_local_port_range="10240 65000"; do
  sysctl -w "$kv" >/dev/null 2>&1
done
say sysctl "max_map_count/somaxconn/port_range"

# docker: bounded logs, parallel layer pulls; applied on next daemon start
if [[ -d /etc/docker ]]; then
  python3 - <<'PY'
import json, os
p = "/etc/docker/daemon.json"
d = {}
if os.path.exists(p):
    try: d = json.load(open(p))
    except Exception: d = {}
d.setdefault("data-root", "/workspace/docker")
d["log-driver"] = "json-file"
d["log-opts"] = {"max-size": "20m", "max-file": "2"}
d["max-concurrent-downloads"] = 6
d["max-concurrent-uploads"] = 6
json.dump(d, open(p, "w"), indent=2)
PY
  say docker "data-root + 20m log cap + 6 parallel pulls (next start)"
fi

# chroot /tmp on tmpfs: keeps builds/scans off the 25G volume
if [[ -d $KALI/tmp ]] && ! mountpoint -q "$KALI/tmp"; then
  mount -t tmpfs -o size=1G,mode=1777 tmpfs "$KALI/tmp" 2>/dev/null \
    && say chroot-tmp "tmpfs 1G" || say chroot-tmp "mount skipped"
else
  say chroot-tmp "already mounted"
fi

# trim caches that grow silently
rm -rf "$KALI"/var/cache/apt/archives/*.deb "$KALI"/root/.cache/* 2>/dev/null
say cache "apt archives + root cache trimmed"
df -h /workspace | awk 'NR==2{printf "  %-22s %s free of %s\n","disk",$4,$2}'
exit 0
