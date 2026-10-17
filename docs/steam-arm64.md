# Valve's arm64 Steam client on ARMv8.0 SoCs (SM6115)

**Status (2026-10-10):** the cause is found and the fix is written. Valve's arm64 client ran on the
MANGMI Air X (Cortex-A73/A53) up to its Big Picture sign-in screen, self-updated to the current
build, inside Valve's arm64 Steam Runtime, with the userspace LSE shim. The kernel fix
(`kernel/patches/0025`) is built but has not booted on hardware yet.

## What fails

Client builds since 2026-04-15 target ARMv8.1 with LSE atomics and no fallback
([steam-for-linux#13288](https://github.com/ValveSoftware/steam-for-linux/issues/13288)). A scan of
every arm64 ELF in the client (`llvm-objdump`, manifest version 1788652215) found ~13,700 unguarded
LSE instructions -- 12,909 `ldaddal`, then `ldadd`, `swpal`, `casal`, `swpa`, `ldumaxah`, `casl`, `caspal` and
the rest, every size and ordering -- in steamclient.so, steamui.so, streaming_client, steamwebhelper,
the `steam` binary itself and others. Nothing else beyond ARMv8.0 matters: the `ldapur`/fp16 hits
are OpenSSL constant tables decoded as code, and libcef's dot-product code is runtime-dispatched
(libcef itself has only 51 LSE sites). The first crash on the Air X, reproduced: `vulkandriverquery`
SIGILL at its first atomic; the client's first SIGILL in a worker thread is
`ldaddal x1, x0, [x0]` in `ThreadInterlockedExchangeAdd64` (libtier0_s.so +0x21960).

## The fix

`kernel/patches/0025-arm64-emulate-lse-atomics-on-cpus-without-them.patch`: the EL0
undefined-instruction path emulates LDADD/LDCLR/LDEOR/LDSET/LD{S,U}{MAX,MIN}, SWP, CAS, CASP (and
LDAPR) as LDXR/STXR compare-exchange loops between full barriers, on CPUs without LSE only.
HWCAP_ATOMICS stays clear, so outline-atomics software keeps its native path. It is the general fix
for every ARMv8.0 board, and needs nothing from the client.

Measured with the userspace twin on the Air X (`tools/lse/`): all 55,288 semantic checks and both
contended counters pass; the Steam client emulated ~9,000 atomics/s (4.18 M in an ~8-minute run,
the self-update included), which at 0.86 us each through a signal is under 1% of one core. The
kernel trap costs less than a signal round trip.

## What else running the client needs

Found on the way, independent of the CPU:

1. **The arm64 Steam Runtime.** The client loads `steamui.so`, which needs GTK2 and the rest of
   the runtime; Holo has none of it, and the client strips `LD_LIBRARY_PATH`. Run it in Valve's
   container: `steam-runtime-steamrt-arm64.tar.xz` from
   `repo.steampowered.com/steamrt3c/images/latest-steam-client-general-availability/`, then
   `<runtime>/run -- steamrtarm64/steam -gamepadui`. (The manifest's `runtime_steamrt_linuxarm64`
   is the x86_64/i386 runtime for FEX games, not this one.)
2. **`~/.steam/steam` and `~/.steam/root`** pointing at the client root ("Steam data link does
   not exist, client is misconfigured").
3. **A clean environment for pressure-vessel**: a `DBUS_SESSION_BUS_ADDRESS` from another user
   (root's, over SSH) makes bwrap fail on `/run/user/0/bus`.
4. **Something to relaunch it after a self-update.** The client exits after installing an
   update ("Update complete, launching Steam...") and expects its wrapper script to start it again.
5. The client zips use backslash paths; extract with the separators converted.

Test install on the Air X: `/home/player/steamtest/` (client, runtime, `lse_shim.so`), started by
`/home/player/steamtest/run-steam.sh`.

## In the image: `/usr/bin/steam`

The OGUI Steam plugin launches games with
`steam -gamepadui -steamos3 -steampal -steamdeck ... steam://rungameid/<appid>`. The image now has
that `steam`, which does the five things above. Neither the client nor the runtime ships in the
image, because a root slot is 2 GB and the two unpack to ~560 MB. `steam` downloads them into the
player's home (`/usr/lib/retroforge/steam-bootstrap`).

No version of either is pinned. `/usr/share/retroforge/steam/steam.pin` names Valve's CHANNELS, and
the bootstrap installs whatever Valve publishes on them when it downloads. Every download is still
checked against a sha256 Valve publishes next to it. A fixed version went stale on its own: the
client's package files are replaced on every release, and Valve prunes old runtime snapshots (the
oldest left on 2026-10-15 was 3c.0.20260526).

- **Client** (`client_channel: steamdeck_stable`): only its arm64 binaries
  (`bins_linuxarm64_linuxarm64`, where `steamrtarm64/` comes from), with the file name and sha256
  from the channel's manifest `steam_client_steamdeck_stable_linuxarm64`. They go into
  `~/.local/share/Steam`, only when missing; the client updates itself from there. The bootstrap
  writes the channel to `package/beta` when it installs the client, and when the file is missing,
  and otherwise leaves it alone. The client owns that file and repoints it to match its launch
  flag. `-steamdeck` keeps either `steamdeck_` line, but a line it does not accept gets repointed,
  which costs a ~631 MB client download on the device. That is why the channel is a `steamdeck_`
  line, and never the gated `-deckard` one (`steam.pin` has the details).
- **Runtime** (`runtime_base: https://repo.steampowered.com/steamrt3c/images`,
  `runtime_channel: latest-public-stable`): on every start, one small GET of
  `<base>/latest-public-stable.txt` (5 s timeout) gives a snapshot id. If that snapshot is not
  installed, its sha256 comes from `<base>/<id>/SHA256SUMS`, and
  `<base>/<id>/steam-runtime-steamrt-arm64.tar.xz` (~52 MB) is downloaded, checked and unpacked to
  `~/.local/share/retroforge/steam-runtime/<id>/` before Steam starts. The older snapshot is
  removed after that, unless a running Steam still holds it (the wrapper keeps a shared `flock` on
  its snapshot's folder); then a later start removes it. Offline, or when the update fails, the
  newest installed snapshot is used and one line says so; with none installed, `steam` exits 1.
  `RETROFORGE_STEAM_RUNTIME_SNAPSHOT=<id>`, or `runtime_snapshot:` in the pin, pins one snapshot.

Measured on 2026-10-16: `steam_client_steamdeck_stable_linuxarm64` and Valve's default line
`steam_client_linuxarm64` (which the bootstrap read before) both serve build 1791918634
(`steamdeck_publicbeta`: 1792192922). `latest-public-stable` and
`latest-steam-client-general-availability` both point at runtime 3c.0.20260824.257593.

Valve's manifest has no arm64 bootstrapper: its one `IsBootstrapperPackage`, `steam_linuxarm64`,
holds the i386 `ubuntu12_32/steam`. That is why the bootstrap starts from the binaries package.

The channel bootstrap against Valve's servers, as a non-root user in a linux/arm64 container on
2026-10-16: on a fresh home it resolved `latest-public-stable` to 3c.0.20260824.257593, checked
the tarball against that snapshot's SHA256SUMS and the client zip against the `steamdeck_stable`
manifest, installed both (runtime 222 MB, client 325 MB) and wrote `package/beta` =
`steamdeck_stable`, in 6 s. The next start, with the channel unchanged, took 160 ms and said
nothing. It left a repointed `package/beta` alone. With Valve unreachable it started with the
installed snapshot and logged one line.

Checked in a linux/arm64 container on 2026-10-15, before the channel pins:
- The bootstrap took 9 s.
- In the runtime's container, `steam` and `steamclient.so` resolve every library.
- The client then updated itself headless: a 667 MB download, ~3 GB on disk, because the
  linuxarm64 manifest also carries the x86 client and runtimes. It stopped at "Unable to open
  X11 display".
- On the second start it verified every executable checksum and found nothing to update.

Not yet seen: the client signed in, a game launched by OGUI, the 42 restart from a real client,
anything on hardware. Nor, here, the client's self-update after the channel bootstrap: that
`-steamdeck` keeps `package/beta` on `steamdeck_stable` was measured upstream, not on this tree. A
real move of `latest-public-stable` has only been exercised with file:// stand-ins
(tests/test-steam.sh).

## steamcmd

The OGUI Steam plugin uses `steamcmd` for the library, installs and updates, not the client. Valve
publishes an arm64 build next to the x86 one (update manifest `steam_cmd_linuxarm64`, installer
`steamcmd_linuxarm64.tar.gz`). The plugin runs `~/.steam/steamcmd/steamcmd.sh`, and only when that
file is missing does it download the x86 one there. Like the client, steamcmd is downloaded on
demand, not shipped:

- **Before the shell starts**, `retroforge-session` runs `/usr/lib/retroforge/install-steamcmd`. It
  puts a stub (`/usr/lib/retroforge/steamcmd-stub`) at `~/.steam/steamcmd/steamcmd.sh`, which stops
  the plugin's x86 download. It writes nothing when the stub or a working arm64 copy is already
  there. It replaces an x86 copy, a half-written copy and a stub from an older image, and leaves the
  rest of the folder alone.
- **The first time the plugin runs steamcmd**, the stub has `/usr/lib/retroforge/steamcmd-fetch`
  download whatever Valve publishes at that moment into a temporary folder inside its own (see
  below). It renames the files into place with Valve's `steamcmd.sh` last, so Valve's script
  replaces the stub, then execs it with the plugin's arguments. steamcmd then downloads the rest of
  itself there and restarts, as on x86. Copies that start at the same time share one download
  (flock on the folder).
- **Offline, or on a download that fails a check**, the stub says why on stderr, exits 1 and stays
  in place. The plugin starts steamcmd once per start of the shell, so the next start tries again.
  Players who already have steamcmd are not affected.

`/usr/share/retroforge/steam/steamcmd.pin` pins a channel, not a file: every first run resolves what
Valve publishes at that moment, so a new steamcmd release needs no bump. What Valve publishes
(checked 2026-10-16, manifest version 1791918946):

- The manifest lists four packages. The one marked `IsBootstrapperPackage`, `steamcmd_linuxarm64`,
  is a 3.7 MB zip holding `linuxarm64/steamcmd` alone (stored 0666, no execute bit). Run on its own,
  that binary downloads the rest from the same manifest (`steamcmd_bins_linuxarm64`:
  `steamclient.so`, `crashhandler.so`, `steamerrorreporter` and more, plus `public/` and
  `siteserverui/`, 23.5 MB). It then exits 42 for its launcher to start it again.
- That launcher, `steamcmd.sh`, is in no manifest package, arm64 or x86, and steamcmd never writes
  it. It is only in the installer tarball, at an unversioned URL Valve replaces in place. The
  tarball's binaries lag the manifest: on 2026-10-16 it still held the 2026-07-27 build. So the
  tarball cannot be checked against the manifest. The x86 tarball has not changed since 2018.

So the helper takes each piece from where it is published and checks it against something that
vouches for it:

- **Binary:** the manifest is read fresh at every first run, and the bootstrapper zip it names is
  refused unless its sha256 is the manifest's `sha2`. The trust anchor is the manifest, read over
  HTTPS from Valve's update host; the helper cannot check its `kvsignatures` without Valve's key.
  The zip is unpacked like the client's: `\` read as a separator, execute bits on ELF files and
  scripts, no path out of the folder.
- **Launcher:** `steamcmd.sh` alone is taken from the installer tarball, and only if its own sha256
  is the pin's `script_sha256`. The tarball's binaries are never used, so Valve republishing it with
  new binaries changes nothing. If the bootstrapper zip ever carries a `steamcmd.sh`, that one is
  used (the manifest vouches for it) and the tarball is not downloaded.
- **Shape:** `linuxarm64/steamcmd` must be an arm64 ELF, and `steamcmd.sh` must pick `linuxarm64`
  and must not be the stub.

The one fixed value left is `script_sha256`, the 2.5 kB launcher. If Valve edits it, a player who
has not run steamcmd yet gets "Valve's steamcmd.sh has changed" and no steamcmd until the pin is
bumped and shipped. For a reproducible install, the pin also takes `fixed_file` + `fixed_sha256`,
one package file, instead of the manifest. They are commented out, because nothing says how long
Valve keeps an old package file.

Against Valve's servers on 2026-10-16, as a non-root player in a pty (linux/arm64 container): the
stub resolved manifest version 1791918946, downloaded and checked the zip and the launcher, became
Valve's `steamcmd.sh`, and steamcmd updated itself (23.5 MB), restarted, and reached "Loading Steam
API...OK" in 6 s. The next `install-steamcmd` left that copy alone. With the update host
unreachable, the stub exited 1 and stayed in place, and the next start succeeded.

It is built like the client: ~300 unguarded LSE atomics in the bootstrapper alone, so the same
`0025` applies.

## Open

- Boot the kernel with 0025 and drop the shim (0025 also removes the shim's one weakness: no
  signal is involved, so a thread's signal mask cannot matter).
- On the Adreno 610, Steam's idle sign-in screen alone kept the GPU ~80% busy (its CEF GPU
  thread 49%, webhelper 13%, compositor 8%, Xwayland 6%): the background animates. To measure
  after sign-in.
- One `steamwebhelper` child segfaulted once at startup (Chromium restarted it).
- Integration: who owns the Guide button when OGUI launches Steam -- with Big Picture in front,
  Steam's input takes the quick-bar chord.
- Whether the client finds games `steamcmd` installed (the plugin sets no install folder), and
  whether `steamcmd` and the client can stay signed in to the same account at once.
- x86 games need FEX, which is a separate question on ARMv8.0.
