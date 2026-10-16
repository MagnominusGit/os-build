#!/usr/bin/env bash
# Point the builder container's pacman at one Arch Linux Archive date, with multilib, and move
# every installed package to it. Run inside the ./builder.pin image by container-build.sh and
# container-compose.sh, so the two see the same package generation.
#
#   pacman-snapshot.sh 2026/08/11
set -euo pipefail
SNAPSHOT="${1:?usage: pacman-snapshot.sh <YYYY/MM/DD>}"

echo "Server=https://archive.archlinux.org/repos/${SNAPSHOT}/\$repo/os/\$arch" >/etc/pacman.d/mirrorlist
grep -q '^\[multilib\]' /etc/pacman.conf || printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' >>/etc/pacman.conf

# pacman 7.1 drops to the `alpm` user under seccomp + landlock to download. Neither works in a
# container under amd64 emulation ("error restricting syscalls via seccomp: 22", then "switching
# to sandbox user 'alpm' failed"), and the container is thrown away after one build anyway.
sed -i -e 's/^#\?DisableSandboxFilesystem$/DisableSandboxFilesystem/' \
       -e 's/^#\?DisableSandboxSyscalls$/DisableSandboxSyscalls/' \
       -e 's/^DownloadUser/#DownloadUser/' /etc/pacman.conf
grep -q '^DisableSandboxSyscalls$' /etc/pacman.conf || sed -i '/^\[options\]/a DisableSandboxSyscalls' /etc/pacman.conf
grep -q '^DisableSandboxFilesystem$' /etc/pacman.conf || sed -i '/^\[options\]/a DisableSandboxFilesystem' /etc/pacman.conf

# -uu: the image predates the snapshot by a day or two, and the snapshot wins in both directions.
pacman -Syyuu --noconfirm
