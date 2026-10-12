# Remote access (SSH)

A release image ships the SSH server **on**, but with no host keys baked in and no account that
has a password. Nothing about that grants access: sshd is **key-only**, so a running server with
no authorized key admits nobody. There is no build flag, no baked key, and no default credential
anywhere in the tree. Host keys are generated per-device the first time sshd starts (openssh's own
`sshdgenkeys.service`).

Access is granted at runtime, as a **key only**, to the session user `player` (uid 1000, home
`/home/player`). Delivering that key over the network is the job of a small pairing daemon,
`retroforge-pairingd`.

## Pairing is always on — for now

The design is that a person holding the device turns pairing on with an on-screen switch, and the
daemon runs only while that switch is on. **There is no such switch yet.** The shell that drew it is
gone and its replacement does not have one, so `retroforge-pairingd.service` is enabled at boot
(`60-retroforge-pairingd.preset`, plus a build-time `multi-user.target.wants` symlink as a fallback) and
the daemon is **always on**: **anyone on the same network can register a key** while that is true.
It restarts on failure; a clean `systemctl stop retroforge-pairingd` stops it until the next boot.

When the shell grows a switch, the unit's `[Install]` section and its preset go away again and the
switch starts and stops the daemon. Everything below about what the daemon accepts and what it
grants stays as it is.

## How a user pairs

1. Make sure the device is on the network. The daemon listens on port 32000.
2. From the machine you want to connect *from*:

   Linux / macOS:

   ```sh
   curl -X POST --data-binary @~/.ssh/id_ed25519.pub http://<device>:32000/register
   ```

   Windows — **`curl.exe`, not `curl`**. Windows has shipped real curl in `System32` since
   Windows 10 1803, but in the default Windows PowerShell (5.1) the bare word `curl` is an
   alias for `Invoke-WebRequest`, which takes different arguments and fails with a confusing
   error. Spelling out the `.exe` bypasses the alias. There is no `~`, so use `$env:USERPROFILE`
   (PowerShell) or `%USERPROFILE%` (cmd):

   ```powershell
   curl.exe -X POST --data-binary "@$env:USERPROFILE\.ssh\id_ed25519.pub" http://<device>:32000/register
   ```

   Or with no curl at all, using PowerShell's own client — `-InFile` sends the file's bytes
   unmodified, which is what this needs:

   ```powershell
   Invoke-RestMethod -Method Post -Uri http://<device>:32000/register `
     -InFile "$env:USERPROFILE\.ssh\id_ed25519.pub"
   ```

   Windows has also shipped the OpenSSH client since 1809, so `ssh-keygen` and `ssh` are
   present and the key is in the usual place. If you have no key yet, `ssh-keygen -t ed25519`
   works identically there. CRLF line endings in the key file are handled.

   `<device>` is the device's IP address. While the daemon is running the device also advertises
   itself over mDNS, so `retroforge.local` usually works too — on Windows that resolves natively on
   recent builds, and otherwise needs Bonjour installed, so prefer the address if the name does not
   resolve.
3. The key is appended to `player`'s `authorized_keys`. sshd is already running, so you can
   `ssh player@<device>` immediately — no password, and no need to re-pair. Registering the same
   key again is a no-op.

Third-party pairing GUIs that speak the same protocol work too: the endpoint and the mDNS service
type (`_steamos-devkit._tcp`) are deliberately the ones existing devkit pairing tools already use.
Nothing requires you to install one.

## What the daemon is, and what it is protecting

Pairing and sshd are separate, and that split is the whole security model:

- **sshd is safe to leave on** because it is key-only. With no authorized key it admits nobody;
  after you pair, it admits exactly the machines whose keys were registered. Leaving it on is what
  lets a headless A/B update be verified — the updated slot trial-boots already reachable.
- **The pairing daemon is the sensitive part**, because `POST /register` has to be
  unauthenticated: the whole point is to accept a key from someone who has no credential yet. The
  intended credential is physical presence — a hand on the device, turning pairing on. Until that
  switch exists the daemon is always listening, so treat a device on an untrusted network as
  pairable by anyone on it.

There is **no time window**, by design. An earlier design closed the port after five minutes; it was
dropped because a switch and a window can disagree (the UI shows "on" after the window has silently
closed). Accepting keys for exactly as long as the daemon runs is simpler and truthful, and is the
behaviour a future switch will inherit.

A submitted line is rejected unless it is exactly one public key of an allowed type that
`ssh-keygen` can fingerprint. In particular a line that begins with `authorized_keys` options
(`command=`, `permitopen=`, `environment=`) is refused — otherwise a registration could install
a forced command rather than a login. The daemon never sets a password and never touches root's
`authorized_keys`.

It runs as root because it writes another account's `authorized_keys`; that one file is the only
privilege it needs (sshd ships enabled, so it starts nothing).

## What persists across an update

- **The key.** `/home` is its own partition and the RAUC handler copies `/var` only, so
  `/home/player/.ssh/authorized_keys` is untouched by a bundle install or an A/B switch.
- **sshd being on.** It ships enabled for every build, and its per-device host keys live in the
  `/etc` overlay upper (in the per-slot `/var`), which `usr/lib/rauc/post-install.sh` copies A→B —
  so the host key does not change across an update and clients do not see a false MITM.

Together those mean a release bundle installed into the inactive slot **trial-boots with SSH
already reachable by an already-paired machine** — which is what makes a headless release update
verifiable on a board with no serial console.

Use `player`, not `root`: `/root` is on the read-only root filesystem and does not survive the
slot write, so a key placed there is gone after the first update.

## The mDNS advertisement

- mDNS advertising is non-fatal on both halves. (It shipped once as a fatal `ExecStartPre` writing
  into `/etc` under `ProtectSystem=full`, which mounts `/etc` read-only; the write failed `EROFS`
  and took the whole daemon down with it. `tests/test-pairingd.sh` pins that it stays non-fatal.)
- **The advert is published by systemd-resolved, not avahi.** resolved already answers mDNS on
  this image — it is what resolves `retroforge.local`, since `nsswitch.conf` carries no
  `mdns_minimal` and `nss-mdns` is not installed — so avahi existed to publish this one service
  and put a *second* responder on 5353. The daemon registers on the `org.freedesktop.resolve1` bus
  once its socket is bound, and the unit's `ExecStopPost` withdraws it. Two things about that were
  measured on a Pocket ACE (systemd 258) rather than assumed, and both are load-bearing:
  - the registration is **not** tied to the caller's bus connection. The daemon exiting without
    unregistering leaves the advert live, which is why withdrawal is an `ExecStopPost` (it runs
    however the daemon ends) and not a `finally` in the daemon.
  - a `.dnssd` file removed from `/etc/systemd/dnssd` plus `systemctl reload systemd-resolved`
    does **not** retract the advert — only a resolved restart does. So the file mechanism cannot
    express "stop advertising now", which is exactly what a pairing switch needs.

  The withdrawal path is fixed by `DNSSD_SERVICE_ID` in the daemon (resolved escapes
  `retroforge-pairing` to `retroforge_2dpairing`); change one and you must change the other.

  Known limit: the registration lives in resolved's memory, so restarting `systemd-resolved`
  while the daemon runs drops the advert until the daemon is restarted. The advert is a
  convenience, never the mechanism; pairing by address is unaffected.

## Not done yet: an on-screen approval prompt

A confirmation drawn on the device ("Approve this pairing?") would restore "a human is standing
here **now**" as the guarantee, on top of a switch. It belongs to the shell, and it must be gated on
something a running game cannot supply — any token readable by `player`-uid processes is readable by
every game, so a prompt gated only by one would be forgeable.
