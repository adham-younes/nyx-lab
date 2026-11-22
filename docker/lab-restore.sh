#!/bin/bash
# Restore the lab from a pushed OCI image into a fresh sandbox (~2-4 min).
#   ./lab-restore.sh ghcr.io/<org>/nyx-kali-lab:2026-11-22
set -euo pipefail
TAG=${1:?usage: lab-restore.sh <registry>/<repo>:<tag>}
ROOT=${KALI_ROOT:-/workspace/kali}
[ "$(id -u)" = 0 ] || exec sudo -n "$0" "$@"

docker info >/dev/null 2>&1 || { nohup dockerd --data-root=/workspace/docker >/var/log/dockerd.log 2>&1 & sleep 8; }
docker image inspect "$TAG" >/dev/null 2>&1 || docker pull "$TAG"

mkdir -p "$ROOT"
cid=$(docker create "$TAG" /bin/true)
docker export "$cid" | tar -x -C "$ROOT" --numeric-owner -f -
docker rm "$cid" >/dev/null
for l in bin sbin lib lib64; do
  [ -e "$ROOT/usr/$l" ] && [ ! -L "$ROOT/$l" ] && rm -rf "$ROOT/$l" && ln -s "usr/$l" "$ROOT/$l"
done
echo "restored $TAG -> $ROOT"
exec "$ROOT/nyx.sh" status
