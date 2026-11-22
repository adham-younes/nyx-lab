# NYX lab: bring the environment up once per boot, in the background.
# Never blocks the shell; set NYX_NO_AUTOSTART=1 to disable.
[ -n "${NYX_NO_AUTOSTART:-}" ] && return 0 2>/dev/null
[ -x /workspace/nyx-lab/nyx/session-up.sh ] || return 0 2>/dev/null
boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)
mark="/run/nyx-session-${boot_id}"
[ -e "$mark" ] && return 0 2>/dev/null
mkdir -p /run 2>/dev/null && : >"$mark" 2>/dev/null
( sudo -n /workspace/nyx-lab/nyx/session-up.sh --fast >/var/log/nyx-session.log 2>&1 & ) >/dev/null 2>&1
