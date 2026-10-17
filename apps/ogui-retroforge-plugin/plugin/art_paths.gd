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
## PortMaster ports are never scraped: each port PortMaster installs carries a gameinfo.xml (an ES
## gameList) whose <path> names its launch script and <image> its screenshot, both relative to
## ~/roms/ports. That screenshot serves every layout but LOGO (ports have no logo). The files are read
## once per PORT_MAP_TTL_MS, not once per card.
const PORT_LAYOUTS := [0, 1, 2]
const PORT_MAP_TTL_MS := 5000
static var _port_maps := {}  # ports folder -> {"at": msec, "map": {script file name: image path}}
## A card image: OGUI's card is 200x300 and draws its texture whole from the top-left, so a box of
## any other shape left part of the card empty (a SNES box filled its top third, ACE 2026-10-17).
## 1.5x the card, for sharpness on the larger panels.
const CARD_SIZE := Vector2i(300, 450)
const CARD_JPG_QUALITY := 0.85


## retroforge-scrape's media folder (its RETROFORGE_MEDIA_DIR default).
static func media_dir() -> String:
	return OS.get_environment("HOME").path_join(".local/share/retroforge/media")


## Where composed card images are kept (rebuilt from the box whenever it is newer). JPEG: a card
## image is opaque, and JPEG decodes 2.5x faster than lossy WebP and encodes 7x faster (300x450,
## Godot 4.7.1, 2026-10-17: 0.67 / 1.3 ms vs 1.65 / 9.3 ms; PNG 2.1 / 33 ms).
static func cards_dir() -> String:
	return OS.get_environment("HOME").path_join(".cache/retroforge/cards")


## ~/roms/ports, where PortMaster puts its ports (plan Phase 4b).
static func ports_dir() -> String:
	return OS.get_environment("HOME").path_join("roms/ports")


## {launch script file name: its screenshot} from every <port>/gameinfo.xml in `ports`. An image
## outside `ports` or missing is left out; a file that does not parse is skipped.
static func port_images(ports: String) -> Dictionary:
	var cached: Dictionary = _port_maps.get(ports, {})
	if not cached.is_empty() and Time.get_ticks_msec() - int(cached["at"]) < PORT_MAP_TTL_MS:
		return cached["map"]
	var root := ports.simplify_path()
	var images := {}
	for folder in DirAccess.get_directories_at(ports):
		for game in _gameinfo(ports.path_join(folder).path_join("gameinfo.xml")):
			var image := root.path_join(game.get("image", "")).simplify_path()
			var script: String = game.get("path", "").get_file()
			if script != "" and image.begins_with(root + "/") and FileAccess.file_exists(image):
				images[script] = image
	_port_maps[ports] = {"at": Time.get_ticks_msec(), "map": images}
	return images


## The <game> entries of an ES gameList file: [{"path": ..., "image": ...}]; [] when unreadable.
static func _gameinfo(path: String) -> Array:
	var parser := XMLParser.new()
	if not FileAccess.file_exists(path) or parser.open(path) != OK:
		return []
	var games := []
	var game := {}
	var field := ""
	while parser.read() == OK:
		match parser.get_node_type():
			XMLParser.NODE_ELEMENT:
				field = parser.get_node_name()
				if field == "game":
					game = {}
			XMLParser.NODE_TEXT:
				if field in ["path", "image"]:
					game[field] = parser.get_node_data().strip_edges()
			XMLParser.NODE_ELEMENT_END:
				if parser.get_node_name() == "game" and game.has("path"):
					games.append(game)
				field = ""
	return games


## An art file as an Image, decoded by its first bytes (Godot's loader goes by the extension, and a
## PNG named .jpg then loads nothing); null when it is not a PNG, JPEG or WebP.
static func load_image(path: String) -> Image:
	var bytes := FileAccess.get_file_as_bytes(path)
	var image := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if bytes.slice(0, 8) == PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]):
		err = image.load_png_from_buffer(bytes)
	elif bytes.slice(0, 3) == PackedByteArray([0xFF, 0xD8, 0xFF]):
		err = image.load_jpg_from_buffer(bytes)
	elif bytes.slice(0, 4).get_string_from_ascii() == "RIFF" and bytes.slice(8, 12).get_string_from_ascii() == "WEBP":
		err = image.load_webp_from_buffer(bytes)
	return image if err == OK and not image.is_empty() else null


## A CARD_SIZE card from a box of any shape: the box scaled to cover the card and its centre cut
## out (user decision 2026-10-17, preferred over the whole box fitted on a blurred backdrop; a wide
## box loses its sides). retroforge-scrape asks boxes 450 high, so this rarely scales up.
static func card_image(box: Image) -> Image:
	var src := box.duplicate() as Image
	src.convert(Image.FORMAT_RGBA8)
	var scale := maxf(float(CARD_SIZE.x) / src.get_width(), float(CARD_SIZE.y) / src.get_height())
	src.resize(maxi(CARD_SIZE.x, roundi(src.get_width() * scale)), maxi(CARD_SIZE.y, roundi(src.get_height() * scale)), Image.INTERPOLATE_LANCZOS)
	return src.get_region(Rect2i((src.get_size() - CARD_SIZE) / 2, CARD_SIZE))


## A ROM's cached card image path.
static func card_cache_path(cards: String, system: String, rom: String) -> String:
	return cards.path_join(system).path_join(rom.trim_suffix("/").get_file() + ".jpg")


## The cached card image, or null when there is none or the box is newer.
static func cached_card(cache: String, box_path: String) -> Image:
	if not FileAccess.file_exists(cache) or FileAccess.get_modified_time(cache) < FileAccess.get_modified_time(box_path):
		return null
	return load_image(cache)


## Compose the card image from the box and cache it (worker-thread safe); null without a box.
static func make_card(box_path: String, cache: String) -> Image:
	var box := load_image(box_path)
	if not box:
		return null
	var card := card_image(box)
	card.convert(Image.FORMAT_RGB8)
	DirAccess.make_dir_recursive_absolute(cache.get_base_dir())
	var tmp := "%s.%d.tmp" % [cache, OS.get_thread_caller_id()]
	if card.save_jpg(tmp, CARD_JPG_QUALITY) == OK:
		DirAccess.rename_absolute(tmp, cache)
	return card


## The art file for a ROM (a file, or a game folder) in a layout; "" when none was scraped. A port's
## comes from PortMaster's gameinfo.xml in `ports` (default: the port script's own folder).
static func path_for(media: String, system: String, rom: String, layout: int, ports := "") -> String:
	var key := rom.trim_suffix("/").get_file()
	if system == "" or key == "":
		return ""
	if system == "ports":
		if not layout in PORT_LAYOUTS:
			return ""
		return port_images(ports if ports != "" else rom.get_base_dir()).get(key, "")
	for kind in KINDS.get(layout, []):
		for ext in EXTS:
			var path := media.path_join(system).path_join("%s-%s.%s" % [key, kind, ext])
			if FileAccess.file_exists(path):
				return path
	return ""
