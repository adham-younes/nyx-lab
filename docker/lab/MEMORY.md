
## NYX lab (baked image)

The offensive lab is preinstalled at `/opt/kali` (Kali rolling chroot) with 95 wrappers in
`/usr/local/bin`. Activate at the start of every session:

```bash
sudo /workspace/kali/nyx.sh          # or: sudo nyx
```

`nyx` mounts proc/dev/sys, repairs merged-usr symlinks, regenerates wrappers, starts dockerd
and (if present) Mythic, then prints the disk report. `nyx full` also starts Tor.
Use `sudo /workspace/kali/enter.sh <cmd>` for arbitrary Kali commands (uid 0, cap=ep).
Never `cp` a glob into `/usr/local/bin`; never create real dirs at
`/workspace/kali/{bin,sbin,lib,lib64}` (they are symlinks into `usr/`).
