extends RefCounted
## Runs /usr/bin/retroforge-scrape for the Scraper settings and the game page (plan scraper Phase 3).
##
## Not OGUI's Command: that hands stdout over only once the process ends and has no stdin, and a
## scrape reports `N%` as it goes while `login` reads the password on stdin (never argv). So the
## tool runs on a worker thread through OS.execute_with_pipe: stdout is read line by line, stderr on
## a second task at the same time (thousands of warnings would otherwise fill its pipe and stall the
## tool), and the results come back to the main thread as signals. Cancel is SIGTERM, which the tool
## turns into a clean stop (cache written, summary printed, exit 5). No OGUI types: tested on a
## stock Godot (tests/test-plugin.sh) against a fake tool.

## A `N%` line of the running tool.
signal progressed(percent: int)
## The tool ended: its exit code (-1 when it could not start), its JSON summary ({} when it printed
## none), and its last stderr line ("" on success).
signal finished(code: int, summary: Dictionary, error: String)

const TOOL := "/usr/bin/retroforge-scrape"
const PREFIX := "retroforge-scrape: "

var tool := TOOL
var running := false
## On threads of its own, not the shared worker pool: a run lasts as long as the tool (an install:
## minutes), and its two pipe readers held both of the pool's low-priority threads, so every card's
## art load waited behind them: all tabs showed empty cards until an install ended (issue #32).
var _thread: Thread
var _pid := -1


## Start the tool with `args`; `stdin_text` (a password) is written as one line. False when a run
## is already going.
func start(args: Array, stdin_text := "") -> bool:
	if running:
		return false
	running = true
	_pid = -1
	_thread = Thread.new()
	_thread.start(_run.bind(PackedStringArray(args), stdin_text))
	return true


## Ask the running tool to stop (SIGTERM); `finished` follows with its summary and exit 5.
func cancel() -> void:
	if running and _pid > 0:
		OS.execute("kill", ["-TERM", str(_pid)])


# Its own thread.
func _run(args: PackedStringArray, stdin_text: String) -> void:
	# Godot forks before it tries the program: a missing one still "runs" and exits 9, which is the
	# tool's own "no developer login" code. So it must exist first.
	var pipe := OS.execute_with_pipe(tool, args, true) if FileAccess.file_exists(tool) else {}
	if pipe.is_empty():
		_end.call_deferred(-1, {}, "")
		return
	_pid = pipe["pid"]
	var io: FileAccess = pipe["stdio"]
	var errors: Array[String] = []
	var err_thread := Thread.new()
	err_thread.start(_drain.bind(pipe["stderr"], errors))
	if stdin_text != "":
		io.store_string(stdin_text + "\n")
		io.flush()
	var summary := {}
	while true:
		var line := io.get_line()
		if line == "" and io.get_error() != OK:
			break
		var parsed := parse_line(line)
		if parsed.has("percent"):
			progressed.emit.call_deferred(parsed["percent"])
		elif parsed.has("summary"):
			summary = parsed["summary"]
	err_thread.wait_to_finish()
	while OS.is_process_running(_pid):
		OS.delay_msec(10)
	var code := OS.get_process_exit_code(_pid)
	_end.call_deferred(code, summary, "" if code == 0 or errors.is_empty() else errors[-1])


# A thread of its own: read stderr to its end, keeping its lines.
static func _drain(err: FileAccess, lines: Array[String]) -> void:
	while true:
		var line := err.get_line()
		if line == "" and err.get_error() != OK:
			return
		if line != "":
			lines.append(line)


func _end(code: int, summary: Dictionary, error: String) -> void:
	if _thread:
		_thread.wait_to_finish()
		_thread = null
	running = false
	_pid = -1
	finished.emit(code, summary, error)


## {"percent": N} for a `N%` line, {"summary": {...}} for the JSON summary, {} for anything else.
static func parse_line(line: String) -> Dictionary:
	var text := line.strip_edges()
	if text.ends_with("%") and text.trim_suffix("%").is_valid_int():
		var pct := text.trim_suffix("%").to_int()
		return {"percent": pct} if pct >= 0 and pct <= 100 else {}
	if text.begins_with("{"):
		var data = JSON.parse_string(text)
		if data is Dictionary:
			return {"summary": data}
	return {}


## What a finished run achieved, for a notification.
static func summary_text(summary: Dictionary) -> String:
	var scraped := int(summary.get("scraped", 0))
	var missing := int(summary.get("not_found", 0))
	var failed := int(summary.get("failed", 0))
	if scraped == 0 and missing == 0 and failed == 0:
		return "No new art: every game is up to date."
	var parts := PackedStringArray()
	parts.append("Art for %d game%s." % [scraped, "" if scraped == 1 else "s"])
	if missing:
		parts.append("%d not found on ScreenScraper." % missing)
	if failed:
		parts.append("%d failed: try again later." % failed)
	return " ".join(parts)


## What a failed run tells the player, from the tool's exit code (retroforge-scrape's header) and
## its last stderr line (the tool's own English reason, for quota and closed).
static func failure_text(code: int, error: String) -> String:
	var reason := error.strip_edges().get_slice("\n", error.strip_edges().count("\n")).trim_prefix(PREFIX)
	match code:
		3:
			return "ScreenScraper could not be reached. Check the network and try again."
		5:
			if "cancelled" in reason:
				return "Cancelled."
			if "another scrape" in reason:
				return "A scrape is already running."
			return "Not enough space to save the art."
		6, 8:
			return reason if reason != "" else "ScreenScraper refused the request. Try again later."
		7:
			return "ScreenScraper refused your user name or password."
		9:
			return "This RetroForge build cannot scrape ROM art (it has no ScreenScraper developer login)."
	return "Scraping failed (%d)." % code
