---
name: kali-env
description: Activate and use the persistent Kali offensive lab — 95 tools (nmap, sqlmap, metasploit, sliver, mythic, havoc, netexec, certipy, responder, hashcat, nuclei, subfinder, httpx, naabu, spiderfoot, volatility3, donut, tor, chisel, ligolo-ng, kev). Use for any scanning, exploitation, C2, AD attack, password, OSINT, RE or threat-intel task, and at the start of every session.
---

# Kali offensive lab

Plain Debian image + persistent Kali rolling rootfs at `/workspace/kali` (14G) with 95
wrappers in `/usr/local/bin`; C2 stack in docker (data on `/workspace/docker`).

## Activate (always first)

```bash
sudo /workspace/kali/nyx.sh          # everything: mounts, wrappers, docker, Mythic, disk report
sudo /workspace/kali/nyx.sh full     # + Tor SOCKS5 127.0.0.1:9050
sudo /workspace/kali/nyx.sh clean    # prune caches if disk < 4G free
```

## Usage

Tools run as root inside the chroot (`uid 0`, `cap=ep`):

- `nmap -sS -Pn <t>` · `sqlmap -u <url>` · `sliver-server` · `havoc-server` · `vol -f mem.raw windows.pslist`
- Arbitrary Kali command: `sudo /workspace/kali/enter.sh bash -lc '<cmd>'`
- C2: Mythic `https://127.0.0.1:7443` (8 containers), Villain, Sliver, Havoc
- Anonymity: `tor-up`, `proxychains4`, `chisel`, `ligolo-proxy`/`ligolo-agent`
- Intel: `kev <term>` | `kev --recent 20` | `kev --ransomware`
- Wordlists chroot `/usr/share/seclists`; payloads chroot `/opt/arsenal/windows`

## Failure modes

- `chroot: failed to run command ...: No such file or directory` → `/workspace/kali/bin`
  replaced by a real dir; `nyx` repairs it.
- `GLIBC_2.4x not found` → binary run on the host instead of via `enter.sh`.
- `sudo: symbol lookup error` → `env -i PATH=/usr/bin:/bin /usr/bin/sudo …`.
- Tor "Couldn't create private data directory" → use `/opt/tor-up.sh`.
- Docker images missing after restart → daemon must use `--data-root=/workspace/docker`.
- Logs must go to `/var/log`; root cannot write `/tmp` files owned by `openhands`.
