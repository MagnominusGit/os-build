# CI

## Today: `.github/workflows/ci.yml`

Three jobs, no secrets, on every push and pull request:

| job | what it runs | needs |
|---|---|---|
| `test` | `make test` — `verify-lock`, then every offline suite under `tests/` (boot state, post-install, update client, pairing, power, installer UI, rootfs guard, upstream-name check, …) | the runner's shell, plus `grub-common` so `test-install.sh`'s grub-editenv case runs |
| `disk` | `tests/test-select-target.sh` and `tests/test-carve.sh` — the installer's disk choice and carve, against the real GPTs captured in `docs/internal-storage.md` | `gdisk`, `mtools`, `dosfstools` from apt |
| `signing` | `make test-signing` — every case a negative against `ota/rauc/verify-signing.sh` | `build/Dockerfile`'s `signing` stage (rauc + openssl + mksquashfs, ~66 MB) |

## Today: `.github/workflows/overlay.yml` — the package compile pass

Builds the from-source overlay packages a **pull request** touches, to prove they still compile.
It publishes nothing and needs no secrets. Triggered by a change to any overlay input
(`packages/*/source.pin`, its patches, a local `PKGBUILD`, `build-overlay.sh`, `inputhash.sh`,
`build/builder.pin`, `build/snapshot.pin`, `build/lib-pins.sh`), plus `workflow_dispatch`.

| job | runner | what it runs |
|---|---|---|
| `plan` | x86 | `verify-lock-rows.sh`, then a `git diff` against the base ref → the build matrix |
| `build` | `ubuntu-24.04-arm` | one job per *changed* package: `build-overlay.sh --only <pkg> --no-index` (PRs and dispatches only) |
| `warm` | `ubuntu-24.04-arm` | on `main` only: restore the overlay cache, `build-overlay.sh --prune-retired`, save it back |

Three properties this leans on:

- **Native aarch64, so no emulation.** `build-overlay.sh`'s own binfmt probe passes and it never
  registers qemu or needs `--privileged`. `vars.OVERLAY_RUNNER` overrides the label; do **not**
  point it at a self-hosted runner while this repo is public.
- **Fork PRs run it fine**, now that nothing is published: `contents: read`, no secrets, no registry.
- **Unknown scope widens the check.** A dispatch with no diff base, or a change to the builder
  itself, selects every package rather than none.

**A push to `main` runs `warm`, not the matrix.** `warm` keeps the overlay cache the release builds
restore (`actions/cache`, key `overlay-aarch64-<hash of every overlay input>`, falling back to the
previous `main` entry). `build-overlay.sh`'s per-package stamps then rebuild only what moved, as they
do on a dev box. It has to be `main`: caches are scoped by ref, and a release runs on a **tag**, which
can read `main`'s caches but saves into a scope no later tag can see. PR caches, fork PRs included,
are never visible to a release. `workflow_dispatch` on `main` with no package list re-warms by hand;
on any other branch it forces a proof pass over a branch that never saw a PR.

### What used to be here

Until 2026-08-04 this workflow was a build-once-and-cache pipeline: it published every package to
GHCR keyed by `packages/inputhash.sh`, ran a `verify` job asserting a cold machine could reconstitute
the repo with zero compiles, and opened a **pin-bump PR** carrying each artifact's sha256 into
`packages/*/artifact.pin` — which a release build then enforced. It needed two PATs (`PIN_BUMP_PAT`,
`GHCR_PRUNE_TOKEN`), a pinned `oras`, and a prune job.

It was retired because its premise was a **dev-box** number. An overlay build costs hours under arm64
emulation on a workstation, and the store existed so nothing paid that twice. CI never paid it: on
`ubuntu-24.04-arm` the packages measured `sddm 5m, mesa 5m, gamescope 4m, scx-scheds 4m,
mangohud 3m, rauc 1m` — well under half an hour for the set (the larger set the tree started from
took ~34 minutes), against a release card build that already ran 33–41 minutes. Both PAT secrets can
be deleted; nothing reads them.

That half hour is still paid by every release build job, rebuilding identical sources almost every
time, which is what brought back the `warm` cache. It keeps none of the store's machinery: no registry, no secret,
no pin, no bot. The stamps decide freshness, and `fetchlock.sh` checks the lock rows against the
commit's sources the same as ever.

The signing job checks the committed keyring (`ota/rauc/qforge-ca.pem`) against the committed
release certificate (`ota/rauc/release.cert.pem`). Both are public, so it runs on a fork's PR
with access to nothing. The private half — does the signing *key* match that cert — announces
itself as skipped there and runs wherever a PKI is mounted:

    PKIDIR=~/qforge-pki make test-signing

## Today: the release image builds

`.github/workflows/image.yml` is a `workflow_call`-only builder: restore the overlay cache `warm`
saved on `main` → `build-overlay.sh --prune-retired` (a re-index when nothing moved, ~30 min cold) →
`make toolchain` → `make sdcard`, `make bundle` or `make installer`, with `df -h` into the step
summary.
work/ peaks near 30 GB and out/ near 21 GB against ~109 G free on the runner, measured by
`preflight.yml` — there is room, and an earlier design that deleted each stage's inputs as it went
was reverted as cleverness bought against a limit that is not there. Two thin callers invoke it on
their own triggers, because a flashable card, a field update and the installer medium are wanted at
different cadences:

| workflow | trigger | secrets | ships to |
|---|---|---|---|
| `release-sdcard.yml` | `card/v*` tag, or manual | `R2_*` (push-only, public bucket) | Cloudflare R2 + a GitHub Release carrying checksums/provenance |
| `release-installer.yml` | `installer/v*` tag, or manual | `R2_*`, same environment as the card | R2 under `installer/<version>/` (keeps 2) + a GitHub Release |
| `release-bundle.yml` | `ota/v*` tag, or manual | `RAUC_CERT_PEM`/`RAUC_KEY_PEM` and `OTA_SSH_KEY`, in `release-signing` | the update server named by `vars.OTA_HOST` — **none exists yet**; the default is the placeholder `updates.qforge.invalid`, so a tagged publish goes red (see `docs/ota.md`) |

**The tag namespaces are separate on purpose.** A bundle ships far more often than a card, so each
gets its own namespace rather than sharing a bare `v*`. That also fixes a real inversion: while
`release-sdcard.yml` owned `v*` alone and `release-bundle.yml` had no tag trigger, tagging a release
built a card and *never* a bundle. `card/v1.3.0` and `ota/v1.3.0` on one commit are the same OS
delivered two ways.

**A card is not a release asset** — GitHub caps those at 2 GiB, and the card measured well over that
on the reference build (figures in `ota/publish-card.sh`; re-measure now that the root is smaller). It goes to
a public R2 bucket (`ota/publish-card.sh`, retention N=1 to stay inside the 10 GB free tier) and
the Release carries only `sha256sums.txt`, `manifest.lock` and the link.

**CI is the only thing that PUBLISHES a release image**, because the R2 and signing credentials live
here. Building one is not restricted: `make sdcard` with no `QFORGE_DEV` produces a real release
image on a dev box, which is how a release image's first boot gets tested on hardware.

The blocker that once made a release build impossible on a clean runner is worth recording. A clean
runner has no `work/`, so it rebuilt the overlay, and because our builds are not bit-reproducible
`rootfs/fetchlock.sh` failed every run — the lock pinned those rows to artifact bytes only the last
`make relock` machine could reproduce. The lock now pins them to their **sources**, which is the
claim that survives crossing a machine. A release image's overlay is built from those same sources —
in the run itself, or by `main`'s `warm` job under stamps that hash them — so the source pins are also
its byte provenance. See `packages/README.md`.

## Not here yet, and why

**Bundle signing, beyond a CI secret.** `release-bundle.yml` signs only on an `ota/v*` tag, in its
`sign` job, inside the protected `release-signing` environment that holds `RAUC_CERT_PEM` /
`RAUC_KEY_PEM`; a dispatch builds with an ephemeral dev cert — it proves the bundle assembles and the
verity hashes compute, while producing something every device will reject. The open question is
whether the release private key belongs in GitHub at all. The shape is settled by the PKI:

- **one secret**, the release signing key, scoped to a protected *environment* (not the repo, where
  any workflow on any branch can read it). Write it to `$RUNNER_TEMP`, never the workspace — the
  repo tree gets uploaded as artifacts and cached.
- `PKIDIR=$RUNNER_TEMP/pki make bundle` mounts it read-only at `/pki` and points `RAUC_CERT` /
  `RAUC_KEY` at it. Copy the committed `ota/rauc/release.cert.pem` in alongside the key.
- `verify-signing.sh` then asserts the key matches the committed cert *as public-key digests*, so a
  stale or truncated secret fails there instead of producing bundles no device accepts.
- **the CA key never reaches a runner.** That is what the two-level PKI is for: if the release key
  leaks, mint a new cert offline under the same CA, commit it, update the one secret — no device is
  affected. See `ota/gen-signing-ca.sh`.
- worth considering before real releases: signing off-CI, or via an HSM/KMS the runner reaches by
  OIDC, so the key never exists as a file. A key that can push arbitrary code to devices with no
  serial console is a large thing to keep in a CI secret store.

**cosign-signed artifacts and published update manifests** — the original Phase 7 scope, CI
patterns borrowed from ublue-os/image-template, for the single unified image (every supported SoC
in one kernel + boot artifact). All of it sits on top of a working image build. The runtime update
mechanism stays RAUC A/B over read-only Btrfs roots.

## The standing caveat

CI green is not evidence about the device. The self-test runs the **build container's** rauc
against the shipped config; the device runs its own (`packages/rauc`). A 1.14-on-device /
1.15-in-container skew is exactly how the dm-verity install bug reached hardware. Only an on-device
`rauc install` is evidence about the device.
