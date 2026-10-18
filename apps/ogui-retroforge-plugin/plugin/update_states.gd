extends RefCounted
## What Settings > General > Updates shows (retroforge_os.gd), from retroforge-update's answers.
##
## One button walks Steam's steps: Check for updates -> Install <version> -> Restart now. Nothing
## installs or restarts on its own (plan ota-ui D2). No OGUI types: tested on a stock Godot
## (tests/test-plugin.sh).

enum Step { IDLE, CHECKING, AVAILABLE, INSTALLING, STAGED }

## The channels' names as the player reads them; any other (a dev card's pin) shows as it is.
const CHANNEL_NAMES := {"stable": "Stable", "beta": "Beta"}


## `retroforge-update channels`: the offered channels, then `pinned<TAB><source>` when /etc or the
## environment decides the channel. {"channels": [...], "pinned": "<source>" or ""}.
static func parse_channels(stdout: String) -> Dictionary:
	var channels: Array[String] = []
	var pinned := ""
	for line in stdout.split("\n", false):
		var text := line.strip_edges()
		if text.begins_with("pinned\t"):
			pinned = text.get_slice("\t", 1)
		elif text != "":
			channels.append(text)
	return {"channels": channels, "pinned": pinned}


## `retroforge-update channel`: "<channel><TAB><source>" -> the channel ("" when unreadable).
static func parse_channel(stdout: String) -> String:
	return stdout.strip_edges().get_slice("\t", 0)


static func channel_name(channel: String) -> String:
	return CHANNEL_NAMES.get(channel, channel)


## The button for a step: {"button": text, "description": text, "disabled": bool}. `running` is
## the version this image runs, `offered` the one check found (or staged), `percent` the install's.
static func button_for(step: Step, running: String, offered := "", percent := 0) -> Dictionary:
	match step:
		Step.CHECKING:
			return {"button": "Checking...", "description": "Looking for a newer RetroForge.", "disabled": true}
		Step.AVAILABLE:
			return {"button": "Install", "description": "RetroForge %s is available (you have %s)." % [offered, running], "disabled": false}
		Step.INSTALLING:
			return {"button": "Installing...", "description": "Installing RetroForge %s: %d%%. You can keep playing." % [offered, percent], "disabled": true}
		Step.STAGED:
			return {"button": "Restart now", "description": "RetroForge %s is installed. Restart to use it." % offered, "disabled": false}
	return {"button": "Check for updates", "description": "RetroForge %s." % running if running != "" else "", "disabled": false}


## What the channel dropdown says under its title.
static func channel_description(pinned: String) -> String:
	if pinned != "":
		return "Set by %s on this device." % pinned
	return "Beta gets new versions first. You can switch back to Stable at any time."
