#!/usr/bin/env bash
# Seal or verify the manifest. A fake fingerprint is worse than none:
# this writes what is on disk, right now.
#   ./seal.sh           # write real hashes
#   ./seal.sh --check   # verify, exit 1 on mismatch
set -Eeuo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

python3 - "$ROOT" "$HERE/manifest.json" "${1:-}" <<'PY'
import hashlib, json, os, sys

root, man, mode = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(man))
bad = 0
for f in data["files"]:
    p = os.path.join(root, f["path"])
    h = hashlib.sha256()
    with open(p, "rb") as fh:
        for b in iter(lambda: fh.read(1 << 20), b""):
            h.update(b)
    real = h.hexdigest()
    if mode == "--check":
        ok = real == f["sha256"]
        bad += 0 if ok else 1
        print(("OK   " if ok else "FAIL ") + real[:16] + "  " + f["path"])
    else:
        f["sha256"] = real
        print(real + "  " + f["path"])

if mode != "--check":
    json.dump(data, open(man, "w"), indent=2, ensure_ascii=False)
    open(man, "a").write("\n")
    print("\nmanifest sealed:", man)
else:
    print("\nverified:", len(data["files"]) - bad, "ok,", bad, "mismatched")
    sys.exit(1 if bad else 0)
PY
