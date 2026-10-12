class_name GameUI
extends CanvasLayer
## Code-built HUD: stats panel, tool / option buttons, info panel, event log, help overlay.

signal tool_selected(tool_id: int)
signal speed_selected(speed: float)
signal pause_toggled()
signal overlay_toggled()
signal climate_toggled()
signal soldier_mode_pressed()
signal threat_pressed()
signal save_pressed()
signal load_pressed()
signal help_toggled()
signal sound_pressed()

const ICON_DIR := "res://assets/icons/"
const TOOL_ICONS := ["select", "dig", "nursery", "food_storage", "waste_chamber"]
const STAT_ICONS := ["climate", "worker", "soldier", "nursery", "food"]
const LOG_ICON_PX := 14
const TOOL_LABELS := ["Select [1]", "Dig [2]", "Nursery [3]", "Storage [4]", "Waste [5]"]
const TOOL_HINTS := [
	"SELECT: click an ant, brood or chamber to inspect it.",
	"DIG: left-drag paints dig orders (must touch a tunnel / the surface). Right-drag cancels.",
	"NURSERY: click to plan a chamber (R rotates). Deeper = steadier climate. Right-click cancels a plan.",
	"STORAGE: click to plan a food chamber (R rotates). Holds sugar + protein.",
	"WASTE: click to plan a waste chamber (R rotates). Cleaners carry refuse and corpses here.",
]
const HELP_TEXT := """ANT CITY - how to play

You guide a colony; the ants decide for themselves. Nothing here is a unit you command.

TOOLS (keys 1-5)   Select / Dig / Nursery / Storage / Waste
  Dig: drag over soil next to a tunnel (or the grass) to order tunnels. Right-drag cancels.
  Chambers: click to plan, workers dig it out, then it works. R rotates. Right-click cancels a plan.

KEYS   Space pause   - / + speed   P pheromone trails   H climate overlay
       K save   L load   Tab or ? this help   M mute   [ ] volume   F3 debug info   Esc back to Select

WHAT THE ANTS DO
  Young workers nurse, middle-aged dig and clean, older ones forage (any age forages when food runs low).
  Foragers look for SUGAR (fuel for workers) or PROTEIN (eggs and larvae) and follow trails (P overlay):
  yellow = sugar trail, pink = protein trail, red = alarm.
  The queen lays eggs in her chamber; nurses carry them to a nursery and feed the larvae protein.
  Cleaners carry refuse and corpses to a Waste chamber (or dump them outside). Dirt = sick brood.
  Deeper chambers are damper and steadier in temperature: brood grows faster there (H overlay).

DANGER   Spiders and rival scouts sometimes roam the surface and kill foragers.
  Workers that see one raise the alarm; Soldiers (made when threatened, or when food is plentiful)
  hurry there and fight. Buttons: Soldiers Auto/Off/Max, Threats Off/Gentle/Normal.

Click an ant, larva or chamber (Select tool) to see details in the top-right box."""

var stats_label: Label
var stat_icons: Array[TextureRect] = []
var warn_icon: TextureRect
var sound_button: Button
var _icon_cache := {}
var info_label: Label
var hint_label: Label
var log_label: RichTextLabel
var help_panel: Panel
var tool_buttons: Array[Button] = []
var speed_buttons: Array[Button] = []
var pause_button: Button
var phero_button: Button
var climate_button: Button
var soldier_button: Button
var threat_button: Button
var save_button: Button
var help_button: Button
var tutorial_button: Button
var debug_label: Label
var _debug_t := 0.0
signal tutorial_pressed()
var _help_t := 0.0
var _last_log := ""

func _ready() -> void:
	layer = 10
	_build()

func _panel(pos: Vector2, size: Vector2, alpha := 0.78) -> Panel:
	var p := Panel.new()
	p.position = pos
	p.size = size
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.05, 0.04, alpha)
	sb.border_color = Color(0.85, 0.7, 0.4, 0.8)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(5)
	p.add_theme_stylebox_override("panel", sb)
	add_child(p)
	return p

func _label(parent: Control, pos: Vector2, size: Vector2, fsize: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.size = size
	l.add_theme_font_size_override("font_size", fsize)
	l.add_theme_color_override("font_color", Color(0.97, 0.94, 0.85))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l

## Icon from assets/icons/ or null when the file is missing (the HUD then just shows text).
func icon(n: String) -> Texture2D:
	if _icon_cache.has(n):
		return _icon_cache[n]
	var path := "%s%s.png" % [ICON_DIR, n]
	var t: Texture2D = null
	if ResourceLoader.exists(path):
		t = load(path) as Texture2D
	_icon_cache[n] = t
	return t

func _set_icon(b: Button, n: String, px := 20) -> void:
	var t := icon(n)
	if t == null:
		return
	b.icon = t
	b.expand_icon = true
	b.icon_alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.add_theme_constant_override("icon_max_width", px)
	b.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS

func _button(parent: Control, text: String, pos: Vector2, size: Vector2, toggle: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.position = pos
	b.size = size
	b.toggle_mode = toggle
	b.focus_mode = Control.FOCUS_NONE     # so Space never "presses" a focused button
	b.add_theme_font_size_override("font_size", 12)
	parent.add_child(b)
	return b

func _build() -> void:
	var stats := _panel(Vector2(8, 6), Vector2(404, 118))
	stats_label = _label(stats, Vector2(26, 3), Vector2(374, 112), 12)
	stats_label.text = "x\nx\nx\nx\nx\nx"
	var lh := stats_label.get_minimum_size().y / 6.0     # measured line pitch of the stats text
	for i in STAT_ICONS.size() + 1:
		var tr := TextureRect.new()
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE    # must be set before the texture, or the rect grows to 64 px
		tr.custom_minimum_size = Vector2(13, 13)
		tr.texture = icon(STAT_ICONS[i] if i < STAT_ICONS.size() else "alert")
		tr.position = Vector2(6, 3 + i * lh + (lh - 13.0) / 2.0 + 1.0)
		tr.size = Vector2(13, 13)
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stats.add_child(tr)
		if i < STAT_ICONS.size():
			stat_icons.append(tr)
		else:
			warn_icon = tr
			tr.visible = false

	var bar := _panel(Vector2(420, 6), Vector2(566, 118))
	var tool_group := ButtonGroup.new()
	for i in TOOL_LABELS.size():
		var b := _button(bar, TOOL_LABELS[i], Vector2(6 + i * 111, 6), Vector2(107, 26), true)
		b.button_group = tool_group
		_set_icon(b, TOOL_ICONS[i])
		b.tooltip_text = TOOL_HINTS[i]
		b.pressed.connect(_on_tool_pressed.bind(i))
		tool_buttons.append(b)
	tool_buttons[0].set_pressed_no_signal(true)
	var speed_group := ButtonGroup.new()
	pause_button = _button(bar, "Pause [Space]", Vector2(6, 36), Vector2(104, 26), true)
	pause_button.pressed.connect(func() -> void: pause_toggled.emit())
	_set_icon(pause_button, "pause")
	pause_button.tooltip_text = "Pause / resume the simulation (Space)."
	var speeds := [1.0, 2.0, 4.0]
	for i in speeds.size():
		var b := _button(bar, "%dx" % int(speeds[i]), Vector2(114 + i * 40, 36), Vector2(38, 26), true)
		b.button_group = speed_group
		_set_icon(b, "speed_%dx" % int(speeds[i]), 22)
		if b.icon != null:
			b.text = ""
			b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.tooltip_text = "Simulation speed %dx (- / + keys)." % int(speeds[i])
		b.pressed.connect(func() -> void: speed_selected.emit(speeds[i]))
		speed_buttons.append(b)
	speed_buttons[0].set_pressed_no_signal(true)
	phero_button = _button(bar, "Trails [P]", Vector2(238, 36), Vector2(100, 26), true)
	phero_button.pressed.connect(func() -> void: overlay_toggled.emit())
	_set_icon(phero_button, "trails")
	phero_button.tooltip_text = "Show pheromone trails: yellow sugar, pink protein, red alarm (P)."
	climate_button = _button(bar, "Climate [H]", Vector2(342, 36), Vector2(108, 26), true)
	climate_button.pressed.connect(func() -> void: climate_toggled.emit())
	_set_icon(climate_button, "climate")
	climate_button.tooltip_text = "Temperature / humidity overlay with brood comfort (H)."
	var help_b := _button(bar, "Help [Tab]", Vector2(454, 36), Vector2(104, 26), false)
	help_button = help_b
	help_b.pressed.connect(func() -> void: help_toggled.emit())
	_set_icon(help_b, "help")
	help_b.tooltip_text = "Show / hide the help text (Tab or ?)."
	soldier_button = _button(bar, "Soldiers: Auto", Vector2(6, 66), Vector2(150, 26), false)
	soldier_button.pressed.connect(func() -> void: soldier_mode_pressed.emit())
	_set_icon(soldier_button, "guard")
	soldier_button.tooltip_text = "Soldier production: Auto (when threatened / food is plentiful), Off, or Max."
	threat_button = _button(bar, "Threats: Gentle", Vector2(160, 66), Vector2(150, 26), false)
	threat_button.pressed.connect(func() -> void: threat_pressed.emit())
	_set_icon(threat_button, "threat_spider")
	threat_button.tooltip_text = "Surface predators: Off, Gentle or Normal."
	var save_b := _button(bar, "Save [K]", Vector2(314, 66), Vector2(120, 26), false)
	save_button = save_b
	save_b.pressed.connect(func() -> void: save_pressed.emit())
	_set_icon(save_b, "save")
	save_b.tooltip_text = "Save the colony to user://antcity_save.json (K)."
	var load_b := _button(bar, "Load [L]", Vector2(438, 66), Vector2(120, 26), false)
	load_b.pressed.connect(func() -> void: load_pressed.emit())
	_set_icon(load_b, "load")
	load_b.tooltip_text = "Load the saved colony (L)."
	hint_label = _label(bar, Vector2(8, 96), Vector2(552, 20), 11)
	hint_label.clip_text = true

	var info := _panel(Vector2(994, 6), Vector2(278, 118))
	info_label = _label(info, Vector2(8, 3), Vector2(264, 112), 11)
	info_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	var logp := _panel(Vector2(8, 720 - 8 - 116), Vector2(500, 116), 0.55)
	logp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	log_label = RichTextLabel.new()
	log_label.position = Vector2(6, 3)
	log_label.size = Vector2(488, 110)
	log_label.bbcode_enabled = true
	log_label.scroll_active = false
	log_label.fit_content = false
	log_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	log_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	log_label.add_theme_font_size_override("normal_font_size", 11)
	log_label.add_theme_color_override("default_color", Color(0.97, 0.94, 0.85))
	logp.add_child(log_label)

	sound_button = Button.new()
	sound_button.position = Vector2(1128, 686)
	sound_button.size = Vector2(144, 26)
	sound_button.focus_mode = Control.FOCUS_NONE
	sound_button.add_theme_font_size_override("font_size", 12)
	sound_button.tooltip_text = "Click or press M to mute. [ and ] change the master volume."
	sound_button.pressed.connect(func() -> void: sound_pressed.emit())
	add_child(sound_button)
	tutorial_button = Button.new()
	tutorial_button.text = "Tutorial"
	tutorial_button.position = Vector2(1128, 656)
	tutorial_button.size = Vector2(144, 26)
	tutorial_button.focus_mode = Control.FOCUS_NONE
	tutorial_button.add_theme_font_size_override("font_size", 12)
	tutorial_button.tooltip_text = "Start the short guided tutorial again."
	tutorial_button.pressed.connect(func() -> void: tutorial_pressed.emit())
	_set_icon(tutorial_button, "help", 18)
	add_child(tutorial_button)
	debug_label = Label.new()
	debug_label.position = Vector2(8, 104)
	debug_label.size = Vector2(360, 60)
	debug_label.add_theme_font_size_override("font_size", 11)
	debug_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(debug_label)
	debug_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	debug_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	debug_label.add_theme_constant_override("outline_size", 3)
	debug_label.visible = false

	help_panel = _panel(Vector2(190, 140), Vector2(900, 470), 0.9)
	help_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var hl := _label(help_panel, Vector2(16, 10), Vector2(870, 450), 13)
	hl.text = HELP_TEXT
	help_panel.visible = true
	_help_t = 25.0

func _process(delta: float) -> void:
	if help_panel.visible and _help_t > 0.0:
		_help_t -= delta
		if _help_t <= 0.0:
			help_panel.visible = false

func _on_tool_pressed(i: int) -> void:
	tool_selected.emit(i)

# ---------------------------------------------------------------- updates from Main
func show_tool(i: int) -> void:
	tool_buttons[i].set_pressed_no_signal(true)
	hint_label.text = TOOL_HINTS[i]

func show_speed(speed: float, paused: bool) -> void:
	pause_button.set_pressed_no_signal(paused)
	var idx := 0 if speed < 1.5 else (1 if speed < 3.0 else 2)
	speed_buttons[idx].set_pressed_no_signal(true)

func show_sound(audio: GameAudio) -> void:
	sound_button.text = audio.label()
	_set_icon(sound_button, "sound_off" if (audio.muted or not audio.enabled) else "sound_on", 18)
	var col := Color(1.0, 0.45, 0.4) if (audio.muted or not audio.enabled) else Color(0.97, 0.94, 0.85)
	sound_button.add_theme_color_override("font_color", col)
	sound_button.add_theme_color_override("font_hover_color", col)

func show_phero(on: bool) -> void:
	phero_button.set_pressed_no_signal(on)

func show_climate(on: bool) -> void:
	climate_button.set_pressed_no_signal(on)

func toggle_help() -> void:
	help_panel.visible = not help_panel.visible
	_help_t = 0.0

func hide_help() -> void:
	help_panel.visible = false
	_help_t = 0.0

func show_modes(colony: Colony) -> void:
	soldier_button.text = "Soldiers: %s" % Colony.SOLDIER_MODE_NAMES[colony.soldier_mode]
	threat_button.text = "Threats: %s" % Config.THREAT_NAMES[Config.threat_level]

@warning_ignore("integer_division")
func refresh(colony: Colony, speed: float, paused: bool, info: String) -> void:
	var t := int(colony.time)
	var tc := colony.task_counts
	var bc := colony.brood_counts
	var soldiers := colony.soldier_count()
	var txt := "Day %d   %d:%02d   %s    Surface %.0f C\n" % [colony.day(), t / 60, t % 60, "PAUSED" if paused else "%dx" % int(speed), Climate.temp(Config.SURFACE_ROW + 1, colony.time)]
	txt += "Workers %d (Nurse %d | Dig %d | Forage %d | Clean %d | Idle %d)\n" % [colony.worker_count(), tc[Ant.Task.NURSE], tc[Ant.Task.DIG], tc[Ant.Task.FORAGE], tc[Ant.Task.CLEAN], tc[Ant.Task.IDLE]]
	txt += "Soldiers %d (+%d brood, goal %d)   Hygiene %d%%\n" % [soldiers, colony.soldier_brood, colony.soldier_target(), roundi(colony.hygiene * 100.0)]
	txt += "Brood %d/%d (Eggs %d | Larvae %d | Pupae %d)\n" % [colony.brood.size(), colony.nursery_capacity, bc[0], bc[1], bc[2]]
	txt += "Sugar %.1f   Protein %.1f   / %.0f   Piles %d\n" % [colony.sugar_stock, colony.protein_stock, colony.food_capacity, colony.active_food_count()]
	var warn := ""
	if colony.ants.is_empty() and colony.brood.is_empty():
		warn = "THE COLONY HAS DIED OUT"
	elif colony.sugar_stock <= 0.01:
		warn = "NO SUGAR - workers are starving!"
	elif colony.protein_stock <= 0.01:
		warn = "NO PROTEIN - no eggs, larvae go hungry!"
	elif not colony.threats.is_empty():
		warn = "DANGER on the surface!" + ("  Alarm raised." if colony.alarm_active() else "")
	elif colony.intruder_count() > 0:
		warn = "INTRUDER in the nest! Workers and soldiers defend."
	elif colony.flooded_cells > 0:
		warn = "Flooding in shallow tunnels - brood moved deeper."
	elif colony.raining:
		warn = "Rain - the soil is getting wet."
	elif colony.hygiene < Config.HYGIENE_BAD:
		warn = "Dirty nest - brood is falling ill!"
	warn_icon.visible = warn != "" and warn_icon.texture != null
	if warn != "":
		txt += warn
	else:
		txt += "Born %d  Died %d  Dig orders %d  Threats %d" % [colony.total_born, colony.total_deaths, colony.dig_tasks.size(), colony.threats.size()]
	stats_label.text = txt
	info_label.text = info
	var lines := colony.events.slice(maxi(0, colony.events.size() - 6))
	var bb := PackedStringArray()
	for l in lines:
		bb.append(_log_bbcode(l))
	var joined := "\n".join(bb)
	if joined != _last_log:      # avoid rebuilding the rich text every frame
		_last_log = joined
		log_label.text = joined

## "@icon [m:ss] message" -> bbcode with the icon inline (older saves have no @icon prefix).
func _log_bbcode(line: String) -> String:
	var ic := ""
	if line.begins_with("@"):
		var sp := line.find(" ")
		if sp > 0:
			ic = line.substr(1, sp - 1)
			line = line.substr(sp + 1)
	line = line.replace("[", "[lb]")
	var tex := icon(ic) if ic != "" else null
	if tex != null:
		return "[img=%dx%d]%s%s.png[/img] %s" % [LOG_ICON_PX, LOG_ICON_PX, ICON_DIR, ic, line]
	return "      " + line   # keep text aligned with iconned lines

# ------------------------------------------------------------------ F3 debug readout (v7)
func toggle_debug() -> void:
	debug_label.visible = not debug_label.visible
	_debug_t = 0.0

func update_debug(delta: float) -> void:
	if debug_label == null or not debug_label.visible:
		return
	_debug_t -= delta
	if _debug_t > 0.0:
		return
	_debug_t = 0.5
	debug_label.text = "FPS %d   draw calls %d   prims %d\nVRAM %.1f MB  (textures %.1f MB, buffers %.1f MB)\nobjects %d  nodes %d  resources %d" % [
		Engine.get_frames_per_second(),
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.OBJECT_COUNT), Performance.get_monitor(Performance.OBJECT_NODE_COUNT), Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)]
