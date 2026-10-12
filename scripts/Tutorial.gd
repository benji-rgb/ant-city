class_name Tutorial
extends Control
## v6: short, skippable step-by-step tutorial. Each step advances on a real player action (or a
## Next button for the "just look" steps); the relevant HUD button pulses. Completion is stored in
## user://settings.cfg ("tutorial/done") and the tutorial is offered on the first launch.

const SETTINGS_PATH := "user://settings.cfg"

var main: Node              # Main (tool, overlay, colony, ui)
var persist := true         # false in self-tests: do not touch the settings file
var step := -1              # -1 = not running
var done_once := false
var _panel: Panel
var _title: Label
var _body: Label
var _next: Button
var _skip: Button
var _t := 0.0
var _base := {}             # counters captured when a step starts

# [title, text, highlight id, needs Next button]
const STEPS := [
	["Welcome to Ant City!", "A young queen has sealed herself underground with a handful of tiny first workers and a little food.\nYou don't steer ants: you tell the colony where to dig and what to build. This view is a slice through the soil.", "", true],
	["1. Dig a tunnel", "Press 2 (or the Dig button), then drag across the soil next to the queen chamber.\nWorkers will dig every orange cell you paint.", "dig", false],
	["2. Build a Nursery", "Press 3 (Nursery) and click next to a tunnel. A green ghost means OK (R rotates it).\nNurses will move the eggs and larvae there - it is warmer and safer than the queen's room.", "nursery", false],
	["3. Build a Food Storage", "Press 4 (Storage) and place it next to a tunnel. Until it exists the little reserve lives in the queen chamber.", "storage", false],
	["4. Watch the foragers", "Foragers search the surface for sugar and protein and lay scent trails home.\nPress P (Trails) to see them: yellow sugar, pink protein, blue the way home.", "trails", false],
	["5. Build a Waste chamber", "Press 5 (Waste) and place it a bit away from the nursery. Cleaners carry refuse there; a dirty nest makes brood sick.", "waste", false],
	["6. Give orders", "Press O (Orders). Set job priorities (or a preset), and choose what new eggs become: Auto, or your Worker : Soldier : Gyne ratio.\nRaise 3 gynes (winged queens) for a Nuptial flight - your big goal.", "orders", false],
	["7. Alarms and filling", "When danger shows up, a red ALARM banner appears: pick Fight, Seal entrances or Evacuate brood (the Orders panel sets the default).\nFill [6/F] packs unwanted tunnels with soil again; red cells tell you why not.", "fill", true],
	["8. You're ready!", "Threats sets the difficulty. Save with K, load with L, Tab shows all keys.\nGood luck, Your Majesty!", "save", true],
]

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel = Panel.new()
	_panel.position = Vector2(520, 556)
	_panel.size = Vector2(560, 132)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.09, 0.06, 0.93)
	sb.border_color = Color(1.0, 0.8, 0.35)
	sb.set_border_width_all(2)
	sb.set_corner_radius_all(6)
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)
	_title = Label.new()
	_title.position = Vector2(12, 6)
	_title.add_theme_font_size_override("font_size", 16)
	_title.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	_panel.add_child(_title)
	_body = Label.new()
	_body.position = Vector2(12, 30)
	_body.size = Vector2(536, 66)
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_body.add_theme_font_size_override("font_size", 12)
	_panel.add_child(_body)
	_next = _btn("Next", Vector2(462, 100), func() -> void: advance())
	_skip = _btn("Skip tutorial", Vector2(12, 100), func() -> void: skip())
	visible = false

func _btn(text: String, pos: Vector2, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = Vector2(86 if text == "Next" else 110, 24)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 12)
	b.pressed.connect(cb)
	_panel.add_child(b)
	return b

# ------------------------------------------------------------------ settings
static func is_done() -> bool:
	var cf := ConfigFile.new()
	if cf.load(SETTINGS_PATH) != OK:
		return false
	return bool(cf.get_value("tutorial", "done", false))

func _mark_done() -> void:
	done_once = true
	if not persist:
		return
	var cf := ConfigFile.new()
	cf.load(SETTINGS_PATH)
	cf.set_value("tutorial", "done", true)
	cf.save(SETTINGS_PATH)

# ------------------------------------------------------------------ flow
func start() -> void:
	_go(0)

func running() -> bool:
	return step >= 0

func skip() -> void:
	step = -1
	visible = false
	_mark_done()
	if main != null:
		main.colony.log_event("Tutorial skipped - press the Tutorial button to see it again.", "help")

func advance() -> void:
	if step < 0:
		return
	if step + 1 >= STEPS.size():
		step = -1
		visible = false
		_mark_done()
		if main != null:
			main.colony.log_event("Tutorial complete!", "help")
		return
	_go(step + 1)

func _go(i: int) -> void:
	step = i
	visible = true
	var s: Array = STEPS[i]
	_title.text = "%s   (%d/%d)" % [s[0], i + 1, STEPS.size()]
	_body.text = s[1]
	_next.visible = s[3]
	_next.text = "Finish" if i == STEPS.size() - 1 else "Next"
	_skip.visible = i < STEPS.size() - 1
	var c: Colony = main.colony if main != null else null
	if c != null:
		_base = {"orders": c.dig_tasks.size(), "dug": c.total_dug, "foraged": c.total_foraged}
		if main.ui.help_panel.visible:
			main.ui.hide_help()

func _has_room(type: int) -> bool:
	for r in main.colony.rooms:
		if r.type == type:
			return true
	return false

## The action that finishes the current step happened?
func _step_done() -> bool:
	var c: Colony = main.colony
	match step:
		1: return c.dig_tasks.size() >= 2 or c.total_dug > int(_base.get("dug", 0))
		2: return _has_room(Room.Type.NURSERY)
		3: return _has_room(Room.Type.FOOD_STORAGE)
		4: return main.overlay.show_phero or c.total_foraged > float(_base.get("foraged", 0.0)) + 6.0
		5: return _has_room(Room.Type.WASTE)
		6: return main.ui.orders_panel.visible
	return false

func _process(delta: float) -> void:
	if step < 0 or main == null:
		return
	_t += delta
	poll()
	queue_redraw()

## Advance if the current step's action was done (also called directly by the self-test).
func poll() -> void:
	if step >= 0 and not STEPS[step][3] and _step_done():
		advance()

func _target() -> Control:
	var ui: Node = main.ui
	match String(STEPS[step][2]):
		"dig": return ui.tool_buttons[1]
		"nursery": return ui.tool_buttons[2]
		"storage": return ui.tool_buttons[3]
		"waste": return ui.tool_buttons[4]
		"trails": return ui.phero_button
		"save": return ui.save_button
		"orders": return ui.soldier_button
		"fill": return ui.tool_buttons[5]
	return null

func _draw() -> void:
	if step < 0:
		return
	var t := _target()
	if t == null:
		return
	var r := t.get_global_rect().grow(3.0 + 2.0 * sin(_t * 6.0))
	r.position -= get_global_rect().position
	draw_rect(r, Color(1.0, 0.85, 0.3, 0.9), false, 3.0)
