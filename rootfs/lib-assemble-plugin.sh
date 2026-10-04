#!/usr/bin/env bash
# qforge read-only root assembler — stages `ogui-plugin`.
#
# SOURCED by rootfs/assemble-rootfs.sh, never executed (tests/test-mkroot.sh reads the
# `# STAGE <name>` banners out of this file set, and asserts the roster it was audited against).
#
# Runs on EVERY build, release included.
#
# Reads the assembler's globals rather than taking arguments -- $stage (the staged tree), $ROOT
# (repo root), $OUT (build outputs).

# STAGE ogui-plugin — the QForge OpenGamepadUI plugin (ROM library, Settings > Emulators), read-only
# in the image. OGUI only loads plugins from the player's home, so qforge-session copies it there
# at every start when it is missing or older (/usr/lib/qforge/install-ogui-plugin): a fresh card
# works offline, and a newer copy from the QForge plugin store is never downgraded.
#
# Built by `make plugin` (a $(ROOTFS) prerequisite). Missing means a stale invocation bypassed make;
# fail rather than assemble an image whose library has no ROM tabs.
plugin_zip="$OUT/plugins/qforge.zip"
[ -s "$plugin_zip" ] || {
  echo "plugin payload missing: ${plugin_zip#"$ROOT"/} (run: make plugin)" >&2
  exit 1
}
echo "  injecting QForge OGUI plugin -> /usr/share/qforge/opengamepadui/qforge.zip"
install -D -m 0644 "$plugin_zip" "$stage/usr/share/qforge/opengamepadui/qforge.zip"
unset plugin_zip
