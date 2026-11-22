#!/bin/bash
# Kali tool wrappers: writes ONLY enumerated names into a real (non-symlink) dir.
set -u
ROOT=${KALI_ROOT:-/workspace/kali}
BIN=/workspace/kali/opt/kaliwraps
MARK="# kali-chroot-wrapper"
TOOLS="nmap ncat nc nping masscan rustscan sqlmap msfconsole msfvenom msfdb searchsploit hydra john hashcat medusa nuclei ffuf gobuster feroxbuster dirb nikto whatweb wpscan wafw00f dnsrecon dnsenum amass theharvester whois dig enum4linux enum4linux-ng smbclient smbmap responder netexec nxc crackmapexec impacket-secretsdump impacket-psexec impacket-wmiexec impacket-ntlmrelayx impacket-getST impacket-ticketer bloodhound-python certipy-ad ssh-audit sslscan testssl tcpdump tshark aircrack-ng airmon-ng bettercap mitmproxy chisel socat patator cewl crunch gdb radare2 r2 binwalk foremost arpspoof ettercap msfpc setoolkit commix wfuzz wireshark evil-winrm kerbrute sshuttle sliver-server sliver-client havoc villain httpx subfinder naabu spiderfoot theHarvester sherlock maigret yara vol certipy shodan censys mitm6 ligolo-proxy ligolo-agent age obfs4proxy donut coercer krbrelayx bloodyad kev httpx-toolkit havoc-server tor-up"

if [ -L "$BIN" ]; then echo "FATAL: $BIN is a symlink (would write into the chroot). Aborting."; exit 1; fi
mkdir -p "$BIN"
made=0; skipped=0
for t in $TOOLS; do
  p=$(chroot "$ROOT" sh -c "command -v $t" 2>/dev/null | head -1)
  [ -z "$p" ] && continue
  case "$p" in /*) ;; *) continue ;; esac
  tmp=$(mktemp)
  printf '#!/bin/sh\n%s\nexec sudo -n %s/enter.sh %s "$@"\n' "$MARK" "$ROOT" "$p" > "$tmp"
  chmod 755 "$tmp"
  install -m 755 "$tmp" "$BIN/$t"
  dest=/usr/local/bin/$t
  if [ -e "$dest" ] && ! grep -q "kali-chroot-wrapper" "$dest" 2>/dev/null; then
    skipped=$((skipped+1))
  else
    install -m 755 "$tmp" "$dest"
  fi
  rm -f "$tmp"
  made=$((made+1))
done
tmp=$(mktemp); printf '#!/bin/sh\n%s\nexec sudo -n %s/enter.sh "$@"\n' "$MARK" "$ROOT" > "$tmp"; chmod 755 "$tmp"
install -m 755 "$tmp" "$BIN/kali"; install -m 755 "$tmp" /usr/local/bin/kali; rm -f "$tmp"
echo "wrappers=$made localbin_total=$(ls -1 /usr/local/bin | wc -l) skipped_non_ours=$skipped"

install -m 755 "$ROOT/nyx.sh" /usr/local/bin/nyx
