#!/bin/bash
# Extras that Kali apt does not ship: Sliver, Villain, Havoc teamserver, KEV, nuclei templates.
set -euo pipefail
ROOT=${KALI_ROOT:-/opt/kali}
K=/opt/lab

curl -fsSL https://github.com/BishopFox/sliver/releases/latest/download/sliver-server_linux -o "$ROOT/usr/local/bin/sliver-server"
curl -fsSL https://github.com/BishopFox/sliver/releases/latest/download/sliver-client_linux -o "$ROOT/usr/local/bin/sliver-client"
chmod +x "$ROOT/usr/local/bin/sliver-server" "$ROOT/usr/local/bin/sliver-client"

git clone --depth 1 https://github.com/t3l3machus/Villain /opt/villain
ln -sf /opt/villain/Villain.py "$ROOT/usr/local/bin/villain"
chmod +x /opt/villain/Villain.py

apt-get install -y --no-install-recommends golang-go >/dev/null
git clone --depth 1 https://github.com/HavocFramework/Havoc /opt/havoc
( cd /opt/havoc/teamserver && go build -o /usr/local/bin/havoc-server . )

install -m 755 "$K/kev" "$ROOT/usr/local/bin/kev"
mkdir -p "$ROOT/opt/feeds" "$ROOT/opt/arsenal/windows"
install -m 644 "$K/kev.json" "$ROOT/opt/feeds/kev.json"

curl -fsSL https://raw.githubusercontent.com/topotam/PetitPotam/main/PetitPotam.py \
  -o "$ROOT/opt/arsenal/windows/PetitPotam.py" || true
curl -fsSL https://raw.githubusercontent.com/0x09AL/RdpThief/master/RdpThief/RdpThief.cs \
  -o "$ROOT/opt/arsenal/windows/RdpThief.cs" || true

chroot "$ROOT" nuclei -update-templates -silent >/dev/null 2>&1 || true
rm -rf /opt/villain/.git /opt/havoc/.git
echo "extras installed"
