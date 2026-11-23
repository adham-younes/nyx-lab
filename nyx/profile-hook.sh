#!/bin/bash
# /etc/profile.d/99-nyx-session.sh — installed by bootstrap/install.sh.
# Fires session-up.sh --fast once per boot, in the background, so a new
# sandbox shell comes up with the lab already warm. Never blocks a login
# and never prints into it.
[ -n "${NYX_PROFILE_HOOK:-}" ] && return 0
export NYX_PROFILE_HOOK=1

UP=${NYX_SESSION_UP:-/workspace/nyx-lab/nyx/session-up.sh}
[ -f "$UP" ] || return 0

# /lab is a symlink into the persistent volume; fall back if it is not up yet
MARK_DIR=/workspace/lab/state
[ -d "$MARK_DIR" ] || MARK_DIR=${TMPDIR:-/tmp}
MARK="$MARK_DIR/.session-up.boot"
boot=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo once)
if [ -s "$MARK" ] && [ "$(cat "$MARK" 2>/dev/null)" = "$boot" ]; then
  return 0
fi

# session-up.sh re-execs itself with sudo -n; start it detached so the shell
# is never blocked by docker/mythic bring-up.
( setsid nohup bash "$UP" --fast >"${MARK_DIR}/session-up.boot.log" 2>&1 & ) >/dev/null 2>&1
printf '%s' "$boot" >"$MARK" 2>/dev/null || true
return 0
