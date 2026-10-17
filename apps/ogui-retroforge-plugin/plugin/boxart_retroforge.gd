extends BoxArtProvider
## Box art for ROM cards from what retroforge-scrape fetched (plan scraper Phase 2).
##
## A card is found through its launch item's metadata (system, rom), never its name: names carry
## rom_names.gd's "(System)" / "(EXT)" suffixes. No texture cache: a card holds its texture, and a
## cache would keep every texture of a 2,000-ROM library in memory after its cards are gone.
## OGUI's own "local" provider registers first, so art dropped in user://boxart/local still wins.
##
## Decoding is what costs (ACE, 2026-10-17: a 640 px box PNG ~8.5 ms, on OGUI's main thread for
## every card, so 300 cards froze it 2.7 s). A card (GRID_PORTRAIT) shows a small cached card image
## (art_paths.gd card_image, a JPEG), composed once from the box; reading or composing it, and every
## other layout's decode (1280 px fan art), runs on a WorkerThreadPool task while OGUI keeps
## drawing. Our tabs do not await a card's art (plugin.gd _build_card), so their cards load in
## parallel; OGUI's own grids await each card, one frame or so apiece, but never freeze.

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
	var system := str(launch.metadata.get("system", ""))
	var rom := str(launch.metadata.get("rom", ""))
	var path := ArtPaths.path_for(ArtPaths.media_dir(), system, rom, kind)
	if path == "":
		return null
	var image: Image
	if kind == LAYOUT.GRID_PORTRAIT:
		image = await _off_main_thread(_card.bind(path, ArtPaths.card_cache_path(ArtPaths.cards_dir(), system, rom)))
	else:
		image = await _off_main_thread(ArtPaths.load_image.bind(path))
	if not image:
		logger.warn("Unreadable art: " + path)
		return null
	return ImageTexture.create_from_image(image)


## A card image: the cached one, else composed from the box and cached (worker thread).
static func _card(box_path: String, cache: String) -> Image:
	var image := ArtPaths.cached_card(cache, box_path)
	return image if image else ArtPaths.make_card(box_path, cache)


## Run `job` (returning an Image) on a worker thread; OGUI keeps drawing frames meanwhile.
func _off_main_thread(job: Callable) -> Image:
	var out := []
	var task := WorkerThreadPool.add_task(func() -> void: out.append(job.call()))
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	return out[0] if not out.is_empty() else null
