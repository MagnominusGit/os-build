extends RefCounted
## Where retroforge-scrape put a ROM's art (plan scraper Phase 2), per OGUI box art layout.
##
## retroforge-scrape writes <media>/<system>/<ROM file or folder name>-<kind>.<png|jpg>, kind one of
## box / screen / fanart / wheel. No OGUI types here (the layouts are BoxArtProvider.LAYOUT's
## values), so tests/test-plugin.sh runs it on a stock Godot.

## BoxArtProvider.LAYOUT -> our kinds, best first. GRID_PORTRAIT is every library card; the wide
## layouts (the home banner, the launch menu's backdrop) want 16:9 fan art, else a screenshot;
## LOGO sits on that backdrop.
const KINDS := {
	0: ["box"],  # GRID_PORTRAIT
	1: ["fanart", "screen"],  # GRID_LANDSCAPE
	2: ["fanart", "screen"],  # BANNER
	3: ["wheel"],  # LOGO
}
const EXTS := ["png", "jpg"]


## retroforge-scrape's media folder (its RETROFORGE_MEDIA_DIR default).
static func media_dir() -> String:
	return OS.get_environment("HOME").path_join(".local/share/retroforge/media")


## An art file as an Image, decoded by its first bytes (Godot's loader goes by the extension, and a
## PNG named .jpg then loads nothing); null when it is not a PNG or JPEG.
static func load_image(path: String) -> Image:
	var bytes := FileAccess.get_file_as_bytes(path)
	var image := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if bytes.slice(0, 8) == PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]):
		err = image.load_png_from_buffer(bytes)
	elif bytes.slice(0, 3) == PackedByteArray([0xFF, 0xD8, 0xFF]):
		err = image.load_jpg_from_buffer(bytes)
	return image if err == OK and not image.is_empty() else null


## The art file for a ROM (a file, or a game folder) in a layout; "" when none was scraped.
static func path_for(media: String, system: String, rom: String, layout: int) -> String:
	var key := rom.trim_suffix("/").get_file()
	if system == "" or key == "":
		return ""
	for kind in KINDS.get(layout, []):
		for ext in EXTS:
			var path := media.path_join(system).path_join("%s-%s.%s" % [key, kind, ext])
			if FileAccess.file_exists(path):
				return path
	return ""
