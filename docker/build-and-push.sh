#!/bin/bash
# Build the lab image on any host with Docker (macOS/Linux) and push it.
#   ./build-and-push.sh <ghcr-org-or-user> [tag]
# macOS note: linux/amd64 is emulated (QEMU) and slow (~40-90 min). CI is faster.
set -euo pipefail
ORG=${1:?usage: build-and-push.sh <ghcr-org-or-user> [tag]}
TAG=${2:-$(date +%Y%m%d-%H%M)}
HERE=$(cd "$(dirname "$0")" && pwd)
IMG=ghcr.io/$ORG/nyx-lab:$TAG

avail=$(df -g "$HERE" | awk 'NR==2{print $4}')
[ "$avail" -ge 20 ] || { echo "need >=20G free, have ${avail}G"; exit 1; }

docker buildx build --platform linux/amd64 -f "$HERE/Dockerfile" -t "$IMG" --push "$HERE"
echo
echo "pushed $IMG"
echo "Enterprise Admin Console -> Use a Custom Sandbox Image -> Sandbox Image Tag: $TAG"
