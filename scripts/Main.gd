extends Node2D
## Root: builds the world, owns tools / input / sim speed, and runs the fixed-step simulation.

enum Tool { SELECT, DIG, NURSERY, STORAGE, WASTE }

const HELP := "Keys: 1-5 tools | Space pause | -/+ speed | P trails | H climate | F5 save | F9 load | F1 help | M mute | [ ] volume | R rotate chamber\nLeft-drag with Dig paints orders, right-drag cancels. Click an ant, larva or chamber to inspect it."
const ROOM_TOOLS := {Tool.NURSERY: Room.Type.NURSERY, Tool.STORAGE: Room.Type.FOOD_STORAGE, Tool.WASTE: Room.Type.WASTE}

var grid: SoilGrid
var colony: Colony
var overlay: Overlay
var overlay_top: Overlay
var ui: GameUI
var audio: GameAudio

var tool: int = Tool.SELECT
var speed := 1.0
var paused := false
var _accum := 0.0

# cursor / ghost state (read by the top overlay)
var hover_cell := Vector2i.ZERO
var hover_visible := false
var hover_ok := false
var ghost_visible := false
var ghost_ok := false
var ghost_rect := Rect2i()
var ghost_type: int = Room.Type.NURSERY
var ghost_msg := ""
var room_w := 5
var room_h := 3

var selected_ant: Ant = null
var selected_brood: Brood = null
var selected_room: Room = null
var _drag := false
var _drag_cancel := false
var _last_cell := Vector2i(-1, -1)
var _selftest: Node = null
var _mouse_world := Vector2(-1000, -1000)   # last known mouse position in world coordinates
var _mouse_seen := false

func _ready() -> void:
	var args := _parse_args()
	if args.has("seed"):
		seed(int(args["seed"]))
	else:
		randomize()
	grid = SoilGrid.new()
	grid.name = "Soil"
	add_child(grid)
	grid.setup()
	audio = GameAudio.new(args.has("forcesound") and not args.has("nosound"))
	if args.has("nosound"):
		audio.enabled = false
	add_child(audio)
	colony = Colony.new()
	colony.name = "Colony"
	colony.audio = audio
	add_child(colony)
	colony.setup(grid)
	overlay = Overlay.new()
	overlay.name = "Overlay"
	overlay.colony = colony
	overlay.z_index = 3
	add_child(overlay)
	overlay_top = Overlay.new()
	overlay_top.name = "OverlayTop"
	overlay_top.top = true
	overlay_top.colony = colony
	overlay_top.main = self
	overlay_top.z_index = 20
	add_child(overlay_top)
	ui = GameUI.new()
	ui.name = "UI"
	add_child(ui)
	ui.tool_selected.connect(set_tool)
	ui.speed_selected.connect(set_speed)
	ui.pause_toggled.connect(toggle_pause)
	ui.overlay_toggled.connect(toggle_phero)
	ui.climate_toggled.connect(toggle_climate)
	ui.soldier_mode_pressed.connect(cycle_soldier_mode)
	ui.threat_pressed.connect(cycle_threat_level)
	ui.save_pressed.connect(save_game)
	ui.load_pressed.connect(load_game)
	ui.help_toggled.connect(func() -> void:
		_click()
		ui.toggle_help())
	ui.sound_pressed.connect(toggle_mute)
	ui.show_sound(audio)
	ui.show_modes(colony)
	ui.show_tool(tool)
	if args.has("threats"):
		Config.threat_level = clampi(int(args["threats"]), 0, 2)
		colony.reset_threat_timer()
		ui.show_modes(colony)
	if args.has("nohelp"):
		ui.hide_help()
	if args.has("selftest") or args.has("shot") or args.has("audiotest"):
		var st := load("res://scripts/SelfTest.gd").new() as Node
		st.name = "SelfTest"
		st.set("main", self)
		st.set("args", args)
		add_child(st)
		_selftest = st

func _parse_args() -> Dictionary:
	var d := {}
	for a in OS.get_cmdline_user_args():
		var s := String(a).trim_prefix("--")
		var kv := s.split("=", true, 1)
		d[kv[0]] = kv[1] if kv.size() > 1 else "1"
	return d

# ------------------------------------------------------------------ simulation loop
func _process(delta: float) -> void:
	if _selftest != null and _selftest.get("manual_stepping"):
		return
	if not paused:
		_accum += minf(delta, 0.1) * speed
		var n := 0
		while _accum >= Config.SIM_DT and n < Config.MAX_STEPS_PER_FRAME:
			colony.sim_step(Config.SIM_DT)
			_accum -= Config.SIM_DT
			n += 1
		if n >= Config.MAX_STEPS_PER_FRAME:
			_accum = 0.0
	_update_cursor()
	if _mouse_seen:
		# ambience follows what the player looks at: surface above the ground line, nest below
		var gy := float(Config.SURFACE_ROW * Config.CELL)
		audio.set_depth_mix(smoothstep(gy - 24.0, gy + 64.0, _mouse_pos().y))
	ui.refresh(colony, speed, paused, _info_text())

func _click() -> void:
	audio.play("ui_click")

func toggle_mute() -> void:
	audio.toggle_mute()
	ui.show_sound(audio)
	if not audio.muted:
		_click()

func change_volume(d: float) -> void:
	audio.change_master(d)
	ui.show_sound(audio)
	_click()

func set_tool(t: int) -> void:
	_click()
	tool = t
	ui.show_tool(t)
	if t != Tool.SELECT:
		_clear_selection()
	_update_cursor()

func set_speed(s: float) -> void:
	_click()
	speed = s
	if paused:
		paused = false
	ui.show_speed(speed, paused)

func toggle_pause() -> void:
	_click()
	paused = not paused
	ui.show_speed(speed, paused)

func toggle_phero() -> void:
	_click()
	overlay.show_phero = not overlay.show_phero
	ui.show_phero(overlay.show_phero)

func toggle_climate() -> void:
	_click()
	overlay.show_climate = not overlay.show_climate
	ui.show_climate(overlay.show_climate)

func cycle_soldier_mode() -> void:
	_click()
	colony.soldier_mode = (colony.soldier_mode + 1) % Colony.SOLDIER_MODE_NAMES.size()
	ui.show_modes(colony)
	colony.log_event("Soldier production: %s." % Colony.SOLDIER_MODE_NAMES[colony.soldier_mode], "guard")

func cycle_threat_level() -> void:
	_click()
	Config.threat_level = (Config.threat_level + 1) % Config.THREAT_NAMES.size()
	colony.reset_threat_timer()
	ui.show_modes(colony)
	colony.log_event("Threats: %s." % Config.THREAT_NAMES[Config.threat_level], "threat_spider")

func save_game() -> void:
	_click()
	if SaveGame.save(colony):
		colony.log_event("Game saved.", "save")
	else:
		colony.log_event("Saving failed!", "alert")

func load_game() -> void:
	_click()
	_clear_selection()
	var err := SaveGame.load_file(colony)
	if err != "":
		colony.log_event("Load failed: " + err, "alert")
	ui.show_modes(colony)

# ------------------------------------------------------------------ input
func _input(event: InputEvent) -> void:
	# track the pointer from events (also when it is over the HUD); works with synthetic input too
	if event is InputEventMouse:
		_mouse_world = get_viewport().get_canvas_transform().affine_inverse() * event.position
		_mouse_seen = true

func _mouse_pos() -> Vector2:
	return _mouse_world if _mouse_seen else get_global_mouse_position()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE: toggle_pause()
			KEY_P: toggle_phero()
			KEY_H: toggle_climate()
			KEY_F1:
				_click()
				ui.toggle_help()
			KEY_M: toggle_mute()
			KEY_BRACKETLEFT: change_volume(-0.1)
			KEY_BRACKETRIGHT: change_volume(0.1)
			KEY_F5: save_game()
			KEY_F9: load_game()
			KEY_1: set_tool(Tool.SELECT)
			KEY_2: set_tool(Tool.DIG)
			KEY_3: set_tool(Tool.NURSERY)
			KEY_4: set_tool(Tool.STORAGE)
			KEY_5: set_tool(Tool.WASTE)
			KEY_ESCAPE: set_tool(Tool.SELECT)
			KEY_R, KEY_T:
				var tmp := room_w
				room_w = room_h
				room_h = tmp
				_update_cursor()
			KEY_MINUS, KEY_KP_SUBTRACT:
				set_speed(maxf(1.0, speed * 0.5))
			KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
				set_speed(minf(4.0, speed * 2.0))
	elif event is InputEventMouseButton:
		var c := SoilGrid.world_to_cell(_mouse_pos())
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_on_left_press(c)
			else:
				_drag = false
				_last_cell = Vector2i(-1, -1)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			if event.pressed:
				_on_right_press(c)
			else:
				_drag_cancel = false
				_last_cell = Vector2i(-1, -1)
	elif event is InputEventMouseMotion:
		var c := SoilGrid.world_to_cell(_mouse_pos())
		if _drag and tool == Tool.DIG:
			_paint_line(_last_cell, c, false)
			_last_cell = c
		elif _drag_cancel and tool == Tool.DIG:
			_paint_line(_last_cell, c, true)
			_last_cell = c

func _on_left_press(c: Vector2i) -> void:
	match tool:
		Tool.SELECT:
			_select_at(_mouse_pos(), c)
		Tool.DIG:
			_drag = true
			_last_cell = c
			colony.add_dig_order(c)
		Tool.NURSERY, Tool.STORAGE, Tool.WASTE:
			var type: int = ROOM_TOOLS[tool]
			var rect := _ghost_rect_for(c)
			if colony.placement_error(type, rect) == "":
				colony.place_room(type, rect)
				_click()

func _on_right_press(c: Vector2i) -> void:
	if tool == Tool.DIG:
		_drag_cancel = true
		_last_cell = c
		colony.cancel_dig_order(c)
		return
	var r := colony.room_at(c)
	if r != null and not r.active:
		colony.cancel_room(r)
	elif tool != Tool.SELECT:
		set_tool(Tool.SELECT)

func _paint_line(a: Vector2i, b: Vector2i, cancel: bool) -> void:
	if a.x < 0:
		a = b
	var steps := maxi(absi(b.x - a.x), absi(b.y - a.y))
	for i in range(steps + 1):
		var t := float(i) / float(maxi(steps, 1))
		var c := Vector2i(roundi(lerpf(a.x, b.x, t)), roundi(lerpf(a.y, b.y, t)))
		if cancel:
			colony.cancel_dig_order(c)
		else:
			colony.add_dig_order(c)

func _select_at(p: Vector2, c: Vector2i) -> void:
	_clear_selection()
	var a := colony.ant_at(p)
	if a != null:
		selected_ant = a
		a.selected = true
		return
	var b := colony.brood_at(c)
	if b != null:
		selected_brood = b
		return
	selected_room = colony.room_at(c)

func _clear_selection() -> void:
	if selected_ant != null and is_instance_valid(selected_ant):
		selected_ant.selected = false
	selected_ant = null
	selected_brood = null
	selected_room = null

@warning_ignore("integer_division")
func _ghost_rect_for(c: Vector2i) -> Rect2i:
	return Rect2i(c.x - room_w / 2, c.y - room_h / 2, room_w, room_h)

func _update_cursor() -> void:
	var mp := _mouse_pos()
	var inside := Rect2(Vector2.ZERO, Config.SCREEN).has_point(mp)
	hover_cell = SoilGrid.world_to_cell(mp)
	hover_visible = inside and tool == Tool.DIG
	hover_ok = colony.can_order_dig(hover_cell) or colony.dig_tasks.has(hover_cell)
	ghost_visible = false
	if inside and ROOM_TOOLS.has(tool):
		ghost_type = ROOM_TOOLS[tool]
		ghost_rect = _ghost_rect_for(hover_cell)
		ghost_msg = colony.placement_error(ghost_type, ghost_rect)
		ghost_ok = ghost_msg == ""
		ghost_visible = true

func _info_text() -> String:
	if selected_ant != null:
		if is_instance_valid(selected_ant) and selected_ant.state != Ant.State.DEAD:
			return selected_ant.info_text()
		selected_ant = null
	if selected_brood != null:
		var b := selected_brood
		if b.dead:
			selected_brood = null
		else:
			var where := "in the nursery" if b.room != null else ("being carried" if b.in_transit else "lying loose (needs a nurse)")
			var rate := Climate.rate(Climate.quality_at(b.cell().y, colony.time))
			return "%s %s\nProgress %d%%   Fed %d%%\nClimate here: development x%.2f%s" % [b.stage_name(), where, int(100.0 * b.t / _stage_time(b)), int(b.fed * 100.0), rate, "   (a nurse is coming)" if b.claimed_by != null else ""]
	if selected_room != null:
		return _room_info(selected_room)
	var r := colony.room_at(hover_cell)
	if r != null:
		return _room_info(r)
	var f := colony.food_near(hover_cell.x)
	if f != null and hover_cell.y <= Config.SURFACE_ROW + 1:
		return "%s pile: %.0f / %.0f left" % [Config.FOOD_NAMES[f.type], f.amount, f.max_amount]
	if hover_cell.y > Config.SURFACE_ROW and hover_visible == false and ui != null and overlay.show_climate:
		return _climate_info(hover_cell.y)
	return HELP

func _climate_info(row: int) -> String:
	var t := Climate.temp(row, colony.time)
	var h := Climate.humidity(row)
	return "Row %d (depth %d)\nTemperature %.1f C   Humidity %d%%\nBrood comfort %d%%  -> development x%.2f" % [row, row - Config.SURFACE_ROW - 1, t, roundi(h * 100.0), roundi(Climate.quality(t, h) * 100.0), Climate.rate(Climate.quality(t, h))]

func _stage_time(b: Brood) -> float:
	return [Config.EGG_TIME, Config.LARVA_TIME, Config.PUPA_TIME][b.stage]

func _room_info(r: Room) -> String:
	var s := r.label() + "\nCells: %d" % r.cell_count()
	match r.type:
		Room.Type.FOOD_STORAGE: s += "   Capacity %.0f food (sugar + protein)" % r.capacity()
		Room.Type.NURSERY: s += "   Capacity %d brood" % int(r.capacity())
		Room.Type.WASTE: s += "   Capacity %.0f units" % r.capacity()
		_: s += "   The queen lives here"
	var row := r.rect.get_center().y
	s += "\nNow %.1f C, %d%% humid   brood comfort %d%%" % [Climate.temp(row, colony.time), roundi(Climate.humidity(row) * 100.0), roundi(r.quality * 100.0)]
	return s
