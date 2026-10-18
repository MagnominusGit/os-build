extends RefCounted
## On-demand art, as OGUI's Steam plugin does it: a card asking for the art of a ROM that has none
## gets it scraped there and then (`retroforge-scrape run --rom`) and awaits it, so a ROM copied
## while OGUI runs shows its art in every grid -- Library, Home -- the moment its card is built.
## OGUI asks for a card's art once (GameCard.set_library_item) and keeps the card: art that arrived
## later, from a background run, stayed on the placeholder until the card was rebuilt (a launch, a
## restart; Pocket FIT 2026-10-18).
##
## Only for a ROM the tool never tried: a ROM ScreenScraper did not know has its cache entry
## (~/.cache/retroforge/scrape.json) and stays on the placeholder, or every OGUI start would ask
## again. One run at a time (ScreenScraper's anonymous limit is 1 thread, the tool locks its media
## folder); a ROM asked for twice (several layouts, several grids) is fetched once. A Settings run
## going (`other`) is waited for first. A run that could not reach or use ScreenScraper (network,
## quota, login, closed, no developer login) holds every fetch for HOLD_SECONDS: offline, each new
## card would otherwise wait for curl's timeouts. No OGUI types: tested on a stock Godot
## (tests/test-plugin.sh) against a fake tool.

## A fetch ended: its "system/rom file" key.
signal fetched(key: String)

const ScrapeRunner := preload("scrape_runner.gd")
## Seconds fetches are held after a run that could not reach or use ScreenScraper.
const HOLD_SECONDS := 600
## Exit codes that hold: network, local (no space), quota, login refused, closed, no developer login.
const HOLD_CODES := [-1, 3, 5, 6, 7, 8, 9]

var runner := ScrapeRunner.new()
## The Settings section's runner (scraper_settings.gd): its run is waited for.
var other: ScrapeRunner
## Whether fetching is allowed now (the "Scrape new games automatically" setting, a build that
## can scrape). Unset: never.
var allowed := Callable()
var cache_path := OS.get_environment("HOME").path_join(".cache/retroforge/scrape.json")
var _queue: Array[PackedStringArray] = []  # [system, rom]
var _pending := {}  # key -> true, queued or running
var _working := false
var _held_until := 0
var _tried := {}  # the tool's cache "roms" keys, re-read when the file changes
var _tried_mtime := -1


## The cache key of a ROM (a file, or a game folder), as retroforge-scrape writes it.
static func key_of(system: String, rom: String) -> String:
	return "%s/%s" % [system, rom.trim_suffix("/").get_file()]


## Fetch the art of `rom` if it is wanted, and return once that fetch ended (at once when not).
func fetch(system: String, rom: String) -> void:
	var key := key_of(system, rom)
	if not _pending.has(key):
		if system == "ports" or not _may_fetch() or tried(key):
			return
		_pending[key] = true
		_queue.append(PackedStringArray([system, rom.trim_suffix("/")]))
		_pump()
	while _pending.has(key):
		await fetched


## Whether retroforge-scrape already has an entry for this key (found, not found, art missing).
func tried(key: String) -> bool:
	var mtime := FileAccess.get_modified_time(cache_path) if FileAccess.file_exists(cache_path) else 0
	if mtime != _tried_mtime:
		_tried_mtime = mtime
		_tried = {}
		var data = JSON.parse_string(FileAccess.get_file_as_string(cache_path)) if mtime else null
		if data is Dictionary and data.get("roms") is Dictionary:
			_tried = data["roms"]
	return _tried.has(key)


func _may_fetch() -> bool:
	return allowed.is_valid() and allowed.call() and Time.get_unix_time_from_system() >= _held_until


func _pump() -> void:
	if _working:
		return
	_working = true
	while not _queue.is_empty():
		var job: PackedStringArray = _queue.pop_front()
		var key := key_of(job[0], job[1])
		if _may_fetch():
			await _run(job[1])
		_pending.erase(key)
		fetched.emit(key)
	_working = false


func _run(rom: String) -> void:
	for attempt in 2:
		if other and other.running:
			await other.finished
		runner.start(["run", "--rom", rom])
		var res: Array = await runner.finished
		var code: int = res[0]
		# The tool's lock: a Settings run started between our check and our start. Wait for it, once.
		if code == 5 and "another scrape" in str(res[2]) and attempt == 0:
			continue
		# A ROM whose lookup the network lost is "failed" in a run that exits 0.
		if code in HOLD_CODES or int(res[1].get("failed", 0)) > 0:
			_held_until = int(Time.get_unix_time_from_system()) + HOLD_SECONDS
		return
