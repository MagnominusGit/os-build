#!/usr/bin/env bash
# hw-test.sh — try the Electron store sign-in on a device, without building an image.
#
#   hw-test.sh push <ip>    stage Electron, the libraries it needs that the image lacks, the app and
#                           two OGUI library entries ("Store sign-in test (GOG|Epic)") on root@<ip>
#   hw-test.sh push-chromium <ip>  add the real Chromium (app mode, chromium-signin.py) beside it, and
#                           two more entries ("Store sign-in test (GOG|Epic, Chromium)")
#   hw-test.sh logs <ip>    print the device's gog.log and epic.log
#   hw-test.sh clean <ip>   remove all of it from the device
#   hw-test.sh stage        only stage it here (~/.cache/retroforge-store-signin-test/stage)
#
# Electron is the official linux-arm64 build, checked against its release's SHASUMS256.txt. The
# libraries are the packages of the image's pinned snapshot (rootfs/manifest.lock) that Electron's
# NEEDED list pulls in and the image does not have, checked against the snapshot's sha256, unpacked
# into lib/ and found through LD_LIBRARY_PATH (run.sh). Nothing outside the player's home changes.
set -euo pipefail

ELECTRON=v45.1.0
ELECTRON_SHA256=64b78d93d1129ab805cdc0f2710f446716afbe814a1d08e639dab3175d2285a1
# What `readelf -d electron` NEEDS beyond libc. Of these the image lacks only GTK3 and what it pulls
# in (2026-10-28: 12 packages, 13 MiB of libraries); the closure skips what the image has.
ROOTS=(gtk3 nss libcups alsa-lib libxcomposite libxdamage libxrandr)
DEST=/home/player/.local/share/retroforge/store-signin-test
APPS=/home/player/.local/share/applications

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
cache="${XDG_CACHE_HOME:-$HOME/.cache}/retroforge-store-signin-test"
cmd="${1:-}" ip="${2:-}"
[ "$cmd" = stage ] || [ -n "$ip" ] || { sed -n '3,9p' "$0"; exit 2; }
dev="root@$ip"
# A dev card takes the checkout's throwaway key (dev.env); SSH_KEY= for another.
key="${SSH_KEY:-$repo/work/dev-ssh/id_ed25519}"
ssh() { if [ -f "$key" ]; then command ssh -i "$key" -o BatchMode=yes -o UserKnownHostsFile="$repo/work/dev-ssh/known_hosts" -o StrictHostKeyChecking=accept-new "$@"; else command ssh "$@"; fi; }

stage_electron() {  # $cache/stage/electron
  local zip="$cache/electron-$ELECTRON-linux-arm64.zip"
  if [ ! -f "$zip" ]; then
    curl -fL --retry 3 -o "$zip.part" \
      "https://github.com/electron/electron/releases/download/$ELECTRON/electron-$ELECTRON-linux-arm64.zip"
    mv "$zip.part" "$zip"
  fi
  echo "$ELECTRON_SHA256  $zip" | sha256sum -c --quiet
  rm -rf "$cache/stage/electron"; mkdir -p "$cache/stage/electron"
  bsdtar -xf "$zip" -C "$cache/stage/electron"
}

stage_libs() {  # $cache/stage/lib: the snapshot packages Electron needs beyond the image
  local snapshot list
  snapshot="$(sed -n 's/^# repo snapshot: *//p' "$repo/rootfs/manifest.lock")"
  [ -n "$snapshot" ] || { echo "no snapshot in rootfs/manifest.lock" >&2; exit 1; }
  mkdir -p "$cache/db"
  for r in core extra; do
    [ -s "$cache/db/$r.db" ] || curl -fsL -o "$cache/db/$r.db" "$snapshot/$r/os/aarch64/$r.db"
    rm -rf "$cache/db/$r"; mkdir -p "$cache/db/$r"; tar -xf "$cache/db/$r.db" -C "$cache/db/$r"
  done
  # repo filename sha256, one line per package, for the closure of ROOTS minus the image's packages.
  list="$(python3 -I - "$cache/db" "$repo/rootfs/manifest.lock" "${ROOTS[@]}" <<'EOF'
import os, re, sys
db, lock, roots = sys.argv[1], sys.argv[2], sys.argv[3:]
pk, prov = {}, {}
for repo in ("core", "extra"):
    for entry in os.listdir(os.path.join(db, repo)):
        f, key = {}, None
        for line in open(os.path.join(db, repo, entry, "desc")).read().splitlines():
            if line.startswith("%"):
                key = line.strip("%"); f[key] = []
            elif line:
                f[key].append(line)
        f["REPO"] = repo
        pk[f["NAME"][0]] = f
        for p in f.get("PROVIDES", []) + f["NAME"]:
            prov.setdefault(re.split("[<>=]", p)[0], f["NAME"][0])
have = {l.split()[0] for l in open(lock) if l.strip() and not l.startswith("#")}
have |= {re.split("[<>=]", p)[0] for h in have if h in pk for p in pk[h].get("PROVIDES", [])}
seen, todo = set(), list(roots)
while todo:
    dep = re.split("[<>=]", todo.pop())[0]
    name = prov.get(dep)
    if dep in have or not name or name in have or name in seen:
        continue
    seen.add(name)
    todo += pk[name].get("DEPENDS", [])
for name in sorted(seen):
    print(pk[name]["REPO"], pk[name]["FILENAME"][0], pk[name]["SHA256SUM"][0])
EOF
)"
  rm -rf "$cache/stage/lib" "$cache/pkg-x"; mkdir -p "$cache/stage/lib" "$cache/pkgs"
  while read -r r file sum; do
    [ -f "$cache/pkgs/$file" ] || curl -fsL -o "$cache/pkgs/$file" "$snapshot/$r/os/aarch64/$file"
    echo "$sum  $cache/pkgs/$file" | sha256sum -c --quiet
    mkdir -p "$cache/pkg-x"
    bsdtar -xf "$cache/pkgs/$file" -C "$cache/pkg-x" usr/lib usr/share/glib-2.0/schemas 2>/dev/null || true
    echo "  $file" >&2
  done <<<"$list"
  find "$cache/pkg-x/usr/lib" -maxdepth 1 -name '*.so*' -exec cp -a {} "$cache/stage/lib/" \;
  # Chromium's own folder (binary, .pak resources, locales), when it is among the packages.
  if [ -d "$cache/pkg-x/usr/lib/chromium" ]; then
    rm -rf "$cache/stage/chromium"; cp -a "$cache/pkg-x/usr/lib/chromium" "$cache/stage/chromium"
  fi
  # GTK's settings schemas (GTK aborts when it asks for one that is not installed), compiled here:
  # gschemas.compiled is the same on every architecture.
  rm -rf "$cache/stage/schemas"; mkdir -p "$cache/stage/schemas"
  cp "$cache/pkg-x/usr/share/glib-2.0/schemas/"*.xml "$cache/stage/schemas/" 2>/dev/null || true
  glib-compile-schemas "$cache/stage/schemas"
  rm -rf "$cache/pkg-x"
}

desktop() {  # desktop <store> <title> [nogpu]: an OGUI library entry (its desktop library wants Categories=Game)
  printf '[Desktop Entry]\nType=Application\nName=Store sign-in test (%s)\nExec=%s/run.sh %s %s\nCategories=Game;\n' \
    "$2" "$DEST" "$1" "${3:-}"
}

stage() {
    mkdir -p "$cache"
    echo "Electron $ELECTRON..."; stage_electron
    echo "Libraries from the image's snapshot:"; stage_libs
    rm -rf "$cache/stage/app"; mkdir -p "$cache/stage/app"
    cp "$here/../main.js" "$here/../package.json" "$cache/stage/app/"
    cp "$here/run.sh" "$cache/stage/"; chmod +x "$cache/stage/run.sh"
}

case "$cmd" in
  stage) stage; echo "Staged: $(du -sh "$cache/stage" | cut -f1) in $cache/stage" ;;
  push)
    stage
    echo "Copying $(du -sh "$cache/stage" | cut -f1) to $dev:$DEST..."
    # As the player: a folder root makes on the way (.local/share/retroforge) would lock the store out.
    ssh "$dev" "rm -rf $DEST && runuser -u player -- mkdir -p $DEST $APPS"
    tar -C "$cache/stage" -cf - . | gzip -1 | ssh "$dev" "gzip -d | tar -xf - -C $DEST"
    desktop gog GOG | ssh "$dev" "cat > $APPS/store-signin-gog.desktop"
    desktop epic Epic | ssh "$dev" "cat > $APPS/store-signin-epic.desktop"
    desktop gog "GOG, no GPU" nogpu | ssh "$dev" "cat > $APPS/store-signin-gog-nogpu.desktop"
    desktop epic "Epic, no GPU" nogpu | ssh "$dev" "cat > $APPS/store-signin-epic-nogpu.desktop"
    ssh "$dev" "chown -R player:player $DEST $APPS"
    echo "Store tools (legendary, gogdl) for the exchange, as the player:"
    ssh "$dev" "for s in gog epic; do runuser -l player -c \"/usr/lib/retroforge/store \$s setup\" | tail -1; done"
    echo "Libraries Electron still cannot find on the device (should be none):"
    ssh "$dev" "LD_LIBRARY_PATH=$DEST/lib ldd $DEST/electron/electron | grep 'not found' || echo '  none'"
    echo "Done. The two entries show in OGUI's library once it reloads it (restart the session if not)."
    ;;
  push-chromium)
    # Chromium's closure includes GTK3, so lib/ is a superset of Electron's.
    ROOTS=(chromium)
    mkdir -p "$cache"
    echo "Chromium and its libraries from the image's snapshot:"; stage_libs
    cp "$here/../chromium-signin.py" "$here/run.sh" "$cache/stage/"; chmod +x "$cache/stage/run.sh"
    echo "Copying Chromium ($(du -sh "$cache/stage/chromium" | cut -f1)) to $dev:$DEST..."
    tar -C "$cache/stage" -cf - chromium lib schemas chromium-signin.py run.sh | gzip -1 \
      | ssh "$dev" "rm -rf $DEST/chromium && gzip -d | tar -xf - -C $DEST && chown -R player:player $DEST"
    desktop gog "GOG, Chromium" chromium | ssh "$dev" "cat > $APPS/store-signin-gog-chromium.desktop"
    desktop epic "Epic, Chromium" chromium | ssh "$dev" "cat > $APPS/store-signin-epic-chromium.desktop"
    ssh "$dev" "chown player:player $APPS/store-signin-*-chromium.desktop"
    echo "Libraries Chromium still cannot find on the device (should be none):"
    ssh "$dev" "LD_LIBRARY_PATH=$DEST/lib ldd $DEST/chromium/chromium | grep 'not found' || echo '  none'"
    echo "Done. Restart the session for OGUI to list the two new entries."
    ;;
  logs)
    ssh "$dev" "for f in $DEST/gog.log $DEST/epic.log; do echo \"## \$f\"; cat \"\$f\" 2>/dev/null || echo '(none yet)'; done"
    ;;
  clean)
    ssh "$dev" "rm -rf $DEST $APPS/store-signin-gog.desktop $APPS/store-signin-epic.desktop $APPS/store-signin-*-nogpu.desktop $APPS/store-signin-*-chromium.desktop"
    ;;
  *) sed -n '3,9p' "$0"; exit 2 ;;
esac
