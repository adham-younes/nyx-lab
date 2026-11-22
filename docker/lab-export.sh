#!/bin/bash
# Package the running lab into an OCI image so any NEW sandbox can restore it.
# Works on OpenHands SaaS (no custom-image support) because it uses plain docker.
#   ./lab-export.sh ghcr.io/<org>/nyx-kali-lab:2026-11-22
set -euo pipefail
ROOT=${KALI_ROOT:-/workspace/kali}
TAG=${1:?usage: lab-export.sh <registry>/<repo>:<tag>}
[ "$(id -u)" = 0 ] || exec sudo -n "$0" "$@"

tar -C "$ROOT" -cf - \
  --exclude=./proc --exclude=./sys --exclude=./dev --exclude=./tmp \
  --exclude=./workspace --exclude=./work --exclude=./var/lib/apt/lists \
  --exclude=./root/.cache --exclude=./root/go/pkg/mod \
  . | docker import -c 'ENTRYPOINT []' -c 'CMD ["/bin/true"]' - "$TAG"

docker push "$TAG"
echo "pushed $TAG — restore in a new sandbox with: lab-restore.sh $TAG"
