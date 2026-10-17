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

## x86 games: the FEX guest

Valve's arm64 client runs x86 games, and x86 Protons, through its FEX tool (Steam app 3127680,
which Steam downloads itself). That tool needs an x86_64 + i386 **graphics provider**: a tree with
`ld.so`, glibc and x86 Mesa (Turnip), with `graphics_provider.json` at its root. SteamOS ships one
at `/usr/share/guestos/fex-mesa` (Valve's `deckard-mesa-linux-x86_64`). We can't: a root slot is
2 GB, and `rootfs/guard-rootfs.sh` section 9 keeps `usr/share/guestos` and FEX out of the image. The
tool also honours `STEAM_COMPAT_GRAPHICS_PROVIDER=/abs/path/graphics_provider.json`, and the
parent directory then becomes both pressure-vessel's graphics provider and FEX's RootFS. Symlinks
from that tree into another one reportedly do not work, so it has to be a real tree.

**The guest:** FEX's own ArchLinux RootFS. `/usr/share/retroforge/steam/x86-guest.pin` pins a
**channel**, not a version: FEX's `https://rootfs.fex-emu.gg/RootFS_links.json` (the file
`FEXRootFSFetcher` reads) and the entry with `DistroMatch: arch` and `Type: squashfs`, "ArchLinux
(SquashFS)". FEX lists one entry per rolling distro and type, its newest, so the device takes
whatever FEX publishes there now. Two matching entries are refused rather than guessed between.

Each entry has a `URL` (a dated directory, `.../ArchLinux/2026-08-11/ArchLinux.sqsh`) and a `Hash`.
That hash is FEX's XXH3-64 (`XXH3_64bits`, seed 0), in hex without leading zeros, not a sha256. The
image checks it with `xxhsum -H3`, from the `xxhash` package (`rsync` already pulls it in; it is in
`PKGS` so the check does not depend on that). XXH3 is not a cryptographic hash: it catches a broken
or wrong download, and the trust is in reading the links file over HTTPS from rootfs.fex-emu.gg. So
an entry has to name an https URL (or one with the channel's own scheme, which the tests use).

What FEX published on 2026-10-16, checked by hand: `2026-08-11/ArchLinux.sqsh`, Hash
`23350f949fc1413d`, 1,359,826,944 bytes. The image's own `xxhsum` (xxhash 0.8.3-1, the package
`rootfs/manifest.lock` names) gives `XXH3_23350f949fc1413d` for it. With `unsquashfs`:
- It is squashfs 4.0, zstd.
- `graphics_provider.json` is at its root: x86_64 from `/usr/lib`, i386 from `/usr/lib32`.
- `freedreno_icd.x86_64.json` and `freedreno_icd.i686.json` point at
  `/usr/lib{,32}/libvulkan_freedreno.so`, Mesa 26.2.0.
- Both arches have glibc and `ld.so`.

A later image FEX publishes is used without that check, so x86 games keep working only as long as FEX
keeps those paths. The pin also takes a **fixed** image (`version`, `url`, `sha256` instead of
`channel`, `distro`, `type`), for an image of our own: then the sha256 is checked, and a new version
downloads when the pin changes.

The squashfs is the smaller build (the EroFS one is ~2.18 GB), and the image already ships
squashfuse. Thunks stay off, as Steam leaves them (`ThunksDB_GL:0,ThunksDB_Vulkan:0`).

**How it gets there** (`/usr/lib/retroforge/steam-x86-guest`, separate from `steam-bootstrap`). No
`steam` waits for the network:
- `steam` runs `steam-x86-guest start $$` before the client. That mounts what is installed and
  starts `fetch` detached in its own session, logging to steam's stderr, and returns at once. With a
  channel it does this at every start; with a fixed pin only while its image is missing.
- `fetch` reads the links file (one ~5 kB GET, 15 s at most) and picks the entry. When that image is
  not there yet, it downloads it to `~/.local/share/retroforge/fex-guest/.<name>-<version>.sqsh.part`,
  resuming a cut-off download with a Range request. It checks the XXH3 (or a fixed pin's sha256) and
  renames the file to `<name>-<version>.sqsh`. For a channel the version is the dated directory and
  the hash: `fex-rootfs-archlinux-2026-08-11-23350f949fc1413d.sqsh`.
- Only then does `fex-guest/current` point at it. Until then the image `current` names is the one
  mounted, so a channel move never leaves Steam without a guest.
- An older image is removed once it is neither current nor mounted: right away, or when the last
  `steam` that has it mounted exits.
- Offline, or a links file that is not JSON, has no such entry, or has two: `fetch` exits 1, logs
  it, and changes nothing. A hash mismatch removes the download. Without `xxhsum` nothing is
  installed; the download is kept and checked at the next start.
- Only one fetch runs at a time, and it refuses to start without ~1.6 GB free.

**The mount.** squashfuse mounts the image on `~/.local/share/retroforge/fex-guest/root`, as the
player. `steam` always exports `STEAM_COMPAT_GRAPHICS_PROVIDER=<that>/graphics_provider.json`,
because the client's environment is fixed when it starts.
- **Mounted** by `start` when an image is there and nothing is mounted yet: a fixed pin's own image,
  else the current one. A mount is never made twice. A dead one (squashfuse killed: `ENOTCONN`) is
  released and replaced. `fex-guest/.mounted` records which image it is.
- **Download finishes while Steam runs:** it is mounted right then, so the next game has it. If an
  older image is already mounted for a running game, it is left alone, and the first start after
  the last `steam` exits mounts the new one.
- **Released** when the last `steam` exits. `start` leaves a holder process outside steam's process
  tree, so OGUI's Exit cannot reap it, with TERM, INT and HUP ignored. It holds
  `fex-guest/.users.lock` shared, watches steam's PID through a pidfd, and when that PID is gone
  (SIGKILL included) it lets go and unmounts with `fusermount3 -u -z`. It skips the unmount if
  another steam still holds the lock. The client does not inherit the lock, so its leftover
  children cannot keep the mount. Mounting, unmounting and removing images run under
  `fex-guest/.mount.lock`.
- squashfuse starts with TERM and INT ignored, like PortMaster's runtimes.

`steam` also links `~/.steam/sdk64` to `<Steam root>/linux64` and `~/.steam/sdk32` to
`<Steam root>/linux32`, which Proton under FEX needs (omarchy-pkgs issue 973).
`RETROFORGE_STEAM_X86_GUEST=0` turns the guest off: no download, no mount, no
`STEAM_COMPAT_GRAPHICS_PROVIDER`. The links are still made. The guest costs 1.36 GB in /home, on
top of the client's ~3 GB.

Checked on 2026-10-16:
- `tests/test-steam-x86-guest.sh`, with stub squashfuse and fusermount3, a local HTTP server and
  links files shaped like FEX's (over HTTP and `file://`): 100/100. It covers the channel picking
  its one entry, a move while Steam runs and with nothing mounted, a wrong XXH3, a hash without
  leading zeros, offline, nine kinds of bad links file, no `xxhsum`, and the fixed pin.
- In a linux/arm64 container, the helper with the real pin read the live `RootFS_links.json`,
  picked `ArchLinux/2026-08-11/ArchLinux.sqsh` and `23350f949fc1413d`, took the real image left as
  its part (FEX's server answered the Range request with 416), checked it with the image's own
  `xxhsum` and installed it. With one byte changed, it was refused and removed.
- With real FUSE, as a non-root player, a channel move from a small image to the real one served
  locally: the old image stayed mounted while the fake `steam` ran, was removed after it was
  SIGKILLed, and the next start mounted the real tree (ICDs, `libvulkan_freedreno.so` and `ld.so`
  for both arches readable).
- In a linux/arm64 container with `/dev/fuse` (Debian's squashfuse 0.5.2 and fuse3 3.17.2; the
  image ships 0.6.1), as a non-root player, with the real helper and wrapper:
  - `fetch` took the real image from a local server and matched the then-fixed pin's sha256
    (`5d0c1a38...5f5f2a`).
  - squashfuse mounted it, and `graphics_provider.json`, both ICDs, both `libvulkan_freedreno.so`
    and both `ld.so` were readable.
  - In Valve's arm64 Steam Runtime (`run --`, pressure-vessel, "Steam Runtime 3c"), the FUSE mount
    under `$HOME` was there and `$STEAM_COMPAT_GRAPHICS_PROVIDER` was readable.
  - The mount was released after `steam` exited normally, after a second `steam` (which neither
    mounted again nor released), after `steam` was SIGKILLed, and after a TERM to every process of
    the launch. A killed squashfuse's dead mount was replaced at the next start.

Not yet seen: the FEX tool using this provider, an x86 game or Proton running, anything on
hardware, and FEX on ARMv8.0.

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
