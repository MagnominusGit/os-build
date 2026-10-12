# The update server

Where a device in the field gets its OS updates from. The device half — the `retroforge-update` client,
the RAUC A/B install, the trial boot and rollback — is in `docs/RUNBOOK.md`; this file is the server
and the act of publishing.

**There is no RetroForge update server yet.** Every default in the tree names the placeholder
`updates.retroforge.invalid`, which never resolves: `retroforge-update`'s `DEFAULT_URL`, the installer
medium's `netcfg` and `release-info`, `ota/publish-bundle.sh`, `ota/setup-server.sh` and the
`release-bundle.yml` publish job. A device built today checks, cannot resolve the host, fails closed
and reports "no update" — rather than asking a host someone else owns. Everything below describes the
server the `ota/` scripts stand up and how publishing to it works; until one exists, read *the host*
as whatever you set up.

> **The first-boot gate.** `retroforge-update`'s `check` and apply paths both begin with `setup_done()`:
> until OpenGamepadUI's first-boot flow has written `[general] first_boot=false` into
> `/home/player/.local/share/opengamepadui/settings.cfg`, the client exits 7 ("no update") without
> contacting any server, and `retroforge-update status` shows `setup: first boot not finished (updates
> deferred)`. A device that has finished setup checks normally.

| | |
|---|---|
| Host | **placeholder** `updates.retroforge.invalid` — `RETROFORGE_OTA_DOMAIN` (`setup-server.sh`), `RETROFORGE_OTA_HOST` (`publish-bundle.sh`), the `OTA_HOST` repo variable (CI) |
| OS the scripts assume | Ubuntu with apt, login `ubuntu` with passwordless sudo (written against Ubuntu 24.04 on Oracle Cloud) |
| Serves | nginx, TLS via Let's Encrypt (`certbot certonly --webroot`) |
| Docroot | `/srv/retroforge-ota`, **read-only to the internet** |
| Retention | 3 bundles per channel (`RETROFORGE_OTA_KEEP`) |
| Repo | `ota/` — vhost, bootstrap, publisher |

## Layout

**The docroot is the URL root.** The client's `DEFAULT_URL` carries no path prefix, so a *channel* is
the first path segment:

```
/srv/retroforge-ota/
  stable/
    latest.json               -> https://<host>/stable/latest.json
    retroforge-0.2.0.raucb        -> https://<host>/stable/retroforge-0.2.0.raucb
  beta/
  .well-known/acme-challenge/ (certbot)
```

The host itself comes from `OTA_URL` in `/etc/retroforge/ota.conf` or `RETROFORGE_OTA_URL` in the
environment, falling back to `DEFAULT_URL`. A channel is a directory, not a migration. The client's
`OTA_CHANNEL` selects one, from the first of these that has it:

| source | who can write it | note |
|---|---|---|
| `RETROFORGE_OTA_CHANNEL` | whoever runs the command | one invocation only |
| `/etc/retroforge/ota.conf` | root | only a **dev** card ships this file, pinned to `dev` so the card is never offered a stable release |
| `~/.config/retroforge/ota.conf` | the user, no root needed | `/home/player/.config/retroforge/ota.conf` (spelled out, not `$HOME`); the only one reachable on a release device |
| built-in `stable` | — | |

`/etc` outranks `$HOME` on purpose: a file in `$HOME` must not silently undo the dev card's pin. On
a release image `/etc/retroforge/ota.conf` does not exist, so the user's file is the only entry in the
chain. It may set `OTA_CHANNEL` **only** — `OTA_URL` is read from `/etc` and the environment, never
from `$HOME`, because which host a device fetches from is an operator decision and one writable file
under `$HOME` must not repoint every future update.

`retroforge-update status` prints which of them supplied the channel in effect, which is the fastest
answer to "why is it checking that channel". `retroforge-update channel` prints the same pair
tab-separated for a program to read, so a future channel picker does not re-derive the precedence and
then disagree with the fetch.

### The client contract

`retroforge-update` keeps the exit-code contract it was written to: `check` exits 0 and prints the
available version on stdout, or exits 7 for "none" — and 7 is also how every recoverable failure
exits (unreachable server, malformed manifest), so a check fails closed. Apply (no argument) emits
forward-only `N%` lines on stdout and everything else on stderr. An update already installed and
waiting for a reboot is reported by reprinting its version. The caller is the RetroForge shell plugin's
updates screen; it can also be run by hand over SSH as `player`.

Channel selection lives in the same program: `retroforge-update channels` lists what a picker offers
(`stable`, `beta`, plus the channel in effect if it is neither, and a `pinned<TAB><source>` line
when `/etc` or the environment outranks the user's choice), and `retroforge-update set-channel <name>`
writes `~/.config/retroforge/ota.conf`. The old Steam-shaped `retroforge-select-branch` is gone.

**Which channels exist:** `stable` and `beta`. `ota/setup-server.sh` creates both, and
`release-bundle.yml` decides between them from the tag's semver pre-release suffix — `ota/v0.3.0`
publishes to `stable`, `ota/v0.3.0-beta.1` to `beta`. Not a separate tag namespace, because the
version string then records the channel and duplicate detection turns on that string: two channels
publishing the same `0.3.0` would leave a device switching stable → beta believing it is already up
to date. A beta bundle is signed with the same release key and gated exactly as hard; the channel
decides who is offered it, not whether it is trustworthy. `card/` and `installer/` tags refuse a
pre-release suffix outright — there is no beta card, and a medium installs the latest `stable`
whatever its own version says.

A choice made in `~/.config` survives an OTA and a slot switch on its own: `/home` is one partition
shared by both slots. The copy in `/etc` needs `post-install.sh` to carry it, because that one lives
in the per-slot `/var` overlay upper.

**A channel with no `latest.json` is the correct resting state, not an outage.** The client gets a
404, fails closed and exits 7 — "no update available". That is exactly right between releases. A
placeholder pointing at a bundle that is not there would be worse: it would *offer* an update whose
download 404s after the user has already said yes.

### `latest.json`

```json
{ "version": "0.2.0", "build": "20260803T120000Z", "git": "abc1234",
  "bundle": "retroforge-0.2.0.raucb", "size": 3758096384, "sha256": "…" }
```

`version` is the identity the client compares and dedupes on (`build` stands in when the version is
the literal `dev`); it is read out of the bundle's own manifest, not chosen at publish time. `bundle`
must be a **bare filename** — the client rejects a scheme, a host, a `/`, a `\` or a leading dot.
`git` is for a human reading the file. `size` must be a positive integer or the manifest is refused;
it is what the installer's pre-flight screen shows, and it is no longer checked against the transfer,
because rauc fetches the bundle itself. `sha256` is not checked by the client: the RAUC signature is
the integrity gate, and a hash in a file fetched from the same server proves nothing an attacker
could not also rewrite.

## Cutting an update

**`rsync` must be installed on the publishing workstation.** `publish-bundle.sh` uses it for both
the bundle upload and the `latest.json` flip, and it is *not* in the Arch base install. The script
refuses up front rather than discovering this minutes in.

```sh
# 1. build and sign — the version must be set BEFORE the rootfs, see docs/RUNBOOK.md
RETROFORGE_VERSION=0.2.0 PKIDIR=$HOME/retroforge-pki make bundle

# 2. install it on a device and confirm it boots, BEFORE anyone else gets it
ssh player@<device> rauc install /path/to/retroforge-0.2.0.raucb

# 3. publish
RETROFORGE_OTA_HOST=<host> RETROFORGE_OTA_SSH_KEY=~/.ssh/<key> ota/publish-bundle.sh out/images/retroforge-0.2.0.raucb
```

Step 2 installs from a **local file**. The device streams when `retroforge-update` drives it (below), but
a local `rauc install <file>` is unaffected: rauc's adaptive path is best-effort with an
unconditional fall-through to a plain full-slot copy, so a workstation install writes the same bytes
it always did. It simply gains nothing from adaptive — there is no download to shrink.

Step 2 is not optional and is not ceremony. Nothing on the device confirms a trial boot that never
reaches a session, so a bundle that comes up to a black screen needs about six manual power-cycles to
recover — on a device with no serial console. Every published bundle gets a hardware install first.

### The device streams; it does not download

`retroforge-update` hands rauc the bundle's **https URL**, not a downloaded file. rauc creates an NBD
device backed by an unprivileged helper (user `nobody`) that turns block reads into HTTP `Range`
requests, so a bundle never occupies storage on the device — there is no staging directory to fill
and no free-space precondition on an update.

Because `ota/rauc/manifest.raucm.in` marks the image `adaptive=block-hash-index`, the bundle also
carries a SHA256 index of every 4 KiB block. rauc looks each block up in **both** slots and fetches
only what it cannot find locally. Measured 2026-08-04 across two independent pairs of real
consecutive bundles: **96.1% of non-zero blocks are reused, ~125 MB crosses the wire instead of
3.90 GB.** Matching is content-addressed, and every local hit is re-hashed against the index inside
the signed bundle before use — a corrupt or tampered local index can only cost bandwidth.

**The server must speak HTTP/2 for that to be quick.** rauc's NBD helper turns block reads into many
concurrent Range requests, which is the request pattern HTTP/1 serialises — and rauc warns about it
at the start of every stream (`using HTTP/1 for streaming, expect slow installation`), observed on a
Pocket ACE. The bundle is fetched by rauc; the only thing curl fetches is `<channel>/latest.json`, a
few hundred bytes. `listen 443 ssl http2` (the pre-1.25 spelling, which is what Ubuntu 24.04's
nginx 1.24 understands) is in `ota/nginx-retroforge-ota.conf`.

Consequences worth knowing before reading a slow first result:

- **rauc runs from the RUNNING slot**, so it is that slot's `system.conf` and that slot's
  `retroforge-update` which decide whether an install is adaptive — not the bundle's. A slot whose
  config has no `data-directory` installs any bundle as a plain full-slot write.
- **The first adaptive install still saves; it is just slower.** With no stored index for either
  slot rauc generates them on demand, which costs one pass of hashing both slots. Indices are then
  kept in the data directory on `/home`, which is shared, so they survive the slot switch.
- **Progress tracks the INSTALL, not the transfer.** With most blocks coming from local slots, it
  advances through stretches where nothing crosses the network.
- **A failed stream is cheap to retry.** The correct blocks already written into the target slot are
  exactly what the next attempt finds locally. There is no resume, and there is no way to cancel an
  install once accepted — rauc's D-Bus API has no `Cancel` method. A broken connection is bounded
  (5 range-request retries, then the install fails); a merely stalled one is bounded only by TCP.

Both halves fail *silently* if lost — a rauc built without streaming, or a kernel without `nbd.ko`,
degrades to a full download that still succeeds. `rootfs/guard-rootfs.sh` asserts both at build time.

`publish-bundle.sh` does, in order: verify the signature against the device keyring, read the version
back out of the bundle, check free space on the server, upload to a `.part` name and rename, **hash
the uploaded file on the server and compare it to the local one**, prove the bundle is readable at
its public URL with a `Range` request, **flip `latest.json` last**, read that back over HTTPS, and
prune to `KEEP`. Everything before the flip is invisible to devices; the flip is the publish.

The server-side hash is not redundant with rsync's own checksum. `$SHA` is computed from the local
file *before* the transfer, so without this step the `sha256` published in `latest.json` describes a
file on the workstation, not the one being served. rsync covers a transfer it knows it made; it does
not cover a `.part` a second concurrent publish was also writing (two runs both `rsync --inplace` to
the same path and neither fails — they just interleave), a resume whose earlier half came from a
different build, or a bad disk on the far end. And because the client does **not** check `sha256`
(above), a corrupt bundle would otherwise be caught no earlier than each device's own signature
verification — after a ~4G transfer, per device. Caught here it costs one re-upload.

### Validating a release on hardware, before anything is published

**Proving the update path needs no published card and no published bundle.** It needs a device on
the boot flow you are shipping and a bundle that device will accept, and both are buildable locally.

One thing decides whether a boot-flow change can be shipped as an OTA at all: **RAUC runs the BOOTED
slot's post-install handler, not the bundle's.** A device runs the handler of the release it is on,
so a change the old handler does not understand (a new boot layout, a file it requires that the new
image no longer ships) cannot be fixed in the bundle — the next card is then a mandatory reflash for
every device in the field. Read the running release's `usr/lib/rauc/post-install.sh` against the new
image before promising an OTA. A handler that dies partway is safe for the running system but is
**not a dry run**: it can leave the target slot overwritten and unbootable while the booted slot
keeps running.

```sh
# 1. the device: build the new boot flow locally and flash it. Give the CARD a version too, or
#    both ends render `dev` and there is no version change to detect.
set -a; . ./dev.env; set +a
RETROFORGE_VERSION=<base> PKIDIR=$HOME/retroforge-pki make sdcard    # dev card, new boot flow

# 2. a bundle the device will accept: a DEV image with a REAL signature.
#    rauc gates on the signature, so this installs exactly like a release bundle.
RETROFORGE_VERSION=<bumped> PKIDIR=$HOME/retroforge-pki make bundle

# 3. install it with rauc directly (no server needed). rauc also accepts an https URL and
#    streams it; with a server, `retroforge-update` on the device does the same.
scp out/images/retroforge-<bumped>.raucb player@<device>:
ssh player@<device> rauc install retroforge-<bumped>.raucb
```

Then reboot and confirm the new slot booted and `/etc/retroforge-release` changed. Once the client is
driven by the shell, the same test runs through a TEST channel on your server instead: hand-place the
bundle and a hand-written `latest.json` (schema above) under `/srv/retroforge-ota/test/`, point the device
at it with

```sh
ssh player@<device> 'mkdir -p ~/.config/retroforge && echo OTA_CHANNEL=test > ~/.config/retroforge/ota.conf'
```

(on a DEV card `/etc/retroforge/ota.conf` pins `dev` and outranks this file, so edit that one — you have
root on a dev card), and drive check → install → restart from the shell. Then check again — it must
report up-to-date and **not** re-offer. **Reset the channel when you are done**: `~/.config` is on
`/home`, shared by both slots, so `OTA_CHANNEL=test` survives the update and the device silently
keeps reading it forever. `retroforge-update status` names the file it came from.

**`ota/publish-bundle.sh` refuses dev bundles, and that does not obstruct this.** The mode gate
protects `stable` from a test image reaching the fleet; hand-placing a bundle in a channel of your
own, on your own server, is you doing something explicit. The gate is on publishing, not installing.

Only once that passes: tag `card/vX.Y.Z`, then `ota/vX.Y.Z`.

**`ota/vX.Y.Z` publishes by itself once a server exists.** `release-bundle.yml`'s `publish` job builds
the bundle, signs it with the release cert and pushes it to the channel directory on
`vars.OTA_HOST` (falling back to the placeholder) as `vars.OTA_USER` (default `otapub`) with the
`OTA_SSH_KEY` secret — `make publish-bundle` from the workstation is the fallback, not the route.
The tag asks for **two approvals**: `build` waits for a reviewer to reach the signing key and
`publish` waits again to reach the publishing key. Signing produces an artifact that still goes
nowhere; publishing is the step that puts bytes in front of the fleet.

A publish ends in exactly one of two states, **published** or **red**: a missing `OTA_SSH_KEY` is an
error, not a skipped step, because nobody reads a skipped step at the bottom of an hour-long success.
With no server configured, a tagged run therefore goes red at publish.

### Rolling back a bad release

The previous bundles are still on the server — that is what `KEEP=3` is for. Edit
`stable/latest.json` to name an older one:

```sh
ssh ubuntu@<host> \
  "cd /srv/retroforge-ota/stable && sed -i 's/retroforge-0.2.0.raucb/retroforge-0.1.0.raucb/' latest.json"
```

Update `version`, `size` and `sha256` to match the older bundle too — `version` is what the client
compares against the device. This only helps devices that have not updated yet; one that already
installed the bad bundle recovers through the boot failsafe, not through the server.

## The server

```sh
# 1. the CI publishing account (creates `otapub`, installs ota/ci-publish.pub, re-owns the docroot)
tar cz ota | ssh -i <admin key> ubuntu@<host> \
  'sudo tar xz -C /tmp && sudo bash /tmp/ota/setup-ci-user.sh'

# 2. stand it up, or re-run it — idempotent, and a second run reports state without changing it
tar cz ota | ssh -i <admin key> ubuntu@<host> \
  'sudo tar xz -C /tmp && sudo RETROFORGE_OTA_DOMAIN=<host> RETROFORGE_OTA_EMAIL=<you> bash /tmp/ota/setup-server.sh'

# is it alive?
curl -I https://<host>/healthz
```

> **Known gap in `setup-server.sh`:** it installs the committed vhost and then substitutes the
> domain with a pattern that matches an old hostname, not the `updates.retroforge.invalid` the vhost now
> carries. A non-default `RETROFORGE_OTA_DOMAIN` therefore leaves `server_name` and the certificate paths
> naming the placeholder, and `nginx -t` fails on the missing certificate. Until that is fixed, put
> your host into `ota/nginx-retroforge-ota.conf` before copying `ota/` up.

Then point the device side at it: `DEFAULT_URL` in `retroforge-update`, `installer/release-info` and
`installer/netcfg` (`tests/test-ui.sh` asserts the three agree), or `OTA_URL` in a device's
`/etc/retroforge/ota.conf`; and set the `OTA_HOST` repo variable for CI.

**Order matters, and only in one direction.** `setup-server.sh` defaults the docroot owner to
`otapub` and *dies* if that account does not exist — it will not create a login itself, because the
one property this account exists to have is *no privileges*, and a server bootstrap that quietly
invents accounts is how that gets lost. Run `setup-ci-user.sh` first, or pass
`RETROFORGE_OTA_OWNER=ubuntu` to stand up a server with no CI principal at all.

### The two publishing principals

| | logs in as | key | may |
|---|---|---|---|
| workstation, by hand | `ubuntu` | the instance admin key | anything — it has passwordless sudo |
| GitHub Actions | `otapub` | `OTA_SSH_KEY`, in the `release-signing` environment | write the docroot, nothing else |

`otapub` is a system account with no password, no sudo, and no group but its own; its sole
`authorized_keys` entry is prefixed `restrict`, so no pty and no forwarding of any kind. The public
half is committed at `ota/ci-publish.pub`; the private half exists only as the CI secret.

**A forced command was considered and rejected.** `command="rrsync /srv/retroforge-ota"` covers rsync,
and `publish-bundle.sh` is not an rsync wrapper — it also runs `mkdir`, `df`, `mv`, `chmod`,
`sha256sum` and a `bash -s` prune over ssh. A wrapper whitelisting those becomes a second,
unversioned copy of the publish protocol: two things that must change together and will eventually
disagree. An account with no sudo is the same bound enforced by the kernel instead.

The docroot is therefore `otapub:otapub` mode **2775** — setgid, with `ubuntu` in the `otapub`
group, so both principals can act on each other's files and the by-hand rollback keeps working.
Adding `ubuntu` to a group does not affect sessions that are already open; reconnect.

**Rotating the CI key** needs no device involvement and no keyring change: `ssh-keygen` a new pair,
replace `ota/ci-publish.pub`, re-run `setup-ci-user.sh` — it *rewrites* `authorized_keys` rather than
appending, so the old key stops working — and `gh secret set OTA_SSH_KEY --env release-signing`.

`/healthz` exists because `stable/` is legitimately empty between releases, so every other probe
answers 404 and a dead server looks exactly like a quiet one.

The vhost is `ota/nginx-retroforge-ota.conf` and **the repo is authoritative** — `setup-server.sh`
copies it. This is why certbot is run as `certonly --webroot` and never `--nginx`: the `--nginx`
installer edits the vhost in place, and the running config would stop matching the committed one
with nothing to signal the drift.

### Disk budget

Free space on the server is not spare capacity — it **is** the retention budget. Keeping the
previous releases is what makes a bad update recoverable fleet-wide by re-pointing `latest.json`
(see *Rolling back a bad release*), and that only works while those bytes are still on the server.
A bundle is ~4G and `RETROFORGE_OTA_KEEP=3` per channel, so budget ~12G per channel plus headroom.

`publish-bundle.sh` protects it from the front. Before it moves a single byte it runs
`df -kP` on the destination **over ssh** and requires the bundle's exact size plus 512 MiB of
headroom, then dies telling you to lower `RETROFORGE_OTA_KEEP` or prune by hand — rather than discovering
it after a 4G transfer.

That check is only as good as the free space it measures, which is why the journal is capped.
Ubuntu ships journald with no `SystemMaxUse`, so the built-in default applies — 10% of the
filesystem, up to 4G — spent slowly on logs for a server that only hands out static files.
`setup-server.sh` installs `/etc/systemd/journald.conf.d/10-retroforge-cap.conf` with
`SystemMaxUse=200M` and vacuums once, so the cap applies to what has already accumulated. The
failure this prevents is *not* corruption: an unbounded journal makes a future publish refuse to
start, at a confusing distance from the cause.

```sh
# what is actually being used
ssh -i <key> ubuntu@<host> \
  'df -h /srv/retroforge-ota; journalctl --disk-usage; du -sh /srv/retroforge-ota/*'
```

### Certificate renewal

Two things have to work and only the first is automatic:

1. **certbot renews it on disk.** `certbot.timer`, twice daily, acting at 30 days remaining — about
   60 attempts before expiry, so a transient failure is harmless. Verify with
   `sudo certbot renew --dry-run`.
2. **nginx starts serving the new one.** This does *not* happen by itself. nginx reads certificates
   at startup and holds them in memory, and `certonly` installs nothing and reloads nothing. Without
   a deploy hook the renewal succeeds, the log says so, and the server keeps presenting the old
   certificate until it expires — every device then failing its update check on a TLS error, with
   the only prior warning being a renewal that *succeeded*.

`setup-server.sh` installs `/etc/letsencrypt/renewal-hooks/deploy/10-reload-nginx.sh` for exactly
that. If you rebuild a host by hand, that hook is the step that gets forgotten.

Expiry notices go to `RETROFORGE_OTA_EMAIL`; set it when running `setup-server.sh`, or the script's own
default address is registered with Let's Encrypt.

## Diagnosing an unreachable server

`setup-server.sh` was written against an Oracle Cloud Ubuntu image, which has two firewall layers,
and the **errno tells them apart without any console access**:

| Symptom from outside | Layer | Fix |
|---|---|---|
| Times out (~10 s) | the cloud's network security list / NSG — it DROPs silently | provider console |
| `EHOSTUNREACH`, fails in one RTT | instance iptables — the chain ends in `REJECT --reject-with icmp-host-prohibited`, which *answers* | `iptables -I INPUT <n> …` — see below |
| `ECONNREFUSED`, fails in one RTT | both layers open, nothing listening | `systemctl status nginx` |
| TLS error | nginx is up | certificate — see renewal above |

The iptables trap: the ACCEPT rules must be **inserted before** the trailing REJECT (`-I INPUT <n>`),
not appended (`-A`). An appended rule lands after the REJECT, is never reached, and changes nothing
while looking exactly like a fix in `iptables -S`. `setup-server.sh` walks the chain in order and
reports position rather than presence, and it never opens a port itself — that is a decision a person
makes on a public host.

## Trust model

**`latest.json` is a hint, never a trust boundary.** It says which bundle to fetch and nothing else.
It cannot select a keyring, a verification mode or an install flag, and the client forces `bundle` to
a bare filename so a manifest can never redirect a device to another host. The gate is the RAUC
signature: the device installs a bundle only if it chains to `/etc/rauc/keyring.pem` with
`check-purpose=codesign`.

That is also why `ota/publish-bundle.sh` verifies against that same keyring before it uploads, with
no override. A dev-cert bundle on the server is not a near miss — `make bundle` without `PKIDIR`
mints an *ephemeral 7-day* certificate that is deleted with its tempdir, so the result is a ~4 GB
download that every device in the field discards at the last step.

**Own the hostname at the registrar.** Whoever controls the name's DNS controls its TLS — HTTP-01
would issue them a valid certificate. The signature still bounds the damage to "serves a bundle every
device rejects", a denial of updates rather than a compromise, but a name under somebody else's apex
gives them that lever. Changing the name later needs a device-side change (the `DEFAULT_URL`
literals above), so choose it once.

**rauc's bus policy is open to every local process.** `de.pengutronix.rauc.conf` ships
`<policy context="default"><allow send_destination="de.pengutronix.rauc"/></policy>` and 1.15.2 has
no polkit policy at all, so any local process can call `InstallBundle`. Bounded by signature
verification, so not arbitrary code execution — but it is the actual mechanism behind "unprivileged
install" (`player` installs with no sudo), and it is not polkit. Accepted as a design choice.
