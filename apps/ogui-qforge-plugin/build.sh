#!/usr/bin/env bash
# Pack the QForge OpenGamepadUI plugin: plugin/* -> <out>/qforge.zip as plugins/qforge/*, the
# layout OGUI's PluginLoader reads from user://plugins/<id>.zip (plugin.json found under plugins/).
#
#   apps/ogui-qforge-plugin/build.sh [out-dir]    # default: out/plugins
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${1:-$here/../../out/plugins}"
mkdir -p "$out"
python3 - "$here/plugin" "$out/qforge.zip" <<'PY'
import os, sys, zipfile
src, dst = sys.argv[1:3]
# Fixed timestamps so the same sources give the same zip.
with zipfile.ZipFile(dst + ".part", "w", zipfile.ZIP_DEFLATED) as z:
    for name in sorted(os.listdir(src)):
        info = zipfile.ZipInfo(f"plugins/qforge/{name}", date_time=(2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        with open(os.path.join(src, name), "rb") as f:
            z.writestr(info, f.read())
os.replace(dst + ".part", dst)
print(dst)
PY
