extends RefCounted
## The plugin's way to retroforge-paneld (org.retroforge.Panel1 on the system bus): the panel's
## measured refresh rate and, on a panel with frame_len_* knobs, its frame-length calibration
## (docs/panel-calibration.md). The daemon is root because the knobs are; the bus policy lets
## player (wheel) call it, and the first call starts it.
##
## busctl, as in power_client.gd, but never on the UI thread: a measured status waits ~0.5 s of
## vblanks and a calibration up to a minute. One call at a time, on a worker thread; the answer
## comes back on the main thread as a signal. No OGUI types: tested on a stock Godot
## (tests/test-plugin.sh) against the real daemon on a session bus.

## Status(measure): retroforge_panel.status() as a Dictionary, or {"error": ...}.
signal status_received(status: Dictionary)
## Calibrate(): {rate, value, startValue, startHz, endHz}, or {"error": ...}.
signal calibrated(result: Dictionary)

const DEST := ["org.retroforge.Panel", "/org/retroforge/Panel", "org.retroforge.Panel1"]
# Above calibrate()'s own 60 s deadline plus its settle sleeps; busctl's default is 25 s.
const TIMEOUT_S := 120

var bus := "--system"  # the test points it at its private session bus with --user
var busy := false
# Held while a call runs: the worker's Callable does not keep this object alive, and the card
# that owns it can be freed mid-call (plugin reload during a minute-long calibration).
var _keepalive: RefCounted


## Ask for the status; `measure` adds the measured rate. False while another call is running.
func request_status(measure: bool) -> bool:
	return _start(["Status", "b", "true" if measure else "false"], status_received)


## Trim the rate the panel is scanning now. False while another call is running.
func request_calibrate() -> bool:
	return _start(["Calibrate"], calibrated)


func _start(call_args: Array, done: Signal) -> bool:
	if busy:
		return false
	busy = true
	_keepalive = self
	var args := [bus, "--json=short", "--timeout=%d" % TIMEOUT_S, "call"]
	args.append_array(DEST)
	args.append_array(call_args)
	WorkerThreadPool.add_task(_run.bind(args, done))
	return true


# Worker thread.
func _run(args: Array, done: Signal) -> void:
	var out := []
	var code := OS.execute("busctl", args, out, true)
	_end.call_deferred(parse_reply(code, "".join(out)), done)


func _end(result: Dictionary, done: Signal) -> void:
	busy = false
	_keepalive = null
	done.emit(result)


## busctl --json=short prints {"type":"s","data":["<the daemon's JSON>"]}; a failed call exits
## nonzero with "Call failed: <message>" (the daemon's own text for Error.Failed/Busy).
static func parse_reply(code: int, text: String) -> Dictionary:
	if code != 0:
		var reason := text.strip_edges().trim_prefix("Call failed: ")
		return {"error": reason if reason != "" else "busctl exited %d" % code}
	var reply = JSON.parse_string(text.strip_edges())
	if reply is Dictionary and reply.get("data") is Array and not reply["data"].is_empty():
		var data = JSON.parse_string(str(reply["data"][0]))
		if data is Dictionary:
			return data
	return {"error": "unexpected reply: %s" % text.strip_edges().left(120)}


## "118.35 Hz · nominal 120 (-1.65)"; just the rate when it matches no knob; the reason it could
## not be measured ("" when there is none).
static func format_rate(status: Dictionary) -> String:
	if status.get("measuredHz") == null:
		return str(status.get("measureError", ""))
	var measured := float(status["measuredHz"])
	var text := "%.2f Hz" % measured
	if status.get("nominalHz") != null:
		var deviation := measured - float(status["nominalHz"])
		text += " · nominal %d (%s%.2f)" % [int(status["nominalHz"]), "+" if deviation >= 0 else "", deviation]
	return text


## "120 Hz: calibrated · 60 Hz: factory", highest rate first; "" on a panel without knobs.
static func format_saved(status: Dictionary) -> String:
	if not status.get("supported", false):
		return ""
	var rates: Array = status.get("rates", []).duplicate()
	rates.sort()
	rates.reverse()
	var saved: Dictionary = status.get("saved", {})
	var parts := PackedStringArray()
	for rate in rates:
		parts.append("%d Hz: %s" % [int(rate), "calibrated" if saved.has(str(int(rate))) else "factory"])
	return " · ".join(parts)


## What a calibration did, for the line under the button.
static func format_result(result: Dictionary) -> String:
	if result.has("error"):
		return "Calibration failed: %s" % result["error"]
	return "%d Hz calibrated: %.2f → %.2f Hz" % [int(result.get("rate", 0)), float(result.get("startHz", 0)), float(result.get("endHz", 0))]
