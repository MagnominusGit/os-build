extends BoxArtProvider
## Box art for ROM cards from what retroforge-scrape fetched (plan scraper Phase 2).
##
## A card is found through its launch item's metadata (system, rom), never its name: names carry
## rom_names.gd's "(System)" / "(EXT)" suffixes. One texture per art file, shared by every card
## showing it (shared_art.gd: weak references, so nothing outlives the cards).
## OGUI's own "local" provider registers first, so art dropped in user://boxart/local still wins.
## A ROM with no art yet is fetched there and then (art_fetch.gd, as the Steam plugin downloads its
## art), so the card asking for it gets it: OGUI never asks a card again.
##
## Decoding is what costs (ACE, 2026-10-17: a 640 px box PNG ~8.5 ms, on OGUI's main thread for
## every card, so 300 cards froze it 2.7 s). A card (GRID_PORTRAIT) shows a small cached card image
## (art_paths.gd card_image, a JPEG), composed once from the box; reading or composing it, and every
## other layout's decode (1280 px fan art), runs on a WorkerThreadPool task while OGUI keeps
## drawing. Our tabs do not await a card's art (plugin.gd _build_card), so their cards load in
## parallel; OGUI's own grids await each card, one frame or so apiece, but never freeze.
##
## Steam games (library_steam.gd) get the art the Steam client cached for its own library
## (steam_apps.gd art_path), else the same file from Valve's CDN, kept in ~/.cache/retroforge/steam-art
## (fetch_art: an owned game the client never showed has none cached). Fetched and decoded on a
## worker thread, as above. A Steam card is a card image too (cards/steam/<appid>.jpg): Steam's
## 600x900 art as a texture took four times a card image's memory.

const ArtPaths := preload("art_paths.gd")
const SteamApps := preload("steam_apps.gd")
const SharedArt := preload("shared_art.gd")
const LibraryStore := preload("library_store.gd")
const LIBRARY_ID := "retroforge-roms"
const STEAM_LIBRARY_ID := "retroforge-steam"
## GOG and Epic games (library_store.gd) get the art their store lists, fetched on a worker thread
## into ~/.cache/retroforge/store-art, and a card image as a Steam game's (cards/<store>/<id>.jpg).
const STORES := ["gog", "epic"]

var fetcher: RefCounted  # art_fetch.gd, set by plugin.gd; none: no fetching
var _art := SharedArt.new()


# Set in _ready, not _init: overriding _init skips BoxArtProvider._init, which registers the
# provider on ready. Ready handlers run before ready is emitted.
func _ready() -> void:
	provider_id = "retroforge"
	logger_name = "RetroForgeArt"
	logger = Log.get_logger(logger_name, log_level)


func get_boxart(item: LibraryItem, kind: LAYOUT) -> Texture2D:
	var launch: LibraryLaunchItem = item.get_launch_item(LIBRARY_ID)
	if not launch:
		for store in STORES:
			var store_launch: LibraryLaunchItem = item.get_launch_item("retroforge-" + store)
			if store_launch:
				return await _store_art(store_launch, kind)
		return await _steam_art(item, kind)
	var system := str(launch.metadata.get("system", ""))
	var rom := str(launch.metadata.get("rom", ""))
	var path := ArtPaths.path_for(ArtPaths.media_dir(), system, rom, kind)
	if path == "" and fetcher and system != "" and rom != "":
		await fetcher.fetch(system, rom)
		path = ArtPaths.path_for(ArtPaths.media_dir(), system, rom, kind)
	if path == "":
		return null
	var texture := await _texture(path, kind, ArtPaths.card_cache_path(ArtPaths.cards_dir(), system, rom))
	if not texture:
		logger.warn("Unreadable art: " + path)
	return texture


## A Steam game's art, or null: any card that launches a Steam game, ours or another library's.
func _steam_art(item: LibraryItem, kind: LAYOUT) -> Texture2D:
	var appid := 0
	for launch in item.launch_items:
		appid = SteamApps.appid_of(launch.args)
		if appid > 0:
			break
	if appid <= 0:
		return null
	# What the client cached, else fetched from Valve's CDN (worker thread: it may download).
	var path := SteamApps.art_path(SteamApps.steam_root(), appid, kind)
	if path == "":
		path = await _art.run(SteamApps.fetch_art.bind(SteamApps.art_cache_dir(), appid, kind))
	if path == "":
		return null
	return await _texture(path, kind, ArtPaths.steam_card_cache_path(ArtPaths.cards_dir(), appid))


## A GOG or Epic game's art, or null.
func _store_art(launch: LibraryLaunchItem, kind: LAYOUT) -> Texture2D:
	var path: String = await _art.run(LibraryStore.fetch_art.bind(LibraryStore.art_cache_dir(), launch, kind))
	if path == "":
		return null
	var card := ArtPaths.cards_dir().path_join(str(launch.metadata.get("store", ""))).path_join(launch.provider_app_id.validate_filename() + ".jpg")
	return await _texture(path, kind, card)


## The shared texture of an art file: a card image (cached at `card_cache`) for GRID_PORTRAIT, the
## file itself for the other layouts.
func _texture(path: String, kind: LAYOUT, card_cache: String) -> Texture2D:
	if kind == LAYOUT.GRID_PORTRAIT:
		return await _art.texture("card:" + path, path, _card.bind(path, card_cache))
	return await _art.texture("file:" + path, path, ArtPaths.load_image.bind(path))


## A card image: the cached one, else composed from the box and cached (worker thread).
static func _card(box_path: String, cache: String) -> Image:
	var image := ArtPaths.cached_card(cache, box_path)
	return image if image else ArtPaths.make_card(box_path, cache)
