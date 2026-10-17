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
## A card image: OGUI's card is 200x300 and draws its texture whole from the top-left, so a box of
## any other shape left part of the card empty (a SNES box filled its top third, ACE 2026-10-17).
## 1.5x the card, for sharpness on the larger panels.
const CARD_SIZE := Vector2i(300, 450)
## The darkened backdrop behind the box: brightness, contrast, saturation (Image.adjust_bcs).
const BACKDROP_BCS := Vector3(0.45, 1.0, 0.8)
const CARD_JPG_QUALITY := 0.85
## The backdrop's blur: shrunk to 1/BLUR of its size, then scaled back up (cheap, smooth).
const BLUR := 16


## retroforge-scrape's media folder (its RETROFORGE_MEDIA_DIR default).
static func media_dir() -> String:
	return OS.get_environment("HOME").path_join(".local/share/retroforge/media")


## Where composed card images are kept (rebuilt from the box whenever it is newer). JPEG: a card
## image is opaque, and JPEG decodes 2.5x faster than lossy WebP and encodes 7x faster (300x450,
## Godot 4.7.1, 2026-10-17: 0.67 / 1.3 ms vs 1.65 / 9.3 ms; PNG 2.1 / 33 ms).
static func cards_dir() -> String:
	return OS.get_environment("HOME").path_join(".cache/retroforge/cards")


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


## A CARD_SIZE card from a box of any shape: the whole box, scaled to fit and centred, over a
## blurred, darkened copy of it scaled to cover the card.
static func card_image(box: Image) -> Image:
	var src := box.duplicate() as Image
	src.convert(Image.FORMAT_RGBA8)
	var w := CARD_SIZE.x
	var h := CARD_SIZE.y
	var cover := maxf(float(w) / src.get_width(), float(h) / src.get_height())
	var back := src.duplicate() as Image
	var full := Vector2i(Vector2(src.get_size()) * cover)
	# Halve down to ~1/BLUR of the size (each halving averages 2x2, so every pixel counts; one big
	# shrink samples a few and looks blocky), then double back up and land on the exact size.
	var halvings := 0
	while back.get_width() > maxi(1, full.x / BLUR) and back.get_height() > maxi(1, full.y / BLUR):
		back.resize(maxi(1, back.get_width() / 2), maxi(1, back.get_height() / 2), Image.INTERPOLATE_BILINEAR)
		halvings += 1
	for i in maxi(0, halvings - 1):
		back.resize(back.get_width() * 2, back.get_height() * 2, Image.INTERPOLATE_BILINEAR)
	back.resize(full.x, full.y, Image.INTERPOLATE_BILINEAR)
	var card := back.get_region(Rect2i((back.get_width() - w) / 2, (back.get_height() - h) / 2, w, h))
	card.adjust_bcs(BACKDROP_BCS.x, BACKDROP_BCS.y, BACKDROP_BCS.z)
	var fit := minf(float(w) / src.get_width(), float(h) / src.get_height())
	var front := src.duplicate() as Image
	front.resize(maxi(1, roundi(src.get_width() * fit)), maxi(1, roundi(src.get_height() * fit)), Image.INTERPOLATE_LANCZOS)
	card.blend_rect(front, Rect2i(Vector2i.ZERO, front.get_size()), (CARD_SIZE - front.get_size()) / 2)
	return card


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
