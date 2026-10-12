extends Node2D
## Root: builds the world, owns tools / input / sim speed, and runs the fixed-step simulation.

enum Tool { SELECT, DIG, NURSERY, STORAGE, WASTE, FILL }

const HELP := "Keys: 1-6 tools (F fill) | O orders | Space pause | -/+ speed | P trails | H climate | K save | L load | Tab or ? help | M mute | F3 debug | R rotate\nLeft-drag with Dig / Fill paints orders, right-drag cancels. Click an ant, larva or chamber to inspect it."
const ROOM_TOOLS := {Tool.NURSERY: Room.Type.NURSERY, Tool.STORAGE: Room.Type.FOOD_STORAGE, Tool.WASTE: Room.Type.WASTE}

var grid: SoilGrid
var colony: Colony
var overlay: Overlay
var overlay_top: Overlay
var tutorial: Tutorial
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
var fill_mode := false
var fill_msg := ""
var _fill_key := Vector3i(-1, -1, -1)
var _fill_key_t := 0.0
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

## Web hardening (v5, extended in v7): 60 fps cap, autosave every AUTOSAVE_S and when the tab is
## hidden, and a graceful 'webglcontextlost' path. The user saw sound keep playing after the loss, so
## the main loop survives: JS only raises a flag, Godot then autosaves (fresh state), mutes, and the
## page reloads with ?resume=1 which loads the autosave on start.
const AUTOSAVE_S := 60.0
var _autosave_t := AUTOSAVE_S
var _web := false
var _web_poll_t := 0.0
var _lost_handled := false
var resume_requested := false

func _web_setup() -> void:
	if not OS.has_feature("web"):
		return
	_web = true
	Engine.max_fps = 60
	JavaScriptBridge.eval("""
(function(){
  window.antcity = window.antcity || {lost: false, hidden: false, lostAt: 0};
  var c = document.getElementById('canvas'); if (!c || c._antcityHooked) return; c._antcityHooked = true;
  // capture phase on window runs BEFORE Godot's own canvas handler, which would block everything
  // with alert('WebGL context lost, please reload the page'); stop it and handle the loss ourselves
  window.addEventListener('webglcontextlost', function(e){
    if (e.target !== c) return;
    e.stopImmediatePropagation();
    if (window.antcity.lost) return;
    window.antcity.lost = true; window.antcity.lostAt = Date.now();
    console.log('ANTCITY webglcontextlost');
    try { var A = window.GodotAudio || (window.Module && Module.GodotAudio); if (A && A.ctx) A.ctx.suspend(); } catch (err) {}
    var d = document.createElement('div');
    d.id = 'antcity-lost';
    d.style.cssText = 'position:fixed;left:0;top:0;right:0;padding:18px;background:#3a1f12;color:#fff;font:16px sans-serif;z-index:99;text-align:center';
    d.innerHTML = 'Oops - the browser stopped the game graphics (WebGL context lost). Saving your colony and reloading in a few seconds... <button onclick="location.search=&#39;?resume=1&#39;">Reload now</button>';
    document.body.appendChild(d);
    // fallback reload even if the game loop never answers
    setTimeout(function(){ location.search = '?resume=1'; }, 6000);
  }, true);
  document.addEventListener('visibilitychange', function(){ if (document.hidden) window.antcity.hidden = true; });
})();
""", true)
	var q := str(JavaScriptBridge.eval("window.location.search", true))
	resume_requested = q.contains("resume=1")

## Polled ~4x per second on the web.
func _web_poll(delta: float) -> void:
	if not _web:
		return
	_web_poll_t -= delta
	if _web_poll_t > 0.0:
		return
	_web_poll_t = 0.25
	var lost := bool(JavaScriptBridge.eval("window.antcity && window.antcity.lost", true))
	if lost and not _lost_handled:
		_lost_handled = true
		print("ANTCITY context lost seen by Godot at t=", int(colony.time), " - autosaving")
		AudioServer.set_bus_mute(0, true)
		SaveGame.save(colony, SaveGame.AUTO_PATH)
		paused = true
		# give IDBFS a moment to sync, then reload and resume from the autosave
		JavaScriptBridge.eval("setTimeout(function(){ location.search = '?resume=1'; }, 1500);", true)
	if bool(JavaScriptBridge.eval("window.antcity && window.antcity.hidden", true)):
		JavaScriptBridge.eval("window.antcity.hidden = false;", true)
		if _selftest == null:
			SaveGame.save(colony, SaveGame.AUTO_PATH)

func _step_autosave(delta: float) -> void:
	_web_poll(delta)
	if _selftest != null or paused:
		return
	_autosave_t -= delta
	if _autosave_t <= 0.0:
		_autosave_t = AUTOSAVE_S
		SaveGame.save(colony, SaveGame.AUTO_PATH)

func _ready() -> void:
	_web_setup()
	var args := _parse_args()
	if args.has("classic"):
		Config.classic_start = true       # v5 layout (pre-built nursery, storage, waste) for the old tests
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
	ui.main = self
	ui.soldier_mode_pressed.connect(toggle_orders)
	colony.nuptial_flight.connect(func(d: Dictionary) -> void:
		ui.show_summary(d)
		if not paused:
			toggle_pause())
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
	# v6 tutorial: offered on the first launch (not in tests unless --tutorial is given)
	tutorial = Tutorial.new()
	tutorial.name = "Tutorial"
	tutorial.main = self
	var testing := args.has("selftest") or args.has("shot") or args.has("audiotest") or args.has("perf")
	tutorial.persist = not testing
	ui.add_child(tutorial)
	ui.tutorial_pressed.connect(func() -> void:
		_click()
		tutorial.start())
	if resume_requested and FileAccess.file_exists(SaveGame.AUTO_PATH):
		var err := SaveGame.load_file(colony, SaveGame.AUTO_PATH)
		print("ANTCITY resume from autosave: ", "ok" if err == "" else err, " t=", int(colony.time))
		colony.log_event("Graphics were reset by the browser - your colony was restored from the autosave." if err == "" else "Could not restore the autosave: " + err, "load")
		ui.show_modes(colony)
		JavaScriptBridge.eval("history.replaceState(null, '', location.pathname);", true)
	elif args.has("tutorial") or (not testing and not Config.classic_start and not Tutorial.is_done()):
		tutorial.start.call_deferred()
	if args.has("selftest") or args.has("shot") or args.has("audiotest") or args.has("perf"):
		var st := load("res://scripts/SelfTest.gd").new() as Node
		st.name = "SelfTest"
		st.set("main", self)
		st.set("args", args)
		add_child(st)
		_selftest = st

func _parse_args() -> Dictionary:
	var d := {}
	var user_args := Array(OS.get_cmdline_user_args())
	if OS.has_feature("web"):
		# web build: options come from the page URL, e.g. index.html?perf=600&ffwd=300&speed=4
		var q := str(JavaScriptBridge.eval("window.location.search", true)).trim_prefix("?")
		for part in q.split("&", false):
			user_args.append("--" + part)
	for a in user_args:
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
	_step_autosave(delta)
	ui.update_debug(delta)
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

# ------------------------------------------------------------------ v8 player orders
func toggle_orders() -> void:
	_click()
	ui.toggle_orders()

func set_prio(job: int, d: int) -> void:
	_click()
	colony.work_prio[job] = clampi(int(colony.work_prio[job]) + d, 0, 4)
	colony.refresh_now()

func apply_preset(n: String) -> void:
	_click()
	colony.work_prio = (Config.PRIO_PRESETS[n] as Array).duplicate()
	colony.refresh_now()
	colony.log_event("Workforce preset: %s." % n, "worker")

func toggle_caste_auto() -> void:
	_click()
	colony.caste_manual = not colony.caste_manual
	colony.log_event("New eggs: %s." % ("your ratio" if colony.caste_manual else "Auto"), "nursery")

func set_caste_w(i: int, d: int) -> void:
	_click()
	colony.caste_manual = true
	colony.caste_w[i] = clampi(int(colony.caste_w[i]) + d, 0, 10)

func cycle_standing_order() -> void:
	_click()
	colony.standing_order = (colony.standing_order + 1) % Config.ORDER_NAMES.size()

func alarm_order(o: int) -> void:
	_click()
	colony.set_alarm_order(o)

func nuptial_flight() -> void:
	_click()
	colony.start_nuptial_flight()

func close_summary() -> void:
	_click()
	ui.summary_panel.visible = false
	if paused:
		toggle_pause()

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
	var path := SaveGame.newest_path()
	var err := SaveGame.load_file(colony, path if path != "" else SaveGame.DEFAULT_PATH)
	if err == "" and path == SaveGame.AUTO_PATH:
		colony.log_event("Loaded the autosave (it was newer than your save).", "load")
	if err != "":
		colony.log_event("Load failed: " + err, "alert")
	ui.show_modes(colony)

# ------------------------------------------------------------------ input
func _input(event: InputEvent) -> void:
	# track the pointer from events (also when it is over the HUD); works with synthetic input too
	if event is InputEventMouse:
		_mouse_world = get_viewport().get_canvas_transform().affine_inverse() * event.position
		_mouse_seen = true
	# Help is caught here so Tab is not eaten by GUI focus navigation (F1 opens browser help on the web).
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode in [KEY_TAB, KEY_QUESTION, KEY_SLASH]:
			_click()
			ui.toggle_help()
			get_viewport().set_input_as_handled()

func _mouse_pos() -> Vector2:
	return _mouse_world if _mouse_seen else get_global_mouse_position()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE: toggle_pause()
			KEY_P: toggle_phero()
			KEY_H: toggle_climate()
			KEY_M: toggle_mute()
			KEY_F3: ui.toggle_debug()
			KEY_BRACKETLEFT: change_volume(-0.1)
			KEY_BRACKETRIGHT: change_volume(0.1)
			KEY_K: save_game()      # web-safe (F5 reloads the page in a browser)
			KEY_L: load_game()
			KEY_1: set_tool(Tool.SELECT)
			KEY_2: set_tool(Tool.DIG)
			KEY_3: set_tool(Tool.NURSERY)
			KEY_4: set_tool(Tool.STORAGE)
			KEY_5: set_tool(Tool.WASTE)
			KEY_6, KEY_F: set_tool(Tool.FILL)
			KEY_O: toggle_orders()
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
		if _drag and (tool == Tool.DIG or tool == Tool.FILL):
			_paint_line(_last_cell, c, false)
			_last_cell = c
		elif _drag_cancel and (tool == Tool.DIG or tool == Tool.FILL):
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
		Tool.FILL:
			_drag = true
			_last_cell = c
			colony.add_fill_order(c)
		Tool.NURSERY, Tool.STORAGE, Tool.WASTE:
			var type: int = ROOM_TOOLS[tool]
			var rect := _ghost_rect_for(c)
			if colony.placement_error(type, rect) == "":
				colony.place_room(type, rect)
				_click()

func _on_right_press(c: Vector2i) -> void:
	if tool == Tool.DIG or tool == Tool.FILL:
		_drag_cancel = true
		_last_cell = c
		if tool == Tool.FILL:
			colony.cancel_fill_order(c)
		else:
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
		if tool == Tool.FILL:
			if cancel:
				colony.cancel_fill_order(c)
			else:
				colony.add_fill_order(c)
		elif cancel:
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
	hover_visible = inside and (tool == Tool.DIG or tool == Tool.FILL)
	fill_mode = tool == Tool.FILL
	if fill_mode:
		if colony.fill_tasks.has(hover_cell):
			hover_ok = true
			fill_msg = "Fill order (right-drag cancels)"
		else:
			var key := Vector3i(hover_cell.x, hover_cell.y, colony.fill_tasks.size() * 7919 + colony.grid.walk_idx.size())
			if key != _fill_key or colony.time - _fill_key_t > 0.5:
				_fill_key = key
				_fill_key_t = colony.time
				fill_msg = colony.fill_error(hover_cell)
			hover_ok = fill_msg == ""
			if hover_ok:
				fill_msg = "Fill - click / drag"
	else:
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
