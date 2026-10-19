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

1. **A few host libraries, and no runtime container.** `steamui.so` links GTK2
   (`libgtk-x11-2.0`), `steamwebhelper` links `libibus-1.0` and does not load without it, and the
   client maps each localhost connection to a process with `lsof`, rejecting its own UI's
   websocket when it cannot ("Unexpected Transport Error", no UI). The image has all three
   (`rootfs/customize-base.sh`), and `steam` runs `steamrtarm64/steam` raw on the host from
   `steamrtarm64/`, with `steamrtarm64` and `steamrtarm64/video` (the client's own libav* and
   libvpx) first on `LD_LIBRARY_PATH`, as Nova-Deck runs it. Valve's arm64 Steam Runtime
   container (steamrt3c, `<runtime>/run -- steamrtarm64/steam`) runs the client too, but no game
   starts from it: Steam runs every game in Steam Linux Runtime 4.0's own pressure-vessel
   container, and that does not start nested inside another (`bwrap: execvp true: No such file or
   directory`, Hades on the KONKR Pocket FIT, 2026-10-19). (The manifest's
   `runtime_steamrt_linuxarm64` is the x86_64/i386 runtime for FEX games, not either of these.)
2. **`~/.steam/steam` and `~/.steam/root`** pointing at the client root ("Steam data link does
   not exist, client is misconfigured").
3. **A clean environment for pressure-vessel**, which games run in: a `DBUS_SESSION_BUS_ADDRESS`
   from another user (root's, over SSH) makes bwrap fail on `/run/user/0/bus`.
4. **Something to relaunch it after a self-update.** The client exits after installing an
   update ("Update complete, launching Steam...") and expects its wrapper script to start it again.
5. The client zips use backslash paths; extract with the separators converted.

Test install on the Air X: `/home/player/steamtest/` (client, runtime, `lse_shim.so`), started by
`/home/player/steamtest/run-steam.sh`.

## In the image: `/usr/bin/steam`

The OGUI Steam plugin launches games with
`steam -gamepadui -steamos3 -steampal -steamdeck ... steam://rungameid/<appid>`. The image now has
that `steam`, which does the five things above. The client does not ship in the image, because a
root slot is 2 GB and the client updates itself to ~3 GB. It is installed into the
player's home from the shell's store (next section); `steam` itself downloads nothing for a client
that is not there, and says where to install it.

## Installing: Main menu > Emulators

Steam shows in the shell's Emulators screen as two entries, each with Download and its progress:

- **Steam Client** (`/usr/lib/retroforge/steam-install install client`): the client's arm64
  binaries (`steam-bootstrap --install`), the x86 guest for FEX (`steam-x86-guest
  fetch`, below), then the client's own update by Valve's updater (`steam -steamdeck -exitsteam`
  through the wrapper, with no display), so its first Open starts at once instead of downloading
  ~650 MB with nothing on screen. If that update does not finish, the install still succeeds and
  the client finishes it on its first Open. Installed, the entry offers Open (Steam's UI:
  `steam -gamepadui -steamos3 -steampal -steamdeck steam://open/bigpicture`) and Repair (the
  install again, fetching only what is missing). There is no Steam library card.
- **Steam CLI** (`steam-install install cli`): Valve's arm64 steamcmd for the OGUI Steam plugin
  (next sections): the stub in install mode with `+quit`, so steamcmd also downloads the rest of
  itself during the install.

`retroforge-emu` lists both beside the emulators (`kind: steam`, from `steam-install status`) and
hands their install to `steam-install`, whose `N%` lines and exit statuses are its own. The page
reads the percentage from `~/.cache/retroforge/steam-install-<entry>.progress`. Both update
themselves, so neither has Update, Check, Revert or Delete. Before Steam Client is installed,
`steam` exits 1 with one line pointing at it (the plugin's launches fail there); before Steam CLI
is, the stub does the same for the plugin's steamcmd, and nothing is downloaded behind the player's
back.

No version is pinned. `/usr/share/retroforge/steam/steam.pin` names Valve's client CHANNEL, and
the bootstrap installs whatever Valve publishes on it when it downloads, still checked against the
sha256 Valve publishes next to it. A fixed version went stale on its own: the client's package
files are replaced on every release.

- **Client** (`client_channel: steamdeck_stable`): only its arm64 binaries
  (`bins_linuxarm64_linuxarm64`, where `steamrtarm64/` comes from), with the file name and sha256
  from the channel's manifest `steam_client_steamdeck_stable_linuxarm64`. They go into
  `~/.local/share/Steam`, only when missing; the client updates itself from there. The bootstrap
  writes the channel to `package/beta` when it installs the client, and when the file is missing,
  and otherwise leaves it alone. The client owns that file and repoints it to match its launch
  flag. `-steamdeck` keeps either `steamdeck_` line, but a line it does not accept gets repointed,
  which costs a ~631 MB client download on the device. That is why the channel is a `steamdeck_`
  line, and never the gated `-deckard` one (`steam.pin` has the details).
- **No Steam Runtime.** Earlier builds also downloaded Valve's steamrt3c runtime (~52 MB) to
  `~/.local/share/retroforge/steam-runtime/` and ran the client in it; the bootstrap now removes
  that folder when it finds it.

Measured on 2026-10-16: `steam_client_steamdeck_stable_linuxarm64` and Valve's default line
`steam_client_linuxarm64` (which the bootstrap read before) both serve build 1791918634
(`steamdeck_publicbeta`: 1792192922).

Valve's manifest has no arm64 bootstrapper: its one `IsBootstrapperPackage`, `steam_linuxarm64`,
holds the i386 `ubuntu12_32/steam`. That is why the bootstrap starts from the binaries package.

The channel bootstrap against Valve's servers, when it still installed the runtime too, as a
non-root user in a linux/arm64 container on 2026-10-16: on a fresh home it resolved `latest-public-stable` to 3c.0.20260824.257593, checked
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

On hardware (KONKR Pocket FIT, 2026-10-19), running on the host: Steam Client installed from
Emulators, the client signed in and showed Big Picture, and Hades launched from it, under Proton
11.0 (ARM64) in Steam Linux Runtime 4.0 - Arm64, with Turnip's swapchain on gamescope and the
game's window focused. In the steamrt3c container the same launch had ended at once (`bwrap: execvp
true`).

Not yet seen: the 42 restart from a real client, an x86-only Linux game. Nor, here, that
`-steamdeck` keeps `package/beta` on `steamdeck_stable` through a client update: that was measured
upstream, not on this tree.

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
- **When the player installs Steam CLI** (Main menu > Emulators: `steam-install` runs the stub with
  `RETROFORGE_STEAMCMD_INSTALL=1`), the stub has `/usr/lib/retroforge/steamcmd-fetch`
  download whatever Valve publishes at that moment into a temporary folder inside its own (see
  below). It renames the files into place with Valve's `steamcmd.sh` last, so Valve's script
  replaces the stub, then execs it with `+quit`. steamcmd then downloads the rest of itself there
  and restarts, as on x86. Copies that start at the same time share one download (flock on the
  folder). Run by the plugin before that install, the stub downloads nothing: it says where to
  install Steam CLI and exits 1.
- **Offline, or on a download that fails a check**, the stub says why on stderr, exits 1 and stays
  in place, and the Emulators page reports the failure; Download tries again.
  Players who already have steamcmd are not affected.

`/usr/share/retroforge/steam/steamcmd.pin` pins a channel, not a file: every install resolves what
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

- **Binary:** the manifest is read fresh at every install, and the bootstrapper zip it names is
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

**Our Mesa over it.** FEX's RootFS carries upstream Arch Mesa. The image carries our own, built for
x86_64 and i686 from `packages/mesa`'s pin and patches by `packages/mesa-x86` (Turnip, zink, the
GL front ends, the VRAM layer; `make mesa-x86`, in an x86_64 Arch container locked to the guest's
Arch snapshot), at `/usr/lib/retroforge/x86-mesa/root`, with `payload.conf` naming that snapshot.
It is the image's one x86 payload and nothing on the host runs it. `steam-x86-guest` mounts the
guest on `fex-guest/base` and lays the payload over it with `fuse-overlayfs` on `fex-guest/root`
(lower layers only, so read-only): our files replace the guest's at the same paths, everything else
is the guest's, and `graphics_provider.json` is still the guest's. A guest older than the payload's
snapshot (it could lack the glibc the payload links against) is mounted as it is, and so is any
guest on an image built with `RETROFORGE_X86_MESA=0`.

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
player. `steam` exports `STEAM_COMPAT_GRAPHICS_PROVIDER=<that>/graphics_provider.json` only when
that file is there, i.e. once the guest is mounted. pressure-vessel reads the variable for every
container it starts, and a file that does not exist yet aborts it (`opendir(...): No such file or
directory`): while the client still ran in a container of its own, a client started during the
first download never started (Air X, 2026-10-18). The client's environment is fixed when it starts, so after the first download x86
games get the guest from the next start of Steam; `steam` says so on stderr.
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

## x86 games: the guest and its Mesa

Native x86 Linux games run under FEX, which the arm64 client adds to a game as a dependency. An
emulated x86 process loads only x86 libraries, so Steam needs an x86_64 + i386 **graphics
provider**: a root with `/graphics_provider.json` at the top, the x86 dynamic loaders, glibc and an
x86 Mesa, named by `STEAM_COMPAT_GRAPHICS_PROVIDER`. FEX can forward GL and Vulkan to the arm64
driver ("thunks"), but its `ThunkConfig` defaults to empty, so by default the guest's x86 Mesa is
the driver: x86 Turnip, compiled and run under emulation.

The guest is downloaded, never shipped: `/usr/share/retroforge/steam/x86-guest.pin` names a
squashfs image that the device fetches and mounts under `/home` with squashfuse. It starts out on
FEX's own ArchLinux RootFS (2026-08-11), whose Mesa is FEX's build of upstream 26.2.0, without our
Adreno patches.

`packages/mesa-x86` builds the replacement: the same Mesa tarball and patches as the host driver,
for x86_64 and i686 (Turnip, and GL as zink over it, which is what Valve's own FEX guest Mesa
ships), laid over that same FEX RootFS as `retroforge-fex-guest-<mesa version>-<revision>.sqsh`.
Composing it checks that both arches' ICDs and GL libraries resolve to our build and that every
library we add loads in the guest. `.github/workflows/release-fex-guest.yml` publishes it as a
Release asset (manual dispatch only, tag `fex-guest/v<version>`).

To switch devices to it, set `x86-guest.pin`'s `name`, `version`, `url` and `sha256` to the
published image (the release notes print all four) and ship that in a bundle. One condition first:
the repo is private, and a device cannot download a private repo's Release asset, so the image has
to be publicly reachable (a public repo or releases repo, or a copy in the R2 bucket behind
`ota.retroforge.org`). A Mesa bump in `packages/mesa` carries into the guest with nothing to edit
there; it needs a new dispatch and a pin bump. Details and the bump steps:
[`packages/mesa-x86/README.md`](../packages/mesa-x86/README.md).

Not yet seen: our guest (or FEX's) mounted by a device and driving a game, zink GL on Adreno under
FEX, and whether Valve's tool enables thunks.

## DXVK-Sarek: Proton-CachyOS for the Adreno 610 (downloaded, not shipped)

**Why the A610 needs it (2026-10-16).** Turnip in Mesa 26.2.5 (`packages/mesa`) gives the A610 only
Vulkan 1.0. It reaches 1.3 because `etc/retroforge/session.conf` exports `TU_DEBUG=noconform` on the
SM6115, and that also fakes `multiViewport`. Mesa 26.3 (final ~2026-11-04) removes noconform and keeps
multiViewport off on a6xx_gen1_low (Mesa 82b86896). Every upstream DXVK (1.10.3, 2.x, 3.x) requires
multiViewport, so after that bump DXVK-Sarek is the only DXVK that creates a device on the A610. The
A650 (SM8250) runs Valve's Proton 11 (DXVK 2.7) but not DXVK 3.x (Proton Experimental,
Proton-CachyOS), because it has no `storageBuffer8BitAccess`. The A740 and A750 run anything. So
Sarek is on by default only on the SM6115.

Proton-CachyOS publishes an arm64 build with an ARM64EC DXVK-Sarek (`files/lib/wine/dxvk-sarek/
aarch64-windows/`), turned on by `PROTON_DXVK_SAREK=1`. Its `toolmanifest.vdf` requires tool appid
4185400 (Steam Linux Runtime 4.0, arm64), which Steam downloads itself. Its maintainers call the arm64
build untested. A local ISA scan of `cachyos-11.0-20261005-slr` found nothing beyond ARMv8.0 except
LSE atomics (covered by `0025`), apart from libraries that pick their code path at run time. Its
`proton` also turns Sarek on by itself when the GPU lacks Vulkan 1.3 with `descriptorIndexing`, but
under noconform the A610 reports 1.3, so that check does not pick Sarek today.

**One setting.** `DXVK_SAREK=on|off` in `~/.config/retroforge/steam.conf`, kept by
`/usr/bin/retroforge-steam-sarek`. The player changes it in Settings > General > "Steam: DXVK-Sarek
(low-end GPUs)" (the RetroForge plugin), or with `retroforge-steam-sarek on|off|status` over SSH.
Never set, it is on for SoC class SM6115 (device-env) and off elsewhere. A card moved to another board
follows that board until the player chooses. `RETROFORGE_STEAM_SAREK=on|off` overrides it, for testing.

- **On:** every `steam` start (and turning the toggle on) runs `/usr/lib/retroforge/steam-compat-tools
  on` in the background, as the user unit `retroforge-steam-compat-tools` (with setsid when there is no
  user manager). A user unit is not under OGUI's reaper, which stops everything under a game when the
  game ends, and the first `steam` does not wait for the download. It installs or updates the tool
  (below), with a `user_settings.py` holding `PROTON_DXVK_SAREK=1`, which Proton-CachyOS applies to
  every game run with it, and `/usr/bin/steam` exports `PROTON_DXVK_SAREK=1` as well (Valve's Proton
  ignores it). Log: `~/.local/share/retroforge/steam-compat-tools.log`.
- **Off:** nothing is downloaded, asked or exported. Before the client starts, `steam-compat-tools
  off` deletes that `user_settings.py` from the installed tool, which stays. Turning the toggle off
  also stops a download in progress.

**Which release: a channel.** `/usr/share/retroforge/steam/proton-cachyos-arm64.pin` names a channel,
not a version: the device resolves what is published now. Each `on` makes one request to GitHub's API
(`/repos/CachyOS/proton-cachyos/releases?per_page=20`; 60 an hour are allowed without a token, and there
is at most one per `steam` start, only while the setting is on) and takes the newest release that has
`proton-cachyos-*-slr-arm64.tar.xz` and its `.sha512sum`. Newest means the
highest Proton version, then the latest published: `cachyos-10.0-sunset-slr` was published a week after
`cachyos-11.0-20260601-slr`, and a newest-by-date rule would have moved every player back to 10.0.
Drafts, prereleases and assets still uploading are skipped. The tarball (~356 MB) has to match the
`.sha512sum`, and the sha256 GitHub's API lists for it. Offline, rate-limited, or on any API error or
answer without an arm64 build, the installed release stays (exit 0, and the log says why); on a card
with nothing installed yet, the next `steam` start tries again. A `tag:` in the pin holds one release
instead (reproducible builds, or keeping players off a bad release), optionally with its `sha512:`;
once that release is installed nothing is asked. On 2026-10-16 the channel resolves to
`cachyos-11.0-20261005-slr`.

**One name.** Whatever the release, the tool is
`~/.local/share/Steam/compatibilitytools.d/proton-cachyos-arm64-retroforge/`, and its
`compatibilitytool.vdf` is rewritten so that its internal name is `proton-cachyos-arm64-retroforge` and
its display name "Proton-CachyOS arm64 (RetroForge)" (only those two strings change; the comments,
`install_path`, `from_oslist` and `to_oslist` stay the release's). Steam records a game's tool in
`config.vdf`'s `CompatToolMapping` by that internal name, so a game set to the tool keeps it through
updates.

**Updates.** A new release is downloaded, checked and unpacked (~2.2 GB) under a temporary name in the
Steam root, renamed to the tool's name, and swapped in by two renames (the old tree out, the new one
in), so Steam never sees half a tool. A player's own `user_settings.py` moves into the new tree. A game
running from the old tree would, after the swap, start wine processes and load DLLs from the new one
by path, and wine refuses a wineserver of another build. So while a process of the player's runs from
the tool (its program, its working folder, or a file it maps), the new tree waits, checked, in
`~/.local/share/Steam/.retroforge-compat-tools.next/`, and goes in at the next `steam` start that finds
nothing running from it, without a second download. One withdrawn upstream meanwhile is dropped. A
running Steam reads the new `toolmanifest.vdf` at its next start.

**Using it.** Steam reads `compatibilitytools.d` only when it starts, so restart Steam once the log
says "installed". Then select "Proton-CachyOS arm64 (RetroForge)" per game (Properties >
Compatibility > Force the use of a specific Steam Play compatibility tool), or for every game
(Settings > Compatibility > Default compatibility tool). Nothing edits Steam's `config.vdf`: choosing
the tool is the player's, once. `PROTON_DXVK_SAREK=0 %command%` in a game's launch options turns Sarek
off for that game.

**What it never touches.** Each folder it installs carries `.retroforge-pin` (name, tag, asset, sha512,
sha256). A folder without one is someone else's: other tools, and a Proton-CachyOS the player installed,
even under the tool's name. A `user_settings.py` the player edited is theirs too.

**From the per-release folders.** The first version of this installed each release under its own name
(`compatibilitytools.d/proton-cachyos-11.0-20261005-slr-arm64/`, with a `.retroforge-pin`). Those are
removed once the one-name folder is in place, each when nothing runs from it, and a player's own
`user_settings.py` in one moves into the new folder. A game set to one has to be set to "Proton-CachyOS
arm64 (RetroForge)", once.

**Removing it.** Turn the setting off, then delete
`~/.local/share/Steam/compatibilitytools.d/proton-cachyos-arm64-retroforge/` (and
`~/.local/share/Steam/.retroforge-compat-tools.next/`, if there), and set games that used it back to
another tool. Steam Linux Runtime 4.0 (arm64) can then be uninstalled from Steam's library like any
tool.

Checked in a linux/arm64 container on 2026-10-16: the image's pin against the live API resolved to
`cachyos-11.0-20261005-slr` (sha256 `e59b646e...cd06c37` as GitHub lists it, the live `.sha512sum`
`81ca1b66...b1c0fa`, the same as a local copy's). Through the live API's own JSON, with that release's
two URLs pointed at local copies, `steam-compat-tools on` installed it in 5 s: 2,191 MB, 1,972
symlinks, none broken, `toolmanifest.vdf` the release's (require 4185400), `compatibilitytool.vdf`
renamed as above, `user_settings.py` importing as `{'PROTON_DXVK_SAREK': '1'}`. A second `on` made its
one API request and touched nothing, and `off` then `on` removed and restored `user_settings.py`.
Updates, the wait while a process runs from the tool, and the move from per-release folders are covered
by `tests/test-steam-compat-tools.sh` with small fake releases and a fake API.

Not yet seen:
- Whether the arm64 client lists the tool. Its `compatibilitytool.vdf` says `to_oslist linux`, and
  steamclient.so has "Ignoring tool %s as it's for a different target platform %s.".
- Whether the arm64 client keeps a game's tool across an update under the rewritten name (that Steam
  keys `CompatToolMapping` by the internal name is how it works on x86; not watched on this client).
- Whether a game in Steam Linux Runtime 4.0 (pressure-vessel) shows the tool's path in
  `/proc/<pid>/maps` as the check expects; if not, an update goes in while the game runs.
- Whether the client's environment reaches games: the client runs on the host, games in Steam
  Linux Runtime 4.0. `user_settings.py` covers that either way.
- Steam fetching 4185400 on arm64, a game run with the tool, Sarek on an A610, the plugin toggle on a
  device, anything on hardware. A release after `cachyos-11.0-20261005-slr` is not ISA-scanned before
  players get it.

## Remote Play (the handheld as a client)

Valve's arm64 client has the whole Remote Play client (`steamrtarm64/streaming_client`): a PC's
games show a Stream button in Big Picture, and nothing gates it to the Frame. Its Frame-only
paths (VR streaming, pairing over the Frame's own hotspot, echo cancellation) switch on with
`-steamframe`/`-deckard`, which we never pass. What the image adds:

- **A way in.** Open on Main menu > Emulators > Steam Client (`emulators_page.gd`) starts
  `steam -gamepadui -steamos3 -steampal -steamdeck steam://open/bigpicture`. Not `steam://rungameid/`:
  OGUI treats that as one game and SIGTERMs Steam once only Steam's own windows are left, which would
  end a stream. There is no Steam library card.
- **Controllers.** Valve's `60-steam-input.rules` (steam-devices, verbatim, MIT): uaccess on the
  hidraw nodes of Steam, Sony, Nintendo, 8BitDo and other pads, so Steam Input reads them directly
  and forwards gyro, trackpads and paddles. The handheld's own controls reach Steam as InputPlumber's
  virtual Xbox Elite 2 pad.
- **Hardware decode.** The client decodes H.264/HEVC through its own stateful V4L2 decoder
  (`CV4L2Accel`): it probes `/dev/video-dec0..99` and `/dev/video0..99` for a mem2mem device, so
  Iris (SM8250/8550/8650) and venus (SM6115, `VIDEO_QCOM_VENUS=m`) need no package in the image.
  `70-retroforge-video-codec.rules` links `/dev/video-dec0`/`video-enc0` to the codec by its driver
  name, which the UI's Chromium also looks for. Without a decoder the client falls back to software
  (FFmpeg 8 in `libvideo.so`).
- **Network.** The image has no firewall: discovery (UDP broadcast on 27036) and the stream
  (UDP 27031-27036, TCP 27036-27037) are open. A firewall added later must keep those open.
- **Audio** goes through pipewire-pulse, as for everything else.

Hosting is not offered: the client's encoders are x264, VA-API and NVENC, and Adreno has no VA-API,
so the handheld would encode in software next to the game.

To check on hardware, per board: the Stream button finding a PC over Wi-Fi; the client naming
"V4L2 ... hardware decoding" as its decoder (and no `CV4L2Accel:` errors); a stall after the first
frame (Steam starts both V4L2 queues before any bitstream; if upstream Iris waits on it, try
`STEAMLINK_V4L2_RESET_AFTER_LAST_BUF=1`); the stream window taking focus under OGUI's gamescope; who
gets the Guide button ("Hold GUIDE to control remote session"); software-decode load on the SM6115
at 720p60, its decoder's ceiling with 1080p30.

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
