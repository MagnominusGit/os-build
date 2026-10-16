# Shared by build.sh, compose.sh and .github/workflows/release-fex-guest.yml -- sourced, not run.
#
# Everything that names the guest image is derived here from committed files, so the workflow, a
# local compose and the docs cannot disagree about what a given commit produces:
#
#   version   <mesa pkgver>-<revision>   e.g. 26.2.4-1
#   asset     retroforge-fex-guest-<version>.sqsh
#   tag       fex-guest/v<version>
#
# The mesa version comes from packages/mesa/PKGBUILD (the host driver's pin), the revision from
# ./guest.pin. A mesa bump therefore renames the image with nothing to edit here.

MX86_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MX86_ROOT="$(cd "$MX86_DIR/../.." && pwd)"
MX86_MESA="$MX86_ROOT/packages/mesa"

mx86_field() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

# A PKGBUILD top-level variable, read the way packages/mesa/fetch-source.sh reads source[0]:
# sourcing a PKGBUILD defines its functions and runs none of them.
mx86_pkgbuild_var() {
  bash -c "source '$MX86_MESA/PKGBUILD' >/dev/null 2>&1; echo \"\${$1}\""
}

mx86_mesa_pkgver() { mx86_pkgbuild_var pkgver; }

# The string the host build writes into mesa's VERSION file (its prepare(), after build-overlay.sh
# has turned pkgrel N into N.<pkgrel_suffix>). The guest uses the same one, so GL_VERSION and the
# libgallium-<version>.so name say the same build on both sides of FEX.
mx86_mesa_version_string() {
  local pkgver epoch pkgrel suffix
  pkgver="$(mx86_pkgbuild_var pkgver)"; epoch="$(mx86_pkgbuild_var epoch)"
  pkgrel="$(mx86_pkgbuild_var pkgrel)"; suffix="$(mx86_field "$MX86_MESA/source.pin" pkgrel_suffix)"
  printf '%s-retroforge%s.%s%s\n' "$pkgver" "$epoch" "$pkgrel" "${suffix:+.$suffix}"
}

mx86_patches() { mx86_field "$MX86_MESA/source.pin" patches; }

mx86_revision() {
  local r; r="$(mx86_field "$MX86_DIR/guest.pin" revision)"
  case "$r" in ''|*[!0-9]*) echo "guest.pin: revision must be a positive integer, got '$r'" >&2; return 1 ;; esac
  printf '%s\n' "$r"
}

mx86_version() { printf '%s-%s\n' "$(mx86_mesa_pkgver)" "$(mx86_revision)"; }
mx86_asset()   { printf 'retroforge-fex-guest-%s.sqsh\n' "$(mx86_version)"; }
mx86_tag()     { printf 'fex-guest/v%s\n' "$(mx86_version)"; }
