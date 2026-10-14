# Container runtime for the host-side build scripts — sourced, not run.
#
# docker where it is installed, otherwise podman (the Fedora build box runs rootless podman).
# RETROFORGE_CONTAINER=docker|podman overrides; the Makefile derives and exports the same choice.
#
# Call the runtime as `ctr <subcommand> ...`. Under podman two subcommands are adjusted:
#   run     gets --security-opt label=disable. On an SELinux host (Fedora, enforcing) a container
#           cannot read an unlabelled bind mount; relabelling it instead (:z) would rewrite the
#           SELinux labels of the user's checkout.
#   import  takes --os/--arch, not docker's --platform os/arch.
RETROFORGE_CONTAINER="${RETROFORGE_CONTAINER:-$(command -v docker >/dev/null 2>&1 && echo docker || echo podman)}"

ctr() {
  if [ "$RETROFORGE_CONTAINER" != podman ]; then
    "$RETROFORGE_CONTAINER" "$@"
    return
  fi
  case "${1:-}" in
    run)
      shift
      podman run --security-opt label=disable "$@"
      ;;
    import)
      shift
      local a args=()
      while [ $# -gt 0 ]; do
        a="$1"; shift
        if [ "$a" = --platform ] && [ $# -gt 0 ]; then
          args+=(--os "${1%%/*}" --arch "${1#*/}"); shift
        else
          args+=("$a")
        fi
      done
      podman import "${args[@]}"
      ;;
    *)
      podman "$@"
      ;;
  esac
}

# What `ctr run` expands to, for printing a command the user can paste.
ctr_run_cmdline() {
  if [ "$RETROFORGE_CONTAINER" = podman ]; then
    printf 'podman run --security-opt label=disable'
  else
    printf '%s run' "$RETROFORGE_CONTAINER"
  fi
}

# Fail early, naming the runtime, when it is not installed.
# The uid:gid a container must chown its output to for the HOST user to own it. Under docker that
# is the host user's own ids. Under ROOTLESS podman it is 0:0: the user namespace maps container root
# to the invoking user and every other container uid to a subordinate id (uid 1000 inside lands as
# 525287 on the build box), so chowning to $(id -u) inside hands the files to a stranger and the
# host script that wrote them a moment ago gets EACCES.
ctr_host_owner() {
  if [ "$RETROFORGE_CONTAINER" = podman ] && [ "$(id -u)" != 0 ]; then
    printf '0:0'
  else
    printf '%s:%s' "$(id -u)" "$(id -g)"
  fi
}
ctr_require() {
  command -v "$RETROFORGE_CONTAINER" >/dev/null 2>&1 \
    || { echo "$RETROFORGE_CONTAINER required${1:+ for $1} (RETROFORGE_CONTAINER=docker|podman)" >&2; exit 1; }
}
