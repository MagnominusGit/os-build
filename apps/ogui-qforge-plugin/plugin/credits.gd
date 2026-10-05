extends RefCounted

## Who made an emulator, as the Emulators page shows it under its name. No OGUI types, so
## tests/test-plugin.sh runs it in a stock headless Godot.


## "By <author>, <homepage>. Licence <name>: <url>" under the emulator's name. Plain text: there is
## no browser to open a link in, so the address itself is what the player gets.
static func credit_text(emu: Dictionary) -> String:
	var parts := PackedStringArray()
	var author := str(emu.get("author", "")) if emu.get("author") != null else ""
	var homepage := str(emu.get("homepage", "")) if emu.get("homepage") != null else ""
	if author != "":
		parts.append("By " + author + (", " + homepage if homepage != "" else "") + ".")
	elif homepage != "":
		parts.append(homepage)
	var licence: Dictionary = emu.get("licence") if emu.get("licence") is Dictionary else {}
	if str(licence.get("name", "")) != "":
		var url := str(licence.get("url", ""))
		parts.append("Licence " + str(licence["name"]) + (": " + url if url != "" else ""))
	return " ".join(parts)
