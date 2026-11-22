#!/bin/sh
# Enter the persistent Kali rootfs at /workspace/kali with host mounts wired in.
ROOT=${KALI_ROOT:-/workspace/kali}

mountpoint -q "$ROOT/proc" || mount -t proc proc "$ROOT/proc"
mountpoint -q "$ROOT/dev"  || mount --rbind /dev "$ROOT/dev"
mountpoint -q "$ROOT/sys"  || mount --rbind /sys "$ROOT/sys"
[ -f /etc/resolv.conf ] && cp -f /etc/resolv.conf "$ROOT/etc/resolv.conf"
mkdir -p "$ROOT/work" "$ROOT/workspace"
mountpoint -q "$ROOT/work" || mount --bind /workspace/project "$ROOT/work"
mountpoint -q "$ROOT/workspace" || mount --bind /workspace "$ROOT/workspace"

if [ "$#" -gt 0 ]; then
    exec chroot "$ROOT" "$@"
fi
exec chroot "$ROOT" /bin/bash -l
