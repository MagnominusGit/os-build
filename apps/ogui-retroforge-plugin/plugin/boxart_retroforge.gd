extends BoxArtProvider
## Box art for ROM cards from what retroforge-scrape fetched (plan scraper Phase 2).
##
## A card is found through its launch item's metadata (system, rom), never its name: names carry
## rom_names.gd's "(System)" / "(EXT)" suffixes. Nothing is cached: a card holds its texture, and a
## cache would keep every texture of a 2,000-ROM library in memory after its cards are gone.
## OGUI's own "local" provider registers first, so art dropped in user://boxart/local still wins.

const ArtPaths := preload("art_paths.gd")
const LIBRARY_ID := "retroforge-roms"


# Set in _ready, not _init: overriding _init skips BoxArtProvider._init, which registers the
# provider on ready. Ready handlers run before ready is emitted.
func _ready() -> void:
	provider_id = "retroforge"
	logger_name = "RetroForgeArt"
	logger = Log.get_logger(logger_name, log_level)


func get_boxart(item: LibraryItem, kind: LAYOUT) -> Texture2D:
	var launch: LibraryLaunchItem = item.get_launch_item(LIBRARY_ID)
	if not launch:
		return null
	var path := ArtPaths.path_for(ArtPaths.media_dir(), str(launch.metadata.get("system", "")),
		str(launch.metadata.get("rom", "")), kind)
	if path == "":
		return null
	var image := ArtPaths.load_image(path)
	if not image:
		logger.warn("Unreadable art: " + path)
		return null
	return ImageTexture.create_from_image(image)
