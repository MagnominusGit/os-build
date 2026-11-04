#!/bin/sh
# retroforge internal install — put the run's log somewhere it can be read.
#
#   save-log.sh      collect the unit's journal and the install record into /var/log/retroforge/install.log
#
# Run by retroforge-installer.service on every stop, just before it reboots into the card. The card
# boots again after a failed install unless the very last write landed, so the log is read on the
# device, or over SSH.
#
# NOT UNDER /home/player. This runs as root, and root writing into a directory `player` owns follows
# any symlink left there, which is overwriting any file on the system. /var/log is root's.
#
# IT NEVER FAILS THE UNIT. Every step is best-effort and the exit status is always 0: a log that
# could not be saved must not turn a successful install into a failed one, and must not mask the
# real failure of a failed one.
set -u

PROG=${0##*/}
log() { printf '[%s] %s\n' "$PROG" "$*" >&2; }

LOGFILE=${RETROFORGE_INSTALL_LOG:-/var/log/retroforge/install.log}
# NetworkManager because the OS is streamed over the network, and a drop mid-stream is the failure
# this log is most likely to be read for. The association and the lease are in its journal, not ours.
UNITS=${RETROFORGE_INSTALL_UNITS:-retroforge-installer.service NetworkManager.service}
JOURNALCTL=${JOURNALCTL:-journalctl}
RECORD=${RETROFORGE_INSTALL_RECORD:-/run/retroforge/install/record}
RELEASE_FILE=${RETROFORGE_INSTALL_RELEASE:-/etc/retroforge-release}

mkdir -p "$(dirname "$LOGFILE")" 2>/dev/null || true

{
    printf '=== retroforge installer log, %s ===\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
    if [ -r "$RELEASE_FILE" ]; then
        printf 'card: %s\n' "$(tr '\n' ' ' <"$RELEASE_FILE")"
    else
        printf 'card: no %s on this image\n' "$RELEASE_FILE"
    fi
    # -b, the CURRENT boot, and never -b -1: the boot index is not trustworthy on these devices,
    # whose RTC comes up stale. This runs inside the boot it is describing anyway.
    for u in $UNITS; do
        printf '\n--- %s ---\n' "$u"
        if command -v "$JOURNALCTL" >/dev/null 2>&1; then
            "$JOURNALCTL" -b -u "$u" --no-pager 2>&1 || printf '(no journal for %s)\n' "$u"
        else
            printf '(no journalctl on this image)\n'
        fi
    done
    # The kernel ring: whether a Wi-Fi or storage fault was the driver's is decided here.
    printf '\n--- kernel ring ---\n'
    if command -v "$JOURNALCTL" >/dev/null 2>&1; then
        "$JOURNALCTL" -b -k --no-pager 2>&1 || printf '(no kernel journal)\n'
    else
        printf '(no journalctl on this image)\n'
    fi
    # The spine's own plain-text record of what it did and what the user consented to.
    if [ -r "$RECORD" ]; then
        printf '\n--- install record ---\n'
        cat "$RECORD" 2>/dev/null
    fi
} >"$LOGFILE" 2>/dev/null || log "could not write $LOGFILE"

# The next thing that happens is a reboot.
sync 2>/dev/null || true
exit 0
