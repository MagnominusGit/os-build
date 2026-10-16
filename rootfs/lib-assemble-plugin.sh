#!/usr/bin/env bash
# retroforge read-only root assembler — stages `ogui-plugin`.
#
# SOURCED by rootfs/assemble-rootfs.sh, never executed (tests/test-mkroot.sh reads the
# `# STAGE <name>` banners out of this file set, and asserts the roster it was audited against).
#
# Runs on EVERY build, release included.
#
# Reads the assembler's globals rather than taking arguments -- $stage (the staged tree), $ROOT
# (repo root), $OUT (build outputs).

# STAGE ogui-plugin — the RetroForge OpenGamepadUI plugin (ROM library, Main menu > Emulators), read-only
# in the image. OGUI only loads plugins from the player's home, so retroforge-session copies it there
# at every start when it is missing or older (/usr/lib/retroforge/install-ogui-plugin): a fresh card
# works offline, and a newer copy from the RetroForge plugin store is never downgraded.
#
# Built by `make plugin` (a $(ROOTFS) prerequisite). Missing means a stale invocation bypassed make;
# fail rather than assemble an image whose library has no ROM tabs.
plugin_zip="$OUT/plugins/retroforge.zip"
[ -s "$plugin_zip" ] || {
  echo "plugin payload missing: ${plugin_zip#"$ROOT"/} (run: make plugin)" >&2
  exit 1
}
echo "  injecting RetroForge OGUI plugin -> /usr/share/retroforge/opengamepadui/retroforge.zip"
install -D -m 0644 "$plugin_zip" "$stage/usr/share/retroforge/opengamepadui/retroforge.zip"
unset plugin_zip
