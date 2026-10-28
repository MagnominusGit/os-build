#!/usr/bin/env bash
# Offline test for the logic our OpenGamepadUI patches add, run on a stock Godot.
#
#   tests/test-ogui-patches.sh        (RETROFORGE_GODOT=<godot 4 binary>, or godot on PATH)
#
# WHY THIS EXISTS. A patch's GDScript only runs once the pck is rebuilt and booted, and what it
# gets wrong shows only on a device with the right library. A new file a patch adds needs no OGUI
# types to test, so it is taken out of the COMMITTED patch and run here:
#
#   - 0032 CardArtWindow: a card's art loads within a screen of the visible part and goes past three
#     screens or after the container has been hidden a while. Loading too little shows empty cards;
#     dropping too little keeps a whole library's art in GPU memory (872 MiB, 1,000 games, Air X).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PATCHES="$ROOT/packages/opengamepadui/patches"
P0032="$PATCHES/0032-card-art-only-near-the-screen.patch"

PASS=0; FAIL=0; CASE=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s -- %s\n' "$CASE" "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s -- %s\n' "$CASE" "$1"; }

[ -f "$P0032" ] || { echo "missing input: $P0032" >&2; exit 1; }
T="$(mktemp -d)" && [ -d "$T" ] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT

# A file the patch adds, as the patch has it: the "+" lines after its "+++ b/<path>" header.
added_file() {
  awk -v path="+++ b/$2" '$0 == path { f = 1; next } f && /^@@/ { next } f && /^\+/ { print substr($0, 2); next } f { exit }' "$1"
}

CASE="card art window (0032)"
GODOT="${RETROFORGE_GODOT:-$(command -v godot || true)}"
if [ -z "$GODOT" ]; then
  printf '  skip %s -- no Godot (set RETROFORGE_GODOT to a Godot 4 binary)\n' "$CASE"
else
  added_file "$P0032" core/ui/components/card_art_window.gd > "$T/card_art_window.gd"
  grep -q '^class_name CardArtWindow$' "$T/card_art_window.gd" \
    && ok "the patch adds core/ui/components/card_art_window.gd" || bad "card_art_window.gd not found in the patch"
  printf 'config_version=5\n[application]\nconfig/name="ogui-patches-test"\n' > "$T/project.godot"
  cat > "$T/card_art_test.gd" <<GD
extends SceneTree
# 60 fake cards, 100 px high, in a 300 px ScrollContainer.

const CardArtWindow := preload("res://card_art_window.gd")
var failed := 0


class FakeCard extends Control:
	var loads := 0
	var releases := 0
	var shown := false

	func _enter_tree() -> void:
		var window = CardArtWindow.of(self)
		if window:
			window.add(self)

	func load_art() -> void:
		loads += 1
		shown = true

	func release_art() -> void:
		releases += 1
		shown = false


func check(what: String, got, want) -> void:
	if got == want:
		print("  ok   $CASE -- ", what)
	else:
		failed += 1
		print("  FAIL $CASE -- ", what, ": got ", got, ", want ", want)


func shown(cards: Array) -> Array:
	var out := []
	for i in cards.size():
		if cards[i].shown:
			out.append(i)
	return out


func frames(n := 3) -> void:
	for i in n:
		await process_frame


func _initialize() -> void:
	run()


func run() -> void:
	var holder := Control.new()
	root.add_child(holder)
	var scroll := ScrollContainer.new()
	scroll.size = Vector2(200, 300)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	holder.add_child(scroll)
	var grid := VBoxContainer.new()
	grid.add_theme_constant_override("separation", 0)
	scroll.add_child(grid)
	var cards := []
	for i in 60:
		var card := FakeCard.new()
		card.custom_minimum_size = Vector2(100, 100)
		grid.add_child(card)
		cards.append(card)
	await frames()
	check("only the cards within a screen of the visible part load (rows 0-5 of 60)", shown(cards), range(0, 6))
	scroll.scroll_vertical = 3000
	await frames()
	var now := shown(cards)
	check("scrolled to row 30: the rows within a screen load, edges exclusive",
		[27 in now, 30 in now, 35 in now, 26 in now, 36 in now], [true, true, true, false, false])
	check("and the first rows, past three screens, drop their art", [cards[0].shown, cards[0].releases], [false, 1])
	scroll.scroll_vertical = 2400
	await frames()
	check("rows past a screen but within three keep theirs", [cards[35].shown, cards[35].releases], [true, 0])
	CardArtWindow.of(cards[0]).hidden_release = 0.3
	holder.visible = false
	await create_timer(0.1).timeout
	check("a hidden container (its parent hidden) keeps its art a while", shown(cards).is_empty(), false)
	await create_timer(0.4).timeout
	check("then drops it all", shown(cards), [])
	holder.visible = true
	await frames()
	check("shown again, the rows on screen load again", 24 in shown(cards), true)
	cards[25].visible = false
	cards[26].visible = false
	await frames()
	scroll.scroll_vertical = 0
	await frames()
	check("hidden cards are skipped and the window still finds its rows", shown(cards).slice(0, 3), [0, 1, 2])
	# A tab built while hidden: its grid never placed its cards (all at 0) until it is shown. Read
	# then, every card looked on screen and all 1,000 loaded at once (Air X, 2026-10-24).
	var holder2 := Control.new()
	holder2.visible = false
	root.add_child(holder2)
	var scroll2 := ScrollContainer.new()
	scroll2.size = Vector2(200, 300)
	scroll2.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	holder2.add_child(scroll2)
	var grid2 := VBoxContainer.new()
	grid2.add_theme_constant_override("separation", 0)
	scroll2.add_child(grid2)
	var cards2 := []
	for i in 60:
		var card := FakeCard.new()
		card.custom_minimum_size = Vector2(100, 100)
		grid2.add_child(card)
		cards2.append(card)
	await frames()
	holder2.visible = true
	await frames(5)
	var loads := 0
	for card in cards2:
		loads += card.loads
	check("a tab built while hidden, then shown: only its first rows ever load, not all 60", [loads, shown(cards2)], [6, range(0, 6)])
	quit(1 if failed else 0)
GD
  out="$(HOME="$T/home" XDG_CONFIG_HOME="$T/config" timeout 60 "$GODOT" --headless --path "$T" --script res://card_art_test.gd 2>&1)"; rc=$?
  printf '%s\n' "$out" | grep -E '^  (ok|FAIL) '
  n_ok="$(printf '%s\n' "$out" | grep -c '^  ok ')"; n_bad="$(printf '%s\n' "$out" | grep -c '^  FAIL ')"
  PASS=$((PASS + n_ok)); FAIL=$((FAIL + n_bad))
  if [ "$rc" -ne 0 ] && [ "$n_bad" -eq 0 ]; then
    bad "Godot failed (rc $rc): $(printf '%s\n' "$out" | grep -E 'ERROR|error' | head -3)"
  fi
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
