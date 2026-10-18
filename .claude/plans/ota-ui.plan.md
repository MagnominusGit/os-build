# Plan: OS updates in the shell (stable / beta)

**Complexity**: Medium. **Branch**: `feat/ota-ui`. **Status**: agreed 2026-10-18, Phase 1 in progress.

## Summary

The device and server halves of OTA exist and are in use: `retroforge-update` (check / apply `N%` /
`channel` / `channels` / `set-channel` / `status`, first-boot gate, `tests/test-update.sh`),
RAUC A/B streamed adaptive installs, R2 at `https://ota.retroforge.org/<channel>/`, and
`release-bundle.yml` routing `ota/vX.Y.Z` to `stable` and `ota/vX.Y.Z-beta.N` to `beta`. Nothing
in the shell drives it: OGUI's own (x86 `update.zip`) updater still sits in Settings > General.
This plan adds the shell half as a RetroForge `OSPlatform` shipped in the plugin, and publishes the
first beta.

## Decisions

| | Decision |
|---|---|
| D1 | The UI is a RetroForge **`OSPlatform` subclass in the plugin** (`nixos.gd` is the model), NOT an OGUI patch. OGUI's `platform.gd` only knows a fixed list of os-release IDs, so `platform.os` is `null` on RetroForge and `card_ui.gd:107` has already run `platform.load(root)` before plugins load: the plugin installs `platform.os` and calls its `ready(root)` itself. |
| D2 | **Never automatic.** A background check only notifies. Install and reboot happen only on a button press. |
| D2b | **One button, Steam-style**: `Check for updates` -> `Install <version>` (progress while installing) -> `Restart now` when the install is done. Restart = `systemctl reboot`, the same call OGUI's power menu makes (`power_menu.gd:22`). A staged update found at start (client's "restart pending") shows `Restart now` straight away. |
| D3 | **No restriction on channel changes**: stable -> beta and beta -> stable switch freely, no confirmation. Whatever the new channel's `latest.json` names is offered, older or not (the client's inequality check already does this). |
| D4 | Beta versions are `X.Y.Z-beta.N`, ahead of the next stable (what the workflow already keys on). |

## Patterns to Mirror

| Category | Source | Pattern |
|---|---|---|
| OS platform | `_ref/OpenGamepadUI/core/platform/os/nixos.gd` | `ready(root)`: await a frame, `_remove_updater`, `_add_updater` into `settings_general_menu` |
| Settings section injected at runtime | `apps/ogui-retroforge-plugin/plugin/scraper_settings.gd` | section_label / card_button_setting / dropdown scenes, `_nodes` kept for teardown |
| Long-running tool on a thread | `apps/ogui-retroforge-plugin/plugin/scrape_runner.gd` | worker thread, progress signal, runner outlives its thread |
| Client contract + tests | `rootfs/overlay/usr/bin/retroforge-update`, `tests/test-update.sh` | exit 7 = none / fail closed; stdout parsed, stderr free text; tests exec the shipped file through env seams |
| Plugin tests | `tests/test-plugin.sh` | |

## Files to Change

| File | Action | Why |
|---|---|---|
| `rootfs/overlay/usr/bin/retroforge-update` | UPDATE | `version` subcommand |
| `tests/test-update.sh` | UPDATE | `version`; channel switch offers an older release |
| `rootfs/overlay/usr/lib/retroforge/install-ogui-plugin`, `tests/test-plugin-install.sh`, `rootfs/lib-assemble-plugin.sh` | UPDATE | image's plugin wins on any version difference |
| `apps/ogui-retroforge-plugin/plugin/retroforge_os.gd` | CREATE | `PlatformRetroForge extends OSPlatform`: updater UI + background check |
| `apps/ogui-retroforge-plugin/plugin/update_runner.gd` | CREATE (if scrape_runner is not reusable as is) | threaded check / apply with `N%` |
| `apps/ogui-retroforge-plugin/plugin/plugin.gd` | UPDATE | install `platform.os` when null and `os_info.id == "retroforge"` |
| `apps/ogui-retroforge-plugin/plugin/plugin.json` | UPDATE | bump `plugin.version` |
| `tests/test-plugin.sh` | UPDATE | static checks for the new files |
| `docs/ota.md`, `docs/RUNBOOK.md`, `.github/workflows/release-bundle.yml` (comment), `.claude/plans/retroforge.plan.md` (Phase 5) | UPDATE | the picker exists; how to cut a beta |

## Tasks

### Phase 1: client gaps (test first)
- `retroforge-update version`: `<version><TAB><channel>` for the header.
- Test that a channel switch offers the other channel's release even when it is older
  (beta `0.0.4-beta.1` -> stable `0.0.3`), so D3 is pinned by a test, not by accident.
- `install-ogui-plugin` installs the image's plugin whenever its version DIFFERS, not only when
  newer: the image is the only source (no plugin store), and after beta -> stable the beta plugin
  left in `/home` would call tools the stable image lacks. `tests/test-plugin-install.sh`.
- **Validate**: `tests/test-update.sh`.

### Phase 2: `PlatformRetroForge`
- `ready(root)`: await a frame, find `main`, remove OGUI's updater nodes (as `nixos.gd`
  `_remove_updater`), add an "Updates" section when `/usr/bin/retroforge-update` exists.
- Section: **Version** (read-only), **Channel** dropdown (Stable / Beta from `channels`; disabled
  with the reason when `pinned`; change = `set-channel` then re-check), and the **one update
  button** of D2b, with a progress bar under it while installing.
- Every command runs off the main thread. Components configured only after `add_child` (release
  export SEGFAULT, see build gotchas). Errors -> a line under the button, never a silent no-op.
- `plugin.gd`: install it only when `platform.os == null` and `os_info.id == "retroforge"`.
- **Validate**: `tests/test-plugin.sh`; deploy with auto-rollback; HW on ACE.

### Phase 3: background check
- One check a few minutes after session start, then every 6 h, skipped while a game runs. An
  available update posts an OGUI notification pointing at Settings > General. Nothing installs.

### Phase 4: first beta + HW
- Build/sign `0.0.4-beta.1`, install it on the ACE from a local file first (`docs/ota.md` step 2),
  then tag `ota/v0.0.4-beta.1` (creates `beta/` in the bucket).
- ACE: stable -> beta, check, install (progress), Restart now, trial boot confirmed; beta -> stable
  (older build offered, install, restart); dev card shows the channel pinned; nothing before first boot.
- Look for rauc's `using HTTP/1` warning on the first real R2 stream (never observed yet).

### Phase 5: docs
- `docs/ota.md`, `docs/RUNBOOK.md`, `release-bundle.yml` comment ("There is no Settings picker"),
  `retroforge.plan.md` Phase 5 entry.

## Validation

```sh
tests/test-update.sh
tests/test-plugin.sh
make test
```

## Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Beta -> stable leaves the beta plugin in `/home` | — | fixed in Phase 1: the image's plugin always wins; HW step in Phase 4 |
| Restart into a bundle that never reaches a session (no serial) | Medium | every bundle HW-installed before tagging; trial boot + rollback |
| Runtime edits of Settings > General crash the release export | Medium | configure after `add_child`; deploy with auto-rollback |
| A future OGUI adds `retroforge` to its list | Low | only install when `platform.os` is null |
| HTTP/1 streaming from R2 is slow | Low | observe in Phase 4 |

## Acceptance
- [ ] All phases done, tests green
- [ ] ACE: both channel switches and a restart-into-update proven on HW
- [ ] Nothing installs or reboots without a button press
