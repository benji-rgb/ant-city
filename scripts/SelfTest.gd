extends Node
## Developer harness (not used in normal play). Started by Main when the game is launched with
##   godot --headless --path . -- --selftest=600 [--seed=1] [--dt=0.0333]
##   godot --path . -- --shot=/tmp/a.png [--ffwd=240]
## Drives the simulation without rendering, scripts a few "player" actions and prints a report.

var main: Node
var args: Dictionary = {}
var manual_stepping := true

var _events: Array = []
var _max_stuck := 0.0
var _stuck_desc := ""
var _problems: Array[String] = []
var _max_workers := 0
var _min_workers := 9999
var _task_samples := {}
var _min_hygiene := 1.0
var _max_waste := 0
var _max_soldiers := 0
var _saved_probe := {}

func _ready() -> void:
	_run.call_deferred()

func _colony() -> Colony:
	return main.colony

func _run() -> void:
	var dt := float(args.get("dt", 1.0 / 30.0))
	var c := _colony()
	_setup_events()
	var nf := int(args.get("foods", Config.FOOD_LAYOUT.size()))
	for i in c.foods.size():
		if i >= nf:
			c.foods[i].active = false
			c.foods[i].respawn_t = 1e9
	if args.has("nofood"):
		for f in c.foods:
			f.active = false
			f.respawn_t = 1e9
	if args.has("audiotest"):
		await _audio_test()
		get_tree().quit(1 if _problems.size() > 0 else 0)
		return
	if args.has("selftest"):
		var dur := float(args["selftest"])
		await _simulate(dur, dt)
		_report(dur)
		get_tree().quit(1 if _problems.size() > 0 else 0)
		return
	# screenshot mode
	var ffwd := float(args.get("ffwd", 0.0))
	await _simulate(ffwd, dt)
	manual_stepping = false
	if args.has("uitest"):
		await _ui_test()
		get_tree().quit(1 if _problems.size() > 0 else 0)
		return
	main.speed = float(args.get("speed", 1.0))
	if args.has("perf"):
		await _perf_run(float(args["perf"]))
		get_tree().quit(0)
		return
	if args.has("phero"):
		main.toggle_phero()
	if args.has("climate"):
		main.toggle_climate()
	if args.has("tool"):
		main.set_tool(int(args["tool"]))
		get_viewport().warp_mouse(Vector2(float(args.get("mx", 700)), float(args.get("my", 330))))
	for i in 20:
		await get_tree().process_frame
	var path := String(args["shot"])
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)
	print("screenshot saved: ", path, " ", img.get_size(), " t=", int(c.time), "s field_updates=", main.overlay.field_updates)
	if args.has("shot2"):
		main.toggle_phero()
		for i in 60:
			await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png(String(args["shot2"]))
		print("screenshot saved: ", args["shot2"])
	await _audio_shutdown()
	get_tree().quit(0)

func _setup_events() -> void:
	# [time, callable]
	if not Config.classic_start:
		_setup_founding_events()
		return
	_events = [
		[5.0, func() -> void: _dig_line(Vector2i(20, 9), Vector2i(0, 1), 6)],        # new entrance shaft
		[8.0, func() -> void: _place(Room.Type.NURSERY, Rect2i(41, 16, 5, 3))],
		[12.0, func() -> void: _place(Room.Type.FOOD_STORAGE, Rect2i(31, 14, 5, 3))],
		[16.0, func() -> void: _dig_line(Vector2i(41, 17), Vector2i(1, 0), 0)],       # (invalid: inside planned room) just exercises validation
		[20.0, func() -> void: _try_invalid()],
		[24.0, func() -> void: _place(Room.Type.WASTE, Rect2i(28, 18, 4, 2))],
	]
	_setup_common_events()

func _setup_common_events() -> void:
	if args.has("v8test"):
		_setup_v8_events()
	if args.has("threatat"):
		var kind := int(args.get("threatkind", 0))
		_events.append([float(args["threatat"]), func() -> void:
			Config.threat_level = maxi(1, Config.threat_level)
			_colony().spawn_threat(kind)
			print("[test] spawned a threat of kind ", kind, " at t=", int(_colony().time))])
	if args.has("raidat"):
		_events.append([float(args["raidat"]), func() -> void:
			Config.threat_level = maxi(1, Config.threat_level)
			var th := _colony().spawn_threat(Threat.Kind.RIVAL)
			th.raider = true
			print("[test] spawned a raiding rival scout at t=", int(_colony().time))])
		_events.append([float(args["raidat"]) + 150.0, func() -> void:
			var c := _colony()
			print("[test] raid check: raids %d, food stolen %.1f, brood stolen %d, intruders killed %d, intruders now %d" % [c.raids, c.food_stolen, c.brood_stolen, c.intruders_killed, c.intruder_count()])
			if c.raids < 1:
				_problems.append("raider never entered the nest")])
	if args.has("raintest"):
		var t0 := float(args["raintest"])
		_events.append([t0, func() -> void:
			_colony().start_rain(1.0, 60.0)
			print("[test] forced heavy rain at t=", int(_colony().time))])
		_events.append([t0 + 55.0, func() -> void:
			var c := _colony()
			var wet := 0
			for r in c.rooms:
				if r.flooded:
					wet += 1
			print("[test] rain check: flooded cells %d, flood peak %.2f, flooded rooms %d, humidity row 10 %.2f" % [c.flooded_cells, c.flood_peak, wet, Climate.humidity(10)])
			if c.flood_peak <= Config.FLOOD_WET or c.flooded_cells == 0:
				_problems.append("heavy rain did not flood shallow tunnels")])
		_events.append([t0 + 240.0, func() -> void:
			var c := _colony()
			print("[test] drain check: flooded cells %d, flood deaths %d, brood relocations %d" % [c.flooded_cells, c.flood_deaths, c.brood_relocated])
			if c.flooded_cells > 0:
				_problems.append("flood did not drain")])
	if args.has("norain"):
		Config.rain_enabled = false
	if args.has("soldiermode"):
		_events.append([1.0, func() -> void: _colony().soldier_mode = int(args["soldiermode"])])
	if args.has("savetest"):
		_events.append([float(args["savetest"]), func() -> void: _save_probe()])
	if args.has("killfoods"):
		# trail-fade test: at T every pile vanishes for good; the pheromone total should decay to ~0
		_events.append([float(args["killfoods"]), func() -> void:
			print("[test] all food sources removed; pheromone total now %.1f" % (_colony().trails[0].total + _colony().trails[1].total))
			for f in _colony().foods:
				f.active = false
				f.respawn_t = 1e9])

	_events.sort_custom(func(x: Array, y: Array) -> bool: return float(x[0]) < float(y[0]))

## v6 founding start. --tutor: do what the tutorial asks, at a beginner's pace (and check the
## tutorial advances on those actions); without it the player does nothing.
func _setup_founding_events() -> void:
	_events = []
	var c := _colony()
	_events.append([0.5, func() -> void:
		_expect(c.rooms.size() == 1 and c.queen_room != null, "founding start has only the queen chamber")
		_expect(c.worker_count() == Config.FOUND_WORKERS and c.brood.size() == Config.FOUND_EGGS + Config.FOUND_LARVAE, "founding start: %d workers, %d brood" % [c.worker_count(), c.brood.size()])
		_expect(c.food_capacity > 0.0 and absf(c.sugar_stock - Config.FOUND_SUGAR) < 1.0, "the reserve sits in the queen chamber (S%.0f P%.0f)" % [c.sugar_stock, c.protein_stock])])
	if args.has("tutor"):
		var tut: Tutorial = main.tutorial
		_events.append([1.0, func() -> void:
			if args.has("skiptut"):
				tut.skip()
				_expect(not tut.running() and tut.done_once, "Skip ends the tutorial and marks it done")
			else:
				tut.start()
				tut.advance()      # "Next" on the welcome page
				_expect(tut.step == 1, "tutorial at the dig step")])
		_events.append([20.0, func() -> void: _dig_line(Vector2i(40, 21), Vector2i(0, 1), 3)])     # down from the queen chamber
		_events.append([25.0, func() -> void:
			tut.poll()
			if not args.has("skiptut"):
				_expect(tut.step == 2, "dig orders advanced the tutorial (step %d)" % tut.step)])
		_events.append([45.0, func() -> void: _place(Room.Type.NURSERY, Rect2i(34, 19, 5, 2))])
		_events.append([80.0, func() -> void: _place(Room.Type.FOOD_STORAGE, Rect2i(43, 19, 5, 2))])
		_events.append([100.0, func() -> void:
			tut.poll()
			if not args.has("skiptut"):
				_expect(tut.step == 4, "rooms advanced the tutorial (step %d)" % tut.step)
			main.toggle_phero()])
		_events.append([140.0, func() -> void:
			tut.poll()
			main.toggle_phero()
			_place(Room.Type.WASTE, Rect2i(41, 14, 4, 2))])
		_events.append([150.0, func() -> void:
			tut.poll()
			if not args.has("skiptut"):
				_expect(tut.step == 6, "waste chamber reached the Orders step (step %d)" % tut.step)
				main.toggle_orders()
				tut.poll()
				_expect(tut.step == 7, "opening Orders advanced the tutorial (step %d)" % tut.step)
				main.toggle_orders()
				tut.advance()
				_expect(tut.step == 8, "last tutorial step (step %d)" % tut.step)
				tut.advance()
				_expect(not tut.running() and tut.done_once, "Finish closes the tutorial")])
	_events.append([300.0, func() -> void:
		var alive := c.worker_count()
		print("[test] founding t=300: workers %d, brood %d, sugar %.1f, protein %.1f, rooms %d" % [alive, c.brood.size(), c.sugar_stock, c.protein_stock, c.rooms.size()])
		if args.has("tutor"):
			_expect(alive >= Config.FOUND_WORKERS, "tutorial player: colony did not shrink in 5 minutes (%d workers)" % alive)
		else:
			_expect(alive >= 1 and c.queen != null, "do-nothing player: colony still alive after 5 minutes (%d workers)" % alive)])
	_setup_common_events()

## v8 checks: sugar caps, fill tool (connectivity + completion), castes / nuptial flight, threat orders, priorities.
var _v8 := {}
func _setup_v8_events() -> void:
	var c := _colony()
	_events.append([2.0, func() -> void:
		_expect(Config.type_cap(1) * c.food_capacity < c.food_capacity * 0.5, "protein may take at most 40%% of storage")
		var before := c.protein_stock
		c.deposit_food(500.0, Config.Food.PROTEIN, Vector2i(40, 12))
		_expect(c.protein_stock <= Config.type_cap(1) * c.food_capacity + 0.01, "protein capped (%.1f / cap %.1f)" % [c.protein_stock, c.food_capacity])
		_expect(c.storage_accepts(Config.Food.SUGAR), "storage still accepts sugar when protein is at its cap")
		print("[v8] protein %.1f -> %.1f, capacity %.1f" % [before, c.protein_stock, c.food_capacity])
		# rejections
		_expect(c.fill_error(Vector2i(5, 30)) != "", "fill rejects solid soil")
		_expect(c.fill_error(c.queen_room.rect.position) != "", "fill rejects the queen chamber")
		# a 3-cell dead-end branch to fill later
		for y in range(Config.FIRST_SOIL_ROW + 3, Config.GRID_H - 4):
			for x in range(Config.DIG_MIN_X + 4, Config.DIG_MAX_X - 4):
				var t := Vector2i(x, y)
				if c.grid.get_cell(t) == SoilGrid.Cell.TUNNEL and c.room_at(t) == null and not _v8.has("base"):
					var ok := true
					for i in range(1, 4):
						var s := t + Vector2i(-i, 0)
						for dy in [-1, 0, 1]:
							var q := s + Vector2i(0, dy)
							if c.grid.get_cell(q) != SoilGrid.Cell.SOIL or c.room_at(q) != null or c.dig_tasks.has(q):
								ok = false
					if ok:
						_v8["base"] = t
		_expect(_v8.has("base"), "found a spot for a test branch")
		if _v8.has("base"):
			var b: Vector2i = _v8["base"]
			for i in range(1, 4):
				c.add_dig_order(b + Vector2i(-i, 0))
			print("[v8] test branch from ", b)])
	_events.append([90.0, func() -> void:
		if not _v8.has("base"):
			return
		var b: Vector2i = _v8["base"]
		var leaf := b + Vector2i(-3, 0)
		var mid := b + Vector2i(-2, 0)
		_expect(c.grid.get_cell(leaf) == SoilGrid.Cell.TUNNEL, "test branch got dug")
		var e := c.fill_error(mid)
		_expect(e.begins_with("Would cut"), "fill of the middle cell is rejected (would strand the leaf): '%s'" % e)
		var ent := c.grid.entrances()
		if ent.size() == 1:
			_expect(c.fill_error(Vector2i(ent[0].x, Config.FIRST_SOIL_ROW)) != "", "the only entrance can't be filled")
		_expect(c.add_fill_order(leaf), "fill order on the dead-end leaf accepted (%s)" % c.fill_error(leaf))
		_expect(c.add_fill_order(mid), "fill order on the middle cell accepted once the leaf is pending")
		_expect(c.fill_error(b + Vector2i(-1, 0)) == "", "inner branch cell fillable too")
		# right-drag cancel path
		_expect(c.add_fill_order(b + Vector2i(-1, 0)) and c.cancel_fill_order(b + Vector2i(-1, 0)), "fill order can be cancelled")
		_v8["filled0"] = c.total_filled])
	_events.append([200.0, func() -> void:
		if not _v8.has("base"):
			return
		var b: Vector2i = _v8["base"]
		print("[v8] fill: total_filled %d, pending %d, mound used %d, soil used %d" % [c.total_filled, c.fill_tasks.size(), c.mound_used, c.soil_used])
		_expect(c.grid.get_cell(b + Vector2i(-3, 0)) == SoilGrid.Cell.SOIL and c.grid.get_cell(b + Vector2i(-2, 0)) == SoilGrid.Cell.SOIL, "workers filled both cells back to soil")
		_expect(not c.grid.is_walkable(b + Vector2i(-2, 0)), "filled cell is not walkable")
		_expect(c.grid.find_path(b, Vector2i(40, Config.SURFACE_ROW)).size() > 0, "nest still connected after filling")
		# castes: gynes only
		c.caste_manual = true
		c.caste_w = [0, 0, 1]
		_v8["gyne_brood0"] = c.brood_of_caste(Brood.Caste.GYNE)
		# priorities: forage off
		_v8["forage0"] = c.job_actual()[0]
		c.work_prio = [0, 2, 2, 2, 2]
		c.refresh_now()
		_expect(c.job_targets()[0] == 0, "forage priority 0 -> wanted foragers 0")])
	_events.append([260.0, func() -> void:
		var fa := c.job_actual()[0]
		print("[v8] foragers %d -> %d with forage priority off; gyne brood %d" % [int(_v8["forage0"]), fa, c.brood_of_caste(Brood.Caste.GYNE)])
		_expect(fa <= maxi(1, int(_v8["forage0"])), "fewer foragers with forage priority off (%d -> %d)" % [int(_v8["forage0"]), fa])
		_expect(c.brood_of_caste(Brood.Caste.GYNE) > int(_v8["gyne_brood0"]) or c.gyne_count() > 0, "manual ratio 0:0:1 lays gyne eggs")
		c.work_prio = [2, 2, 2, 2, 2]
		c.caste_w = [6, 2, 0]
		# threat orders
		c.standing_order = 1
		Config.threat_level = maxi(1, Config.threat_level)
		var th := c.spawn_threat(Threat.Kind.RIVAL)
		th.raider = true
		th.position.x = c.grid.entrances()[0].x * 16.0 + 40.0     # right next to a hole
		_v8["th"] = th
		_expect(c.sealed(), "standing order Seal applies during an alarm")
		_v8["raids0"] = c.raids
		c.set_alarm_order(2)
		_expect(c.evacuating() and not c.sealed(), "alarm banner choice overrides the standing order")
		var deep: Room = null
		var shallow: Room = null
		for r in c.rooms:
			if r.is_nursery():
				if deep == null or r.rect.position.y > deep.rect.position.y:
					deep = r
				if shallow == null or r.rect.position.y < shallow.rect.position.y:
					shallow = r
		if deep != shallow:
			_expect(c.brood_q(deep) > c.brood_q(shallow), "evacuate prefers the deepest nursery")
		c.set_alarm_order(1)])
	_events.append([340.0, func() -> void:
		print("[v8] seal: raids %d -> %d, threats %d, intruders %d" % [int(_v8["raids0"]), c.raids, c.threats.size(), c.intruder_count()])
		var th2 = _v8["th"]
		var still: bool = is_instance_valid(th2) and th2.raider
		var gave := false
		for e in c.events:
			if String(e).contains("entrances sealed"):
				gave = true
		print("[v8] raider valid %s, still raiding %s, gave-up event %s" % [is_instance_valid(th2), still, gave])
		_expect(c.raids == int(_v8["raids0"]), "no raid got in while sealed")
		_expect(gave and not still, "the raider found the entrances sealed and gave up")
		# nuptial flight with three gynes
		var deaths := c.total_deaths
		for i in Config.GYNE_GOAL:
			c._spawn_ant(c.queen_room.random_cell(), Ant.Caste.GYNE)
		_expect(c.can_fly(), "%d gynes allow a nuptial flight" % Config.GYNE_GOAL)
		var got := []
		c.nuptial_flight.connect(func(d: Dictionary) -> void: got.append(d), CONNECT_ONE_SHOT)
		_expect(c.start_nuptial_flight(), "nuptial flight starts")
		_expect(c.flights == 1 and c.score > 0 and got.size() == 1, "flight counted, scored and summary emitted (score %d)" % c.score)
		_expect(c.total_deaths == deaths, "flown gynes are not counted as deaths")
		_expect(not c.can_fly(), "gynes are gone after the flight")])

func _dig_line(start: Vector2i, dir: Vector2i, n: int) -> void:
	var c := _colony()
	var ok := 0
	for i in range(n + 1):
		if c.add_dig_order(start + dir * i):
			ok += 1
	print("[test] dig line from ", start, " -> ", ok, "/", n + 1, " orders accepted")

func _place(type: int, rect: Rect2i) -> void:
	var c := _colony()
	var err := c.placement_error(type, rect)
	var r := c.place_room(type, rect)
	print("[test] place ", Room.type_name(type), " ", rect, " err='", err, "' ", "OK" if r != null else "REJECTED")
	if r == null:
		_problems.append("room placement unexpectedly rejected: " + str(rect))

func _try_invalid() -> void:
	var c := _colony()
	var e1 := c.placement_error(Room.Type.NURSERY, Rect2i(60, 30, 5, 3))     # floating in soil
	var e2 := c.placement_error(Room.Type.NURSERY, Rect2i(41, 16, 5, 3))     # overlaps planned room
	var e3 := c.placement_error(Room.Type.NURSERY, Rect2i(40, 5, 5, 3))      # sky
	var o1 := c.can_order_dig(Vector2i(60, 30))                                # not adjacent to open cell
	print("[test] validation: floating='", e1, "' overlap='", e2, "' sky='", e3, "' dig-nonadjacent=", o1)
	if e1 == "" or e2 == "" or e3 == "" or o1:
		_problems.append("validation failed")
	# load error handling: missing file, garbage, wrong version, missing keys -> message, colony untouched
	var n_ants := c.ants.size()
	var bad := {"user://does_not_exist.json": null, "user://bad_garbage.json": "{not json", "user://bad_version.json": '{"version": 1}',
		"user://bad_keys.json": '{"version": 3, "rooms": []}'}
	for path in bad:
		if bad[path] != null:
			var f := FileAccess.open(path, FileAccess.WRITE)
			f.store_string(String(bad[path]))
			f.close()
		var err := SaveGame.load_file(c, path)
		print("[test] load ", path.get_file(), " -> '", err, "'")
		if err == "" or c.ants.size() != n_ants:
			_problems.append("bad save file handling: " + path)

func _simulate(duration: float, dt: float) -> void:
	var c := _colony()
	var steps := int(duration / dt)
	var next_log := 0.0
	var next_ev := 0
	var next_sample := 0.0
	var wall0 := Time.get_ticks_msec()
	for i in steps:
		while next_ev < _events.size() and c.time >= _events[next_ev][0]:
			_events[next_ev][1].call()
			next_ev += 1
		c.sim_step(dt)
		if c.time >= next_sample:
			next_sample = c.time + 2.0
			_sample()
		if c.time >= next_log:
			next_log = c.time + 60.0
			_log_line()
		if i % 2000 == 0:
			await get_tree().process_frame
	print("[test] simulated %.0f sim-s in %.1f wall-s" % [duration, (Time.get_ticks_msec() - wall0) / 1000.0])

func _log_line() -> void:
	var c := _colony()
	var tc := c.task_counts
	print("t=%4ds | W%2d S%d (idle %d nurse %d dig %d forage %d clean %d) | brood %2d/%2d e%d l%d p%d | sugar %5.1f prot %5.1f /%3.0f | waste %d hyg %.2f | thr %d | trail %.0f/%.0f | born %d died %d %s" % [
		int(c.time), c.worker_count(), c.soldier_count(), tc[0], tc[1], tc[2], tc[3], tc[4], c.brood.size(), c.nursery_capacity,
		c.brood_counts[0], c.brood_counts[1], c.brood_counts[2], c.sugar_stock, c.protein_stock, c.food_capacity,
		c.waste_items.size(), c.hygiene, c.threats.size(), c.trails[0].total, c.trails[1].total, c.total_born, c.total_deaths, str(c.death_reasons)])

func _sample() -> void:
	var c := _colony()
	_max_workers = maxi(_max_workers, c.ants.size())
	_min_workers = mini(_min_workers, c.ants.size())
	var all: Array[Ant] = c.ants.duplicate()
	all.append(c.queen)
	for a in all:
		if not (is_finite(a.position.x) and is_finite(a.position.y)):
			_problems.append("NaN position")
			continue
		if not c.grid.is_walkable(a.cell):
			_problems.append("ant on non-walkable cell %s task=%d state=%d" % [str(a.cell), a.task, a.state])
		if a.position.distance_to(c.grid.stand_pos(a.cell)) > 40.0:
			_problems.append("ant far from its cell %s pos=%s" % [str(a.cell), str(a.position)])
		if a.state == Ant.State.MOVE and a.state_time > _max_stuck:
			_max_stuck = a.state_time
			_stuck_desc = "task=%d purpose=%d cell=%s path=%d/%d" % [a.task, a.purpose, str(a.cell), a.path_i, a.path.size()]
		if not a.is_queen and a.state == Ant.State.SEARCH and a.state_time > 600.0:
			_problems.append("ant searching > 600s")
	_task_samples[c.task_counts.duplicate().hash()] = true
	if not is_finite(c.food_stock) or c.sugar_stock < -0.001 or c.protein_stock < -0.001:
		_problems.append("bad food stock %f / %f" % [c.sugar_stock, c.protein_stock])
	_min_hygiene = minf(_min_hygiene, c.hygiene)
	_max_waste = maxi(_max_waste, c.waste_items.size())
	_max_soldiers = maxi(_max_soldiers, c.soldier_count())
	_check_invariants()

func _check_invariants() -> void:
	var c := _colony()
	var seen := {}
	for b in c.brood:
		if b.dead:
			_problems.append("dead brood still listed")
		if seen.has(b.uid):
			_problems.append("duplicate brood uid")
		seen[b.uid] = true
		var r := b.room
		if r != null and (b.slot >= r.slots.size() or r.slots[b.slot] != b):
			_problems.append("brood/room slot mismatch")
		if b.in_transit and (b.carried_by == null or not is_instance_valid(b.carried_by) or not b.carried_by.carrying_brood):
			_problems.append("brood in transit without a valid carrier")
		if b.dest_room != null and b.dest_room.reserved.get(b.dest_slot) != b:
			_problems.append("brood destination not reserved")
	for r in c.rooms:
		for s in r.reserved:
			var rb: Brood = r.reserved[s]
			if rb.dead or rb.dest_room != r:
				_problems.append("stale reservation")
		for i in r.slots.size():
			if r.slots[i] != null and (r.slots[i] as Brood).dead:
				_problems.append("dead brood in slot")
	for a in c.ants:
		if a.carrying_brood and a.move_brood == null:
			_problems.append("carrying_brood without move_brood")
		if a.carry_food < -0.001 or a.carry_food > 20.0:
			_problems.append("bad carry_food")

func _save_probe() -> void:
	var c := _colony()
	var path := "user://selftest_save.json"
	var ok := SaveGame.save(c, path)
	_saved_probe = {"ok": ok, "workers": c.ants.size(), "brood": c.brood.size(), "sugar": c.sugar_stock, "protein": c.protein_stock,
		"rooms": c.rooms.size(), "trail0": c.trails[0].total, "waste": _all_waste(c), "time": c.time, "soldiers": c.soldier_count(),
		"cells": c.grid.cells.duplicate(), "hash0": hash(c.trails[0].a.to_byte_array()), "hash1": hash(c.trails[1].a.to_byte_array()), "halarm": hash(c.alarm.a.to_byte_array()), "fhash": _food_hash(c)}
	print("[test] saved at t=%d: %s" % [int(c.time), str({"workers": c.ants.size(), "brood": c.brood.size(), "rooms": c.rooms.size()})])
	# keep simulating for a while, then load it back and compare
	_events.append([c.time + 40.0, func() -> void: _load_probe(path)])

func _all_waste(c: Colony) -> int:
	var n := c.waste_items.size()
	for a in c.ants:
		if a.carrying_waste:
			n += 1     # carried refuse is saved as a lying item
	return n

func _food_hash(c: Colony) -> int:
	var arr := []
	for f in c.foods:
		arr.append([f.col, snappedf(f.amount, 0.001), f.type, f.active])
	return str(arr).hash()

func _load_probe(path: String) -> void:
	var c := _colony()
	print("[test] before load: workers %d brood %d rooms %d t=%d" % [c.ants.size(), c.brood.size(), c.rooms.size(), int(c.time)])
	var err := SaveGame.load_file(c, path)
	if err != "":
		_problems.append("load failed: " + err)
		return
	c.sim_step(0.0001)   # refresh caches
	var same: bool = c.ants.size() == _saved_probe["workers"] and c.brood.size() == _saved_probe["brood"] \
		and c.rooms.size() == _saved_probe["rooms"] and _all_waste(c) == _saved_probe["waste"] \
		and c.soldier_count() == _saved_probe["soldiers"] and c.grid.cells == _saved_probe["cells"] \
		and absf(c.sugar_stock - float(_saved_probe["sugar"])) < 0.01 and absf(c.protein_stock - float(_saved_probe["protein"])) < 0.01 \
		and absf(c.time - float(_saved_probe["time"])) < 0.01 \
		and hash(c.trails[0].a.to_byte_array()) == _saved_probe["hash0"] and hash(c.trails[1].a.to_byte_array()) == _saved_probe["hash1"] \
		and hash(c.alarm.a.to_byte_array()) == _saved_probe["halarm"] and _food_hash(c) == _saved_probe["fhash"]
	if not same:
		print("[test] detail: ants ", c.ants.size() == _saved_probe["workers"], " brood ", c.brood.size() == _saved_probe["brood"], " rooms ", c.rooms.size() == _saved_probe["rooms"],
			" waste ", _all_waste(c) == _saved_probe["waste"], " soldiers ", c.soldier_count() == _saved_probe["soldiers"], " cells ", c.grid.cells == _saved_probe["cells"],
			" sugar ", c.sugar_stock, "/", _saved_probe["sugar"], " prot ", c.protein_stock, "/", _saved_probe["protein"], " time ", c.time, "/", _saved_probe["time"],
			" h0 ", hash(c.trails[0].a.to_byte_array()) == _saved_probe["hash0"], " h1 ", hash(c.trails[1].a.to_byte_array()) == _saved_probe["hash1"],
			" alarm ", hash(c.alarm.a.to_byte_array()) == _saved_probe["halarm"], " food ", _food_hash(c) == _saved_probe["fhash"])
	print("[test] after load: workers %d brood %d rooms %d t=%d trail0 %.1f (saved %.1f) -> %s" % [c.ants.size(), c.brood.size(), c.rooms.size(), int(c.time), c.trails[0].total, _saved_probe["trail0"], "MATCH" if same else "MISMATCH"])
	if not same:
		_problems.append("save/load state mismatch")
	# second save must reproduce the same file contents (round trip)
	var d1 := SaveGame.to_dict(c)
	var d2 := SaveGame.to_dict(c)
	if JSON.stringify(d1) != JSON.stringify(d2):
		_problems.append("to_dict not deterministic")

## Rendering / memory probe: plays in real time for `secs` seconds and prints Performance monitors.
## overlays=1 cycles the pheromone and climate overlays (worst case for draw load).
func _perf_run(secs: float) -> void:
	var c := _colony()
	var t0 := Time.get_ticks_msec()
	var next := 0.0
	var frames := 0
	var peak_prims := 0.0
	var peak_calls := 0.0
	var cycle := args.has("overlays")
	var phase := -1
	print("PERF start t=%d ants=%d speed=%.1f" % [int(c.time), c.ants.size(), main.speed])
	if args.has("breakdown"):
		await _perf_breakdown()
	while true:
		await get_tree().process_frame
		frames += 1
		var el := (Time.get_ticks_msec() - t0) / 1000.0
		peak_prims = maxf(peak_prims, Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		peak_calls = maxf(peak_calls, Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
		if args.has("activity") and frames % 90 == 0:
			_perf_activity(c)
		if cycle:
			var ph := int(el / 20.0) % 3      # 0 none, 1 trails, 2 climate
			if ph != phase:
				phase = ph
				main.overlay.show_phero = ph == 1
				main.overlay.show_climate = ph == 2
		if el >= next:
			next += 10.0
			print("PERF el=%d game=%d fps=%.0f ants=%d objs=%d nodes=%d res=%d orphans=%d calls=%d prims=%d objs_frame=%d tex_mb=%.1f vid_mb=%.1f mem_mb=%.1f peak_prims=%d peak_calls=%d" % [
				int(el), int(c.time), Performance.get_monitor(Performance.TIME_FPS), c.ants.size(),
				Performance.get_monitor(Performance.OBJECT_COUNT), Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
				Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT), Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
				Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
				Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
				Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0, Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
				Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, peak_prims, peak_calls])
			peak_prims = 0.0
			peak_calls = 0.0
		if el >= secs:
			break
	print("PERF done frames=%d" % frames)

## Prints how many primitives / draw calls each top-level canvas node costs (hide it, measure the drop).
## Keep the diggers busy (dig orders next to tunnels) and the UI changing, like a real player.
func _perf_activity(c: Colony) -> void:
	var placed := 0
	for tries in 400:
		if placed >= 6 or c.dig_tasks.size() > 30:
			break
		var cell := Vector2i(randi_range(Config.DIG_MIN_X, Config.DIG_MAX_X), randi_range(Config.FIRST_SOIL_ROW + 1, Config.DIG_MAX_Y))
		if c.add_dig_order(cell):
			placed += 1
	main.set_tool(randi() % 5)
	main.set_tool(0)

func _perf_breakdown() -> void:
	var nodes: Array[CanvasItem] = []
	for n in main.find_children("*", "CanvasItem", true, false):
		var ci := n as CanvasItem
		if ci.get_parent() == main or ci.get_parent() == c_or_null() or ci.get_parent() is CanvasLayer:
			nodes.append(ci)
	for i in 4:
		await get_tree().process_frame
	var base_p := Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	var base_c := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	print("PERF breakdown base prims=%d calls=%d" % [base_p, base_c])
	for ci in nodes:
		if not ci.visible:
			continue
		ci.visible = false
		for i in 4:
			await get_tree().process_frame
		var p := Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		var cc := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		print("PERF   %-28s prims %6d calls %4d" % [str(main.get_path_to(ci)), base_p - p, base_c - cc])
		ci.visible = true
		for i in 2:
			await get_tree().process_frame

func c_or_null() -> Node:
	return _colony()

func _report(dur: float) -> void:
	var c := _colony()
	if args.has("dbg"):
		for t: DigTask in c.dig_tasks.values():
			var a := t.claimed_by
			print("[dbg] task ", t.cell, " claimed=", a != null, " claimable=", c.is_claimable(t), " blocked=", t.blocked_until, " ant=", ("" if a == null else "%s state=%d purpose=%d cell=%s path=%d/%d st=%.0f" % [a.task, a.state, a.purpose, str(a.cell), a.path_i, a.path.size(), a.state_time]))
	_log_line()
	print("---- report after %.0f sim seconds ----" % dur)
	print("workers min/max/now: %d / %d / %d" % [_min_workers, _max_workers, c.ants.size()])
	print("born %d, deaths %d %s, larvae starved %d, eggs laid %d" % [c.total_born, c.total_deaths, str(c.death_reasons), c.starved_larvae, c.total_laid])
	print("dug cells %d, total food deposited %.0f, dropped on the floor %.0f (still lying: %d piles)" % [c.total_dug, c.total_foraged, c.food_dropped_total, c.dropped.size()])
	print("brood carries %d (of which %d relocations to a better chamber), diseased brood %d | waste disposed %d (still lying %d, max %d), min hygiene %.2f, middens %s" % [c.brood_moved, c.brood_relocated, c.diseased_brood, c.waste_disposed, c.waste_items.size(), _max_waste, _min_hygiene, str(c.middens)])
	var carried := 0
	for a in c.ants:
		carried += a.soil
	print("v5: home trail %.1f, homing ok %d / fallback %d | soil dug %d = hauled %d + lost %d + carried %d | raids %d, food stolen %.1f, brood stolen %d, intruders killed %d | rain %d, flood peak %.2f, flood deaths %d" % [
		c.home.total, c.homing_ok, c.homing_fallback, c.total_dug, c.soil_hauled, c.soil_lost, carried, c.raids, c.food_stolen, c.brood_stolen, c.intruders_killed, c.rain_count, c.flood_peak, c.flood_deaths])
	print("v8: filled %d (mound pellets %d, dug pellets %d), flights %d, score %d, gynes %d, prio %s, castes %s %s" % [c.total_filled, c.mound_used, c.soil_used, c.flights, c.score, c.gyne_count(), str(c.work_prio), "manual" if c.caste_manual else "auto", str(c.caste_w)])
	if c.total_dug != c.soil_hauled + c.soil_lost + carried + c.soil_used and not args.has("savetest"):
		_problems.append("soil not conserved (dug %d, hauled %d, lost %d, carried %d)" % [c.total_dug, c.soil_hauled, c.soil_lost, carried])
	if dur >= 600.0 and c.total_dug > 4 and c.soil_hauled == 0:
		_problems.append("no soil was hauled to the surface")
	if dur >= 600.0 and c.total_foraged > 40.0 and c.homing_ok == 0:
		_problems.append("no forager ever homed along the home trail")
	print("threats seen %d, killed %d | soldiers now %d (max %d) | mounds %s" % [c.threat_count, c.threats_killed, c.soldier_count(), _max_soldiers, str(c.mounds)])
	var rq := ""
	for r in c.rooms:
		if r.type == Room.Type.NURSERY:
			rq += "%s q=%.2f  " % [str(r.rect), r.quality]
	print("nursery climate comfort: ", rq)
	var rooms := ""
	for r in c.rooms:
		rooms += "[%s %s active=%s] " % [Room.type_name(r.type), str(r.rect), str(r.active)]
	print("rooms: ", rooms)
	print("entrances: ", c.grid.entrances())
	var early := 0.0
	var late := 0.0
	var ne := 0
	var nl := 0
	for v in c.search_log:
		if v.x <= 3:
			early += v.y
			ne += 1
		elif v.x >= 8:
			late += v.y
			nl += 1
	if ne > 0 and nl > 0:
		print("pickups %d; mean search time for a source's first 3 trips %.1fs (n=%d) vs trips #8+ %.1fs (n=%d)" % [c.search_log.size(), early / ne, ne, late / nl, nl])
	if args.has("dbgwaste"):
		for w in c.waste_items:
			var ca := w.claimed_by
			print("[dbg] waste ", w.cell, " kind ", w.kind, " claimed=", ca != null, (" by task %d state %d purpose %d cell %s path %d/%d st=%.0f" % [ca.task, ca.state, ca.purpose, str(ca.cell), ca.path_i, ca.path.size(), ca.state_time]) if ca != null else "")
		for a in c.ants:
			if a.task == Ant.Task.CLEAN:
				print("[dbg] cleaner state %d purpose %d carrying %s item %s cell %s wait %.1f" % [a.state, a.purpose, str(a.carrying_waste), str(a.waste_item != null), str(a.cell), a.wait_timer])
	if args.has("events"):
		for e in c.events:
			print("   event: ", e)
	print("longest continuous MOVE seen: %.1fs (%s)" % [_max_stuck, _stuck_desc])
	var uniq := {}
	for p in _problems:
		uniq[p] = int(uniq.get(p, 0)) + 1
	for p in uniq:
		print("PROBLEM (x%d): %s" % [uniq[p], p])
	print("RESULT: ", "OK" if _problems.is_empty() else "PROBLEMS")


# ---------------------------------------------------------------- simulated player input
func _px(c: Vector2i) -> Vector2:
	return main.grid.cell_center(c)

func _key(code: int) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.physical_keycode = code
		e.pressed = pressed
		Input.parse_input_event(e)
	await get_tree().process_frame

func _move_mouse(p: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = p
	e.global_position = p
	if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		e.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(e)
	await get_tree().process_frame
	await get_tree().process_frame

func _button(p: Vector2, idx: int, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.position = p
	e.global_position = p
	e.button_index = idx
	e.pressed = pressed
	Input.parse_input_event(e)
	await get_tree().process_frame

func _click(p: Vector2, idx := MOUSE_BUTTON_LEFT) -> void:
	await _move_mouse(p)
	await _button(p, idx, true)
	await _button(p, idx, false)

func _shot(name: String) -> void:
	for i in 5:
		await get_tree().process_frame
	var path := "%s_%s.png" % [String(args["shot"]), name]
	get_viewport().get_texture().get_image().save_png(path)
	print("[ui] screenshot ", path)

func _expect(cond: bool, msg: String) -> void:
	print("[ui] ", "PASS " if cond else "FAIL ", msg)
	if not cond:
		_problems.append("ui: " + msg)

## Audio manager checks; run headless with --audiotest --forcesound (dummy audio driver).
func _audio_test() -> void:
	var au: GameAudio = main.audio
	_expect(au.enabled, "audio manager enabled (forced under the dummy driver)")
	_expect(au.missing.is_empty(), "all one-shot streams loaded (missing: %s)" % [au.missing])
	_expect(au.ambient_playing(), "both ambient loops are playing")
	for p in [au._amb_surface, au._amb_nest]:
		if p.stream is AudioStreamOggVorbis:
			var o := p.stream as AudioStreamOggVorbis
			_expect(o.loop and o.get_length() > 10.0, "ambient OGG loops (%.2f s)" % o.get_length())
		else:
			var s := p.stream as AudioStreamWAV
			_expect(s.loop_mode == AudioStreamWAV.LOOP_FORWARD and s.loop_begin == 0 and s.loop_end == s.data.size() / 2 and s.loop_end > 44100 * 10, "ambient loop set to the full sample (%d frames, %.2f s)" % [s.loop_end, float(s.loop_end) / s.mix_rate])
	for n in GameAudio.SFX:
		var st := au._stream(n)
		var one_shot := (st is AudioStreamOggVorbis and not (st as AudioStreamOggVorbis).loop) \
			or (st is AudioStreamWAV and (st as AudioStreamWAV).loop_mode == AudioStreamWAV.LOOP_DISABLED)
		_expect(st != null and st.get_length() > 0.03 and st.get_length() < 2.5 and one_shot, "%s loads as a one-shot %s (%.2f s)" % [n, st.get_class() if st != null else "?", st.get_length() if st != null else -1.0])
	# throttling: ten immediate dig requests start at most one
	var d0 := int(au.played.get("dig", 0))
	var ok := 0
	for i in 10:
		if au.play("dig"):
			ok += 1
	_expect(ok == 1 and int(au.played["dig"]) == d0 + 1 and int(au.throttled.get("dig", 0)) >= 9, "dig is throttled (%d of 10 started)" % ok)
	_expect(au.play("ui_click"), "ui_click plays")
	_expect(au.play("fight") and au.play("threat_warning") and au.play("alarm"), "fight / threat_warning / alarm play")
	_expect(not au.play("alarm"), "alarm is throttled")
	_expect(au.playing_count() <= GameAudio.POOL_SIZE, "one-shots never exceed the pool (%d playing)" % au.playing_count())
	# missing files / unknown names must be harmless
	_expect(not au.play("no_such_sound"), "unknown sound name is ignored")
	var n_missing := au.missing.size()
	_expect(au._stream("no_such_file") == null and au.missing.size() == n_missing + 1, "missing file is reported and returns null")
	au.missing.clear()
	# master volume + mute (restore the user's settings afterwards)
	var m0 := au.master
	var mu0 := au.muted
	au.set_master(0.5)
	_expect(is_equal_approx(AudioServer.get_bus_volume_db(0), linear_to_db(0.5)), "master volume applied to the Master bus")
	au.change_master(10.0)
	_expect(is_equal_approx(au.master, 1.0), "master volume clamps at 100%")
	au.change_master(-10.0)
	_expect(is_equal_approx(au.master, 0.0), "master volume clamps at 0%")
	au.muted = false
	au.toggle_mute()
	_expect(au.muted and AudioServer.is_bus_mute(0) and au.label() == "MUTED [M]", "mute switches the bus off")
	au.toggle_mute()
	_expect(not AudioServer.is_bus_mute(0), "unmute works")
	au.set_master(m0)
	au.muted = mu0
	au._apply_master()
	au._save_settings()
	# run the simulation a little with sound events enabled
	await _simulate(120.0, 1.0 / 30.0)
	print("[audio] played=", au.played, " throttled=", au.throttled)
	# let the mixer finish the one-shots before quitting so the engine can release the playbacks
	await get_tree().create_timer(2.6).timeout
	au._exit_tree()
	await get_tree().create_timer(0.5).timeout

func _audio_shutdown() -> void:
	if main.audio.enabled:
		main.audio._exit_tree()
		await get_tree().create_timer(0.5).timeout

func _ui_test() -> void:
	var c := _colony()
	main.speed = 4.0
	var au: GameAudio = main.audio
	var m_start := au.master
	var mute_start := au.muted
	_expect(au.enabled and au.ambient_playing(), "audio manager active with ambient loops (dummy driver)")
	_expect(main.ui.sound_button.text.begins_with("Sound") or main.ui.sound_button.text.begins_with("MUTED"), "HUD sound indicator shows '%s'" % main.ui.sound_button.text)
	_expect(main.ui.help_panel.visible, "help overlay is shown at start")
	await _shot("help")
	await _key(KEY_TAB)
	_expect(not main.ui.help_panel.visible, "Tab hides the help overlay")
	_expect(int(au.played.get("ui_click", 0)) >= 1, "UI click sound played for Tab")
	# --- dig tool: drag a vertical line from the surface
	await _key(KEY_2)
	_expect(main.tool == 1, "key 2 selects Dig")
	await _move_mouse(_px(Vector2i(60, 9)))
	await _button(_px(Vector2i(60, 9)), MOUSE_BUTTON_LEFT, true)
	await _move_mouse(_px(Vector2i(60, 16)))
	await _move_mouse(_px(Vector2i(64, 16)))
	await _shot("dig_drag")
	await _button(_px(Vector2i(64, 16)), MOUSE_BUTTON_LEFT, false)
	var n_orders := c.dig_tasks.size()
	_expect(n_orders >= 11, "drag painted a connected line of orders (%d)" % n_orders)
	# non adjacent cell must be refused
	await _click(_px(Vector2i(70, 30)))
	_expect(not c.dig_tasks.has(Vector2i(70, 30)), "isolated soil cell refused")
	# right-drag cancels the tail of the line
	await _move_mouse(_px(Vector2i(64, 16)))
	await _button(_px(Vector2i(64, 16)), MOUSE_BUTTON_RIGHT, true)
	await _move_mouse(_px(Vector2i(62, 16)))
	await _button(_px(Vector2i(62, 16)), MOUSE_BUTTON_RIGHT, false)
	_expect(not c.dig_tasks.has(Vector2i(63, 16)) and not c.dig_tasks.has(Vector2i(62, 16)), "right-drag cancelled orders")
	# --- nursery tool next to the queen chamber
	await _key(KEY_3)
	await _move_mouse(_px(Vector2i(35, 22)))
	_expect(main.ghost_visible and main.ghost_ok, "nursery ghost valid next to queen chamber")
	await _shot("ghost_ok")
	await _key(KEY_R)
	_expect(main.ghost_rect.size == Vector2i(3, 5), "R rotates the ghost")
	await _key(KEY_R)
	var rooms_before := c.rooms.size()
	await _click(_px(Vector2i(35, 22)))
	_expect(c.rooms.size() == rooms_before + 1, "click placed a planned nursery")
	var planned := c.room_at(Vector2i(35, 22))
	_expect(planned != null and not planned.active, "planned room is inactive until dug")
	# --- storage tool: invalid spot
	await _key(KEY_4)
	await _move_mouse(_px(Vector2i(60, 30)))
	_expect(main.ghost_visible and not main.ghost_ok, "storage ghost invalid in the middle of nowhere (%s)" % main.ghost_msg)
	await _shot("ghost_bad")
	await _click(_px(Vector2i(60, 30)))
	_expect(c.rooms.size() == rooms_before + 1, "invalid click placed nothing")
	# --- waste tool: plan a chamber next to the queen chamber
	await _key(KEY_5)
	_expect(main.tool == 4, "key 5 selects Waste")
	await _move_mouse(_px(Vector2i(45, 22)))
	_expect(main.ghost_visible and main.ghost_ok and main.ghost_type == Room.Type.WASTE, "waste ghost valid next to queen chamber (%s)" % main.ghost_msg)
	var rooms_w := c.rooms.size()
	await _click(_px(Vector2i(45, 22)))
	_expect(c.rooms.size() == rooms_w + 1, "click planned a waste chamber")
	var planned_waste := c.room_at(Vector2i(45, 22))
	# --- speed / pause / overlay keys
	await _key(KEY_P)
	_expect(main.overlay.show_phero, "P toggles pheromone overlay")
	await _key(KEY_SPACE)
	_expect(main.paused, "Space pauses")
	await _key(KEY_SPACE)
	await _key(KEY_MINUS)
	_expect(is_equal_approx(main.speed, 2.0), "minus lowers speed to 2x")
	await _key(KEY_EQUAL)
	_expect(is_equal_approx(main.speed, 4.0), "plus raises speed to 4x")
	await _key(KEY_ESCAPE)
	_expect(main.tool == 0, "Esc returns to Select")
	# --- sound keys: M mute, [ ] volume, HUD indicator, clickable button
	au.set_master(0.5)
	main.ui.show_sound(au)
	await _key(KEY_M)
	_expect(au.muted != mute_start and AudioServer.is_bus_mute(0) == au.muted, "M toggles mute (muted=%s)" % au.muted)
	_expect(main.ui.sound_button.text == au.label() and (not au.muted or main.ui.sound_button.text.begins_with("MUTED")), "HUD shows '%s'" % main.ui.sound_button.text)
	await _shot("muted")
	await _click(main.ui.sound_button.get_global_rect().get_center())
	_expect(au.muted == mute_start, "clicking the sound button toggles mute back")
	await _key(KEY_BRACKETRIGHT)
	_expect(is_equal_approx(au.master, 0.6) and main.ui.sound_button.text.contains("60%"), "] raises volume to 60%% (%s)" % main.ui.sound_button.text)
	await _key(KEY_BRACKETLEFT)
	await _key(KEY_BRACKETLEFT)
	_expect(is_equal_approx(au.master, 0.4), "[ lowers volume to 40%")
	au.set_master(m_start)
	au.muted = mute_start
	au._apply_master()
	au._save_settings()
	main.ui.show_sound(au)
	# --- run 4x for a while: everything planned should get dug out
	var t0 := c.time
	var frames := 0
	while c.time - t0 < 240.0 and frames < 6000 and (c.dig_tasks.size() > 0):
		await get_tree().process_frame
		frames += 1
	print("[ui] ran %d frames (%.0f sim s) at 4x, remaining dig orders: %d" % [frames, c.time - t0, c.dig_tasks.size()])
	_expect(int(au.played.get("dig", 0)) >= 1, "dig sound played during excavation (%d plays, %d throttled)" % [int(au.played.get("dig", 0)), int(au.throttled.get("dig", 0))])
	_expect(planned.active, "planned nursery became active after being dug out")
	_expect(planned_waste != null and planned_waste.active and planned_waste.type == Room.Type.WASTE, "planned waste chamber became active")
	_expect(c.grid.get_cell(Vector2i(60, 12)) == SoilGrid.Cell.TUNNEL, "painted shaft was dug")
	_expect(c.grid.entrances().has(Vector2i(60, 8)), "new entrance registered")
	# --- select an ant by clicking it
	await _key(KEY_1)
	var a: Ant = c.ants[0]
	await _click(a.position)
	_expect(main.selected_ant != null, "click selects an ant")
	await _shot("selected")
	# --- climate overlay, mode buttons, save / load
	await _key(KEY_H)
	_expect(main.overlay.show_climate, "H toggles the climate overlay")
	await _move_mouse(_px(Vector2i(30, 25)))
	await _shot("climate")
	await _key(KEY_H)
	# --- v8 Orders panel
	var ui: GameUI = main.ui
	await _click(ui.soldier_button.get_global_rect().get_center())
	_expect(ui.orders_panel.visible, "Orders button opens the orders panel")
	await _click(ui.prio_plus[0].get_global_rect().get_center())
	_expect(int(c.work_prio[0]) == 3, "Forage + raises the priority (%d)" % int(c.work_prio[0]))
	await _click(ui.caste_auto_button.get_global_rect().get_center())
	_expect(c.caste_manual, "caste button switches to the manual ratio")
	for i in 8:
		await get_tree().process_frame
	await _shot("orders")
	await _click(ui.preset_buttons[0].get_global_rect().get_center())
	_expect(c.work_prio == [2, 2, 2, 2, 2], "Balanced preset resets priorities")
	await _click(ui.caste_auto_button.get_global_rect().get_center())
	_expect(not c.caste_manual, "caste button back to Auto")
	await _key(KEY_O)
	_expect(not ui.orders_panel.visible, "O closes the orders panel")
	# --- v8 Fill tool
	await _key(KEY_6)
	_expect(int(main.tool) == 5, "6 selects the Fill tool")
	await _key(KEY_1)
	await _key(KEY_F)
	_expect(int(main.tool) == 5, "F selects the Fill tool")
	await _move_mouse(_px(c.queen_room.rect.position + Vector2i(1, 0)))
	_expect(main.hover_visible and not main.hover_ok and main.fill_msg.contains("queen"), "red fill ghost explains the queen chamber (%s)" % main.fill_msg)
	await _shot("fill_bad")
	var fc := Vector2i(-1, -1)
	for i in c.grid.walk_idx:
		var cc := Vector2i(i % Config.GRID_W, i / Config.GRID_W)
		if cc.y > Config.FIRST_SOIL_ROW + 2 and c.fill_error(cc) == "":
			fc = cc
			break
	_expect(fc.x >= 0, "some tunnel cell can be filled")
	if fc.x >= 0:
		await _move_mouse(_px(fc))
		_expect(main.hover_ok, "green fill ghost on a dead-end cell")
		await _click(_px(fc))
		_expect(c.fill_tasks.has(fc), "click paints a fill order")
		await _shot("fill_order")
		await _click(_px(fc), MOUSE_BUTTON_RIGHT)
		_expect(not c.fill_tasks.has(fc), "right-click cancels the fill order")
	await _key(KEY_1)
	var tb: Button = main.ui.threat_button
	var lvl := Config.threat_level
	await _click(tb.get_global_rect().get_center())
	_expect(Config.threat_level == (lvl + 1) % 3, "threat button cycles the level (%s)" % tb.text)
	await _click(tb.get_global_rect().get_center())
	await _click(tb.get_global_rect().get_center())
	_expect(Config.threat_level == lvl, "threat button wraps")
	await _key(KEY_SPACE)
	var snap_ants := c.ants.size()
	var snap_brood := c.brood.size()
	var snap_rooms := c.rooms.size()
	var snap_t := c.time
	var f5 := SaveGame.DEFAULT_PATH
	if FileAccess.file_exists(f5):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(f5))
	await _key(KEY_K)
	_expect(FileAccess.file_exists(f5), "F5 wrote the save file")
	await get_tree().process_frame
	await _key(KEY_L)
	_expect(c.ants.size() == snap_ants and c.brood.size() == snap_brood and c.rooms.size() == snap_rooms and absf(c.time - snap_t) < 0.01, "F9 restored the saved colony (%d ants, %d brood, %d rooms)" % [c.ants.size(), c.brood.size(), c.rooms.size()])
	await _key(KEY_SPACE)
	for i in 120:
		await get_tree().process_frame
	_expect(not main.paused and c.time > snap_t + 1.0, "game keeps running after loading")
	_expect(main.ui.log_label.text != "", "event log shows lines")
	# --- a predator shows up: alarm + soldiers
	for i in 3:
		c._spawn_ant(Vector2i(c.grid.entrances()[0].x, Config.FIRST_SOIL_ROW + 1 + i), Ant.Caste.SOLDIER)
	var th := c.spawn_threat(Threat.Kind.SPIDER)
	th.position.x = c.grid.entrances()[0].x * 16.0 + 70.0
	_expect(int(au.played.get("threat_warning", 0)) >= 1, "threat warning sound played when the spider appeared")
	var t_spawn := c.time
	var max_poly := 0
	var shot_done := false
	while c.time - t_spawn < 60.0 and not c.threats.is_empty():
		await get_tree().process_frame
		max_poly = maxi(max_poly, au.playing_count())
		if not shot_done and c.time - t_spawn > 1.5 and not c.threats.is_empty():
			shot_done = true
			_expect(main.ui.alarm_panel.visible, "alarm banner is shown during the threat")
			await _click(main.ui.alarm_buttons[1].get_global_rect().get_center())
			_expect(c.current_order() == 1 and c.sealed(), "alarm banner: Seal entrances")
			await _click(main.ui.alarm_buttons[0].get_global_rect().get_center())
			_expect(c.current_order() == 0, "alarm banner: Fight")
			await _key(KEY_P)
			await _shot("threat")
			await _key(KEY_P)
	print("[ui] threat resolved after %.0f sim s; soldiers %d" % [c.time - t_spawn, c.soldier_count()])
	_expect(shot_done, "a threat screenshot was taken while it was alive")
	_expect(int(au.played.get("fight", 0)) >= 1, "fight sound played during combat (%d plays)" % int(au.played.get("fight", 0)))
	_expect(max_poly <= GameAudio.POOL_SIZE, "simultaneous one-shots stayed within the limit (max %d)" % max_poly)
	print("[ui] audio played=", au.played, " throttled=", au.throttled)
	# --- v8 nuptial flight + summary
	for i in Config.GYNE_GOAL:
		c._spawn_ant(c.queen_room.random_cell(), Ant.Caste.GYNE)
	for i in 30:
		await get_tree().process_frame
	await _key(KEY_O)
	for i in 10:
		await get_tree().process_frame
	_expect(not main.ui.fly_button.disabled, "flight button enabled with %d gynes" % Config.GYNE_GOAL)
	await _shot("gynes")
	await _click(main.ui.fly_button.get_global_rect().get_center())
	_expect(c.flights == 1 and main.ui.summary_panel.visible and main.paused, "nuptial flight shows the summary and pauses")
	await _shot("flight_summary")
	await _click(main.ui.summary_button.get_global_rect().get_center())
	_expect(not main.ui.summary_panel.visible and not main.paused, "Continue closes the summary")
	await _key(KEY_O)
	# --- inspect the waste chamber
	await _key(KEY_1)
	await _click(_px(Vector2i(33, 19)))
	_expect(main.selected_room != null and main.selected_room.type == Room.Type.WASTE, "clicking the waste chamber selects it")
	await _shot("room_info")
	# --- right click cancels a planned room
	await _key(KEY_3)
	await _move_mouse(_px(Vector2i(24, 30)))
	await _audio_shutdown()
	# --- v6 tutorial: the Tutorial button starts it, the target button is highlighted, Skip closes it
	var tut: Tutorial = main.tutorial
	await _click(main.ui.tutorial_button.get_global_rect().get_center())
	for i in 3:
		await get_tree().process_frame
	_expect(tut.running() and tut.visible and tut.step == 0, "Tutorial button opens the tutorial")
	tut.advance()
	await get_tree().process_frame
	_expect(tut._target() == main.ui.tool_buttons[1], "dig step highlights the Dig button")
	await _shot("tutorial")
	await _click(tut._skip.get_global_rect().get_center())
	await get_tree().process_frame
	_expect(not tut.running() and not tut.visible and tut.done_once, "Skip closes the tutorial")
	print("[ui] done: workers=%d brood=%d food=%.1f" % [c.ants.size(), c.brood.size(), c.food_stock])
