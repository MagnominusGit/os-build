extends RefCounted

## What the Apps page offers for one emulator (plan emulator-latest, Phase 2), from its
## `retroforge-emu list` entry and its `retroforge-emu check` answer ({} until one arrives, or
## offline). No OGUI types, so tests/test-plugin.sh runs it in a stock headless Godot.
##
## rows() -> {"main": row, "tested": row or null, "extra": [row...]}; "tested" (Install tested version)
## goes right below the main row, "extra" before Delete. A row is {"text", "description", "button",
## "args"}: the retroforge-emu arguments its button runs (["install", id], ["install", id,
## "--tested"], ["rollback", id], ["check", id, "--refresh"]), or [] for Open.
##
## Tested = the catalog's pin ("tested" in list), the build RetroForge checked. An entry that
## follows upstream ("follows_latest") installs upstream's newest by default; the page says when the
## installed build is not the tested one, and offers it back. Whether upstream has a newer build is
## asked only when the player presses "Check for a newer version" (each ask costs two of the 60
## GitHub requests an hour this network gets); a failed or missing check offers no Update.

const Credits := preload("credits.gd")


static func rows(id: String, emu: Dictionary, check: Dictionary) -> Dictionary:
	if emu.get("kind") == "steam":
		return steam_rows(id, emu)
	var installed = emu.get("installed")
	var tested = emu.get("tested")
	var follows: bool = emu.get("follows_latest", false) == true
	var self_update: bool = emu.get("self_update", false) == true
	var nightly: bool = tested == null and follows  # no tested build at all (Cemu)
	var latest = check.get("latest") if check.get("error") == null else null
	var mb := int(emu.get("size", 0)) / 1048576
	var install := ["install", id]
	var main := {"button": "Open", "args": []}

	if installed == null:
		main.text = "Not installed"
		main.button = "Download"
		main.args = install
		if nightly:
			main.description = "Latest nightly build, about %d MB. Not tested by RetroForge." % mb
		elif not follows:
			main.description = "Version %s, %d MB." % [_v(tested), mb]
		elif latest != null and latest != tested:
			main.description = "Version %s, the newest from upstream, about %d MB. RetroForge tested %s." % [
				_v(latest), mb, _v(tested)]
		else:
			main.description = "The newest version from upstream, about %d MB. RetroForge tested %s." % [
				mb, _v(tested)]
	else:
		main.text = ("" if nightly else "Version ") + _v(installed)
		if installed == tested:
			main.text += " · Tested"
		if self_update:
			# PortMaster: it offers its own updates when opened.
			main.description = "Installed. Updates itself: open it to check."
		elif follows and latest != null and latest != installed:
			main.button = "Update"
			main.args = install
			main.description = "Update to %s available, about %d MB." % [_v(latest), mb]
		elif not follows and emu.get("update", false):
			main.button = "Update"
			main.args = install
			main.description = "Update to %s available, %d MB." % [_v(tested), mb]
		elif nightly:
			main.description = "Installed. Nightly builds come straight from upstream, untested by RetroForge."
		elif installed != tested:
			main.description = "Installed straight from upstream. RetroForge tested %s." % _v(tested)
		else:
			main.description = "Installed."

	var extra := []
	if installed != null and follows and not self_update and main.button != "Update":
		var checked: bool = latest != null and latest == installed
		extra.append({"text": "Check for a newer version", "button": "Check",
			"description": ("Up to date: %s is the newest from upstream." % _v(installed)) if checked
				else "Asks upstream whether a newer version is out.",
			"args": ["check", id, "--refresh"]})
	if installed != null and emu.get("previous") != null:
		extra.append({"text": "Revert to " + _v(emu["previous"]), "button": "Revert",
			"description": "Goes back to the version installed before, kept on this device.",
			"args": ["rollback", id]})
	var tested_row = null
	if follows and tested != null and installed != tested and not (self_update and installed != null):
		tested_row = {"text": "Install tested version (%s)" % _v(tested), "button": "Install",
			"description": "The version RetroForge tested, %d MB." % mb,
			"args": ["install", id, "--tested"]}
	return {"main": main, "tested": tested_row, "extra": extra}


## Steam Client (retroforge-emu's "kind": "steam"): Download until installed, then Open (Steam's own
## UI) and Repair (the install again: it fetches only what is missing). Valve's client updates
## itself, so there is no Update, Check or Revert.
static func steam_rows(id: String, emu: Dictionary) -> Dictionary:
	var mb := int(emu.get("size", 0)) / 1048576
	var install := ["install", id]
	var repair := {"text": "Repair", "button": "Repair", "args": install,
		"description": "Downloads again whatever of it is missing."}
	var main := {"button": "Open", "args": []}
	var extra := []
	if emu.get("installed") == null:
		main.text = "Not installed"
		main.button = "Download"
		main.args = install
		main.description = "Valve's Steam for arm64, with what x86 games need under FEX: about %d MB. Updates itself once installed." % mb
	else:
		main.text = "Installed"
		main.description = "Opens Steam. It updates itself."
		extra.append(repair)
	return {"main": main, "tested": null, "extra": extra}


static func _v(tag) -> String:
	return Credits.version_text(str(tag)) if tag != null else "?"
