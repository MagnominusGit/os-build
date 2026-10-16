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

The OGUI Steam plugin launches games with `steam -gamepadui ... steam://rungameid/<appid>`. The
image now has that `steam`, which does the five things above. Neither the client nor the runtime
ships in the image, because a root slot is 2 GB and the two unpack to ~560 MB. The first `steam`
downloads them into the player's home (`/usr/lib/retroforge/steam-bootstrap`):

- **Runtime:** pinned in `/usr/share/retroforge/steam/runtime.pin` to Valve's versioned image
  directory, sha256-checked, unpacked to `~/.local/share/retroforge/steam-runtime/<version>/`.
- **Client:** only its arm64 binaries (`bins_linuxarm64_linuxarm64`, where `steamrtarm64/` comes
  from). Its file name and sha256 come from Valve's current `steam_client_linuxarm64` manifest,
  because a pinned one would stop existing at the next client release. It goes into
  `~/.local/share/Steam`, and the client updates itself from there.

Valve's manifest has no arm64 bootstrapper: its one `IsBootstrapperPackage`, `steam_linuxarm64`,
holds the i386 `ubuntu12_32/steam`. That is why the bootstrap starts from the binaries package.

Checked in a linux/arm64 container on 2026-10-15:
- The bootstrap took 9 s.
- In the runtime's container, `steam` and `steamclient.so` resolve every library.
- The client then updated itself headless: a 667 MB download, ~3 GB on disk, because the
  linuxarm64 manifest also carries the x86 client and runtimes. It stopped at "Unable to open
  X11 display".
- On the second start it verified every executable checksum and found nothing to update.

Not yet seen: the client signed in, a game launched by OGUI, the 42 restart from a real client,
anything on hardware.

## steamcmd

The OGUI Steam plugin uses `steamcmd` for the library, installs and updates, not the client. Valve
publishes an arm64 build next to the x86 one (`steamcmd_linuxarm64.tar.gz`, update manifest
`steam_cmd_linuxarm64`). The plugin runs `~/.steam/steamcmd/steamcmd.sh`, and only when that file
is missing does it download the x86 one there. Like the client, steamcmd is downloaded on demand,
not shipped:

- **Before the shell starts**, `retroforge-session` runs `/usr/lib/retroforge/install-steamcmd`. It
  puts a stub (`/usr/lib/retroforge/steamcmd-stub`) at `~/.steam/steamcmd/steamcmd.sh`, which stops
  the plugin's x86 download. It writes nothing when the stub or a working arm64 copy is already
  there. It replaces an x86 copy, a half-written copy and a stub from an older image, and leaves the
  rest of the folder alone.
- **The first time the plugin runs steamcmd**, the stub downloads the tarball pinned in
  `/usr/share/retroforge/steam/steamcmd.pin` (curl, sha256-checked) into its own folder. It renames
  the files into place with Valve's `steamcmd.sh` last, so Valve's script replaces the stub, then
  execs it with the plugin's arguments. steamcmd then updates itself there, as on x86. Copies that
  start at the same time share one download (flock on the folder).
- **Offline or on a checksum mismatch**, the stub says why on stderr, exits 1 and stays in place.
  The plugin starts steamcmd once per start of the shell, so the next start tries again. The pinned
  URL is unversioned, and Valve replaces the file at that URL in place. A mismatch on a good
  connection therefore means the pin needs a bump. Players who already have steamcmd are not
  affected.

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
