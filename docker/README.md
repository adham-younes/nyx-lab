# NYX lab — persistent image routes

Three ways to keep the arsenal. Only one of them survives a **brand-new sandbox**.

| Route | Works on | Cold start | Disk needed |
|---|---|---|---|
| A. Custom sandbox image (`Dockerfile`) | OpenHands **Enterprise** only | ~0 s (baked) | ~20G to build |
| B. OCI snapshot (`lab-export.sh` / `lab-restore.sh`) | **SaaS and Enterprise** | 3-5 min | ~13G at restore |
| C. Volume + `nyx` (current) | SaaS, same sandbox | 3 s | 13G (already used) |

> OpenHands SaaS (app.all-hands.dev) does **not** support custom sandbox images yet —
> see docs: `enterprise/custom-sandbox-images`. Route A needs a self-hosted Enterprise
> install (Admin Console → Use a Custom Sandbox Image).

## A. Custom image (Enterprise)

```bash
docker buildx build --platform linux/amd64 \
  -f docker/Dockerfile \
  -t ghcr.io/<org>/nyx-lab:<tag> --push docker/
```

- Extends `ghcr.io/openhands/agent-server:1.46.0-python`; the base entrypoint
  (`tini -- openhands-agent-server`) is left untouched, as required.
- Bakes a Kali rolling chroot at `/opt/kali` (same merged-usr layout proven at runtime),
  the 95 wrappers, `nyx`, CISA KEV, nuclei templates, Sliver/Havoc/Villain, and a
  memory snippet that tells the agent to run `nyx` first.
- Build args: `WITH_SECLISTS=0` drops 1.9G; `KALI_MIRROR=...` for a local mirror.
- Validated with `docker build --check` (no warnings). A full build needs ~20G free and
  ~20-30 min; it was **not** executed on this 25G volume.

## B. OCI snapshot (SaaS-compatible)

```bash
# on the machine/sandbox that has the finished lab
export GITHUB_TOKEN=<token with packages:write>
./docker/lab-export.sh ghcr.io/<org>/nyx-lab:2026-11-22

# in any brand-new sandbox
./docker/lab-restore.sh ghcr.io/<org>/nyx-lab:2026-11-22
```

`lab-export.sh` streams `tar | docker import` (no temp copy), then pushes.
`lab-restore.sh` pulls, `docker export | tar -x` into `/workspace/kali`, repairs the
merged-usr symlinks, and runs `nyx status`.

Requirements: docker in both sandboxes (present), registry auth (`docker login ghcr.io`),
and ~13G free where the lab is restored. Export needs the same 13G in the docker store.

## C. Current setup

`sudo /workspace/kali/nyx.sh` — mounts, wrappers, dockerd, Mythic, disk report.
State lives on the 25G volume; a new sandbox has a new volume, so use A or B for that.
