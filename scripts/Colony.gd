class_name Colony
extends Node2D
## The colony simulation: rooms, brood, food (sugar / protein), dig orders, waste, task allocation
## (utility scoring / age polyethism), soldiers, threats, microclimate, queen egg laying.
## Everything advances through sim_step(dt), driven by Main at a fixed step so
## pause / 1x / 2x / 4x are exact and a headless test can run thousands of seconds.

enum SoldierMode { AUTO, OFF, MAX }
const SOLDIER_MODE_NAMES := ["Auto", "Off", "Max"]
const N_TASKS := 6

var grid: SoilGrid
var trails: Array[PheroGrid] = []       # one food trail per food type
var alarm: PheroGrid
var home: PheroGrid                     # v5: home / nest trail laid by outbound ants
var flood := PackedFloat32Array()       # v5: water level per cell (0..1)
var rooms: Array[Room] = []
var queen_room: Room = null
var ants: Array[Ant] = []               # every ant except the queen (workers + soldiers)
var queen: Ant = null
var brood: Array[Brood] = []
var foods: Array[FoodSource] = []
var threats: Array[Threat] = []
var dig_tasks: Dictionary = {}          # Vector2i -> DigTask
var fill_tasks: Dictionary = {}         # v8: Vector2i -> DigTask (fill orders: tunnel -> soil)
var total_filled := 0
var soil_used := 0                      # dug pellets packed back into filled cells (soil bookkeeping)
var mound_used := 0
var waste_items: Array[WasteItem] = []
var dropped: Dictionary = {}            # Vector3i(x, y, food type) -> amount lying on the floor
var mounds: Dictionary = {}             # entrance column -> excavated soil pellets (visual)
var middens: Dictionary = {}            # entrance column -> refuse dumped outside (visual)
var fx: Array = []                      # short visual effects
var audio: GameAudio = null               # optional sound manager (set by Main)
var _alarm_was := false
var events: Array[String] = []          # event log shown in the HUD

var time := 0.0
var sugar_stock := 0.0
var protein_stock := 0.0
var food_stock := 0.0                   # sugar + protein
var food_capacity := 0.0
var lay_timer := 6.0
var soldier_mode: int = SoldierMode.AUTO
# v8 player decisions
var work_prio: Array = [2, 2, 2, 2, 2]     # Forage, Nurse, Dig, Clean, Guard (0..4)
var caste_manual := false                   # false = Auto (old soldier logic + gynes in big colonies)
var caste_w: Array = [6, 2, 0]              # manual weights: worker, soldier, gyne (0..10)
var standing_order := 0                     # Config.ORDER_NAMES
var active_order := -1                      # chosen during the current alarm (-1 = use the standing order)
var _calm_t := 0.0
var flights := 0
var gynes_flown := 0
var score := 0
signal nuptial_flight(summary: Dictionary)
var hygiene := 1.0
var next_uid := 1

# cached needs (refreshed once per sim second)
var need_hungry := 0                    # larvae wanting food, nobody on the way
var need_move := 0                      # brood to carry (loose eggs, better chambers)
var need_dig := 0                       # claimable, unclaimed dig tasks
var dig_pending := 0                    # all unclaimed dig tasks
var need_clean := 0                     # unclaimed waste items
var task_counts: Array[int] = [0, 0, 0, 0, 0, 0]
var brood_counts: Array[int] = [0, 0, 0]
var soldier_brood := 0
var nursery_capacity := 0
var _needs_t := 0.0
var _waste_t := 30.0
var _threat_t := 0.0
var _climate_t := 0.0
var row_rate := PackedFloat32Array()
var last_threat_t := -9999.0
var threat_count := 0
var _hygiene_warned := false
var _starve_warned := false

# statistics
var total_born := 0
var total_deaths := 0
var death_reasons: Dictionary = {}
var total_foraged := 0.0
var total_laid := 0
var total_dug := 0
var starved_larvae := 0
var diseased_brood := 0
var waste_disposed := 0
var threats_killed := 0
var brood_moved := 0
var brood_relocated := 0
var food_dropped_total := 0.0
# v5 statistics / state
var homing_ok := 0                      # loaded foragers that found an entrance by the home trail
var homing_fallback := 0                # ... that gave up and used A*
var soil_hauled := 0
var soil_lost := 0
var raids := 0
var food_stolen := 0.0
var brood_stolen := 0
var intruders_killed := 0
var raining := false
var rain_intensity := 0.0
var rain_left := 0.0
var _rain_t := 0.0
var rain_count := 0
var flood_peak := 0.0
var flood_deaths := 0
var flooded_cells := 0
var _rain_tick := 0.0
var search_log: Array[Vector2] = []     # (pickup index within the source's life, seconds spent searching)

var ant_container: Node2D
var food_container: Node2D

func setup(g: SoilGrid) -> void:
	grid = g
	trails = [PheroGrid.new(grid), PheroGrid.new(grid)]
	alarm = PheroGrid.new(grid, 0.10, 0.12, 3.0)
	home = PheroGrid.new(grid, Config.HOME_EVAP, Config.HOME_DIFFUSE, Config.HOME_MAX)
	flood.resize(Config.GRID_W * Config.GRID_H)
	flood.fill(0.0)
	_rain_t = Config.RAIN_FIRST * randf_range(0.8, 1.2)
	row_rate.resize(Config.GRID_H)
	ant_container = Node2D.new()
	ant_container.name = "Ants"
	add_child(ant_container)
	food_container = Node2D.new()
	food_container.name = "FoodSources"
	add_child(food_container)
	move_child(food_container, 0)
	_make_start_rooms()
	_spawn_queen()
	var founding := not Config.classic_start
	for i in (Config.FOUND_WORKERS if founding else Config.START_WORKERS):
		var at := queen_room.random_cell() if founding else random_nest_cell(Vector2i(46, 14), 10)
		var a := _spawn_ant(at, Ant.Caste.WORKER, true)
		# nanitic workers of a founding colony are all young
		a.age = randf_range(0.02, 0.2 if founding else 0.65) * a.lifespan
	_seed_brood()
	for i in Config.FOOD_LAYOUT.size():
		var f := FoodSource.new()
		food_container.add_child(f)
		foods.append(f)
		f.setup(self, pick_food_column(null), randf_range(Config.FOOD_AMOUNT_MIN, Config.FOOD_AMOUNT_MAX), Config.FOOD_LAYOUT[i])
	_recount_capacity()
	if founding:
		queen_room.sugar = Config.FOUND_SUGAR
		queen_room.protein = Config.FOUND_PROTEIN
	else:
		for r in rooms:
			if r.type == Room.Type.FOOD_STORAGE:
				r.sugar = minf(Config.START_SUGAR, r.capacity() * Config.type_cap(0))
				r.protein = minf(Config.START_PROTEIN, r.capacity() * Config.type_cap(1))
				break
	_recount_food()
	_refresh_climate()
	_refresh_needs()
	for a in ants:
		a.task = choose_task(a)
	reset_threat_timer()
	if founding:
		log_event("A young queen has sealed herself in with her first workers. Dig her a home!", "queen_chamber")
	else:
		log_event("The colony wakes up. Press Tab for help.", "worker")

# ------------------------------------------------------------------ setup helpers
func _make_start_rooms() -> void:
	if not Config.classic_start:
		queen_room = _add_room(Room.Type.QUEEN_CHAMBER, Config.FOUND_QUEEN_RECT, true)
		return
	queen_room = _add_room(Room.Type.QUEEN_CHAMBER, Rect2i(38, 21, 5, 3), true)
	_add_room(Room.Type.FOOD_STORAGE, Rect2i(29, 12, 5, 2), true)
	_add_room(Room.Type.NURSERY, Rect2i(46, 14, 5, 2), true)
	_add_room(Room.Type.WASTE, Rect2i(32, 18, 4, 2), true)

func _add_room(type: int, rect: Rect2i, active: bool) -> Room:
	var r := Room.new()
	r.type = type
	r.rect = rect
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			if grid.get_cell(Vector2i(x, y)) != SoilGrid.Cell.TUNNEL:
				r.undug += 1
	if active or r.undug == 0:
		r.activate()
	rooms.append(r)
	return r

func _spawn_queen() -> void:
	var q := Ant.new()
	ant_container.add_child(q)
	q.setup(self, queen_room.random_cell(), Ant.Caste.WORKER, true)
	q.lifespan = 1e9
	q.task = Ant.Task.IDLE
	queen = q

func _spawn_ant(at: Vector2i, caste: int, initial := false) -> Ant:
	var a := Ant.new()
	ant_container.add_child(a)
	a.setup(self, at, caste)
	ants.append(a)
	if not initial:
		total_born += 1
	return a

func _seed_brood() -> void:
	if not Config.classic_start:
		for i in Config.FOUND_EGGS:
			_add_brood(queen_room, Brood.Stage.EGG, randf_range(0.0, Config.EGG_TIME * 0.8))
		for i in Config.FOUND_LARVAE:
			_add_brood(queen_room, Brood.Stage.LARVA, randf_range(0.0, Config.LARVA_TIME * 0.5))
		return
	var nur := first_active(Room.Type.NURSERY)
	if nur == null:
		return
	for i in 3:
		_add_brood(nur, Brood.Stage.EGG, randf_range(0.0, Config.EGG_TIME * 0.8))
	for i in 3:
		_add_brood(nur, Brood.Stage.LARVA, randf_range(0.0, Config.LARVA_TIME * 0.6))
	for i in 2:
		_add_brood(nur, Brood.Stage.PUPA, randf_range(0.0, Config.PUPA_TIME * 0.7))

func _add_brood(nur: Room, stage: int, t: float, caste := Brood.Caste.WORKER) -> Brood:
	var s := nur.free_slot()
	if s < 0:
		return null
	var b := Brood.new()
	b.uid = next_uid
	next_uid += 1
	b.stage = stage
	b.caste = caste
	b.t = t
	b.fed = randf_range(0.45, 0.9)
	b.room = nur
	b.slot = s
	nur.slots[s] = b
	brood.append(b)
	return b

func pick_food_column(me: FoodSource) -> int:
	var entr := grid.entrances()
	for attempt in 40:
		var c := randi_range(3, Config.GRID_W - 4)
		var ok := true
		for f in foods:
			if f != me and f.active and absi(f.col - c) < Config.FOOD_MIN_SPACING:
				ok = false
		for e in entr:
			if absi(e.x - c) < Config.FOOD_MIN_FROM_ENTRY:
				ok = false
		if ok:
			return c
	return randi_range(3, Config.GRID_W - 4)

# ------------------------------------------------------------------ simulation step
func sim_step(dt: float) -> void:
	time += dt
	for t in trails:
		t.step(dt)
	alarm.step(dt)
	home.step(dt)
	_step_rain(dt)
	_step_orders(dt)
	for f in foods:
		f.step(dt)
	for a in ants.duplicate():
		a.step(dt)
	queen.step(dt)
	for th in threats.duplicate():
		th.step(dt)
	for b in brood.duplicate():
		_step_brood(b, dt)
	_step_laying(dt)
	_consume(dt)
	_step_waste(dt)
	_step_threat_spawn(dt)
	_step_fx(dt)
	var al := alarm_active()
	if al and not _alarm_was:
		sfx("alarm")
	_alarm_was = al
	_climate_t -= dt
	if _climate_t <= 0.0:
		_climate_t = 0.5
		_refresh_climate()
	_needs_t -= dt
	if _needs_t <= 0.0:
		_needs_t = 1.0
		_refresh_needs()

func _consume(dt: float) -> void:
	var soldiers := soldier_count()
	var gynes := gyne_count()
	var workers := ants.size() - soldiers - gynes
	var want := (workers * Config.SUGAR_RATE_WORKER + soldiers * Config.SUGAR_RATE_SOLDIER + gynes * Config.SUGAR_RATE_GYNE + Config.SUGAR_RATE_QUEEN) * dt
	take_food(want, Config.Food.SUGAR, Vector2i(-1, -1))

func _step_laying(dt: float) -> void:
	var mult := clampf(protein_stock / Config.LAY_COMFORT, 0.25, 1.0)
	lay_timer -= dt * mult
	if lay_timer > 0.0:
		return
	var caste := pick_egg_caste()
	var cost: float = Config.CASTE_PROTEIN[caste]
	var scost: float = Config.CASTE_SUGAR[caste]
	if protein_stock < maxf(Config.LAY_PROTEIN_MIN, cost) or sugar_stock <= 0.01 + scost or queen.hunger >= 0.9:
		return
	if free_nursery_slots() - loose_brood_count() <= 0:
		return
	var b := Brood.new()
	b.uid = next_uid
	next_uid += 1
	b.caste = caste
	if scost > 0.0:
		take_food(scost, Config.Food.SUGAR, Vector2i(-1, -1))
	b.loose_cell = queen_room.random_cell()
	b.fed = 0.8
	brood.append(b)
	take_food(cost, Config.Food.PROTEIN, Vector2i(-1, -1))
	total_laid += 1
	lay_timer = Config.EGG_INTERVAL * randf_range(0.8, 1.2)
	add_fx(grid.cell_center(b.loose_cell), "egg", "")

func _brood_rate(b: Brood) -> float:
	if b.in_transit:
		return 1.0
	return row_rate[clampi(b.cell().y, 0, Config.GRID_H - 1)]

func _step_brood(b: Brood, dt: float) -> void:
	var m := _brood_rate(b)
	if not b.in_transit and flooded_cells > 0 and is_flooded(b.cell()):
		m *= 0.3
		if randf() < Config.FLOOD_BROOD_DEATH * dt:
			flood_deaths += 1
			log_event("A %s drowned in a flooded chamber." % b.stage_name().to_lower(), "climate")
			_remove_brood(b, true)
			return
	if b.stage != Brood.Stage.PUPA and hygiene < Config.HYGIENE_BAD:
		var p := (Config.HYGIENE_BAD - hygiene) / Config.HYGIENE_BAD * Config.BROOD_DISEASE_RATE * dt
		if randf() < p:
			diseased_brood += 1
			log_event("A %s died of disease (dirty nest)." % b.stage_name().to_lower(), "clean")
			_remove_brood(b, true)
			return
	match b.stage:
		Brood.Stage.EGG:
			b.t += dt * m
			if b.t >= Config.EGG_TIME:
				b.stage = Brood.Stage.LARVA
				sfx("egg_hatch")
				b.t = 0.0
				b.fed = 0.8
		Brood.Stage.LARVA:
			b.fed = maxf(0.0, b.fed - dt / Config.LARVA_FED_DECAY)
			var rate := 1.0
			if b.fed <= 0.0:
				rate = 0.0
				b.starve_t += dt
				if b.starve_t >= Config.LARVA_STARVE_DEATH:
					starved_larvae += 1
					_remove_brood(b, true)
					return
			else:
				b.starve_t = maxf(0.0, b.starve_t - dt)
				if b.fed < 0.25:
					rate = 0.35
			b.t += dt * rate * m
			if b.t >= Config.LARVA_TIME * Config.CASTE_TIME[b.caste]:
				b.stage = Brood.Stage.PUPA
				b.t = 0.0
				b.claimed_by = null
		Brood.Stage.PUPA:
			b.t += dt * m
			if b.t >= Config.PUPA_TIME * Config.CASTE_TIME[b.caste] and not b.in_transit and ants.size() < Config.MAX_WORKERS:
				var c := b.cell()
				var caste := b.caste
				_remove_brood(b, false)
				var a := _spawn_ant(c, caste)     # Brood.Caste and Ant.Caste share the order
				if caste == Brood.Caste.SOLDIER:
					log_event("A soldier ant emerged.", "soldier")
				elif caste == Brood.Caste.GYNE:
					log_event("A winged gyne emerged (%d/%d for a nuptial flight)." % [gyne_count(), Config.GYNE_GOAL], "queen_chamber")
				add_fx(a.position, "pop", "")

func _remove_brood(b: Brood, corpse: bool) -> void:
	b.dead = true
	var cell := b.cell()
	var r := b.room
	if r != null and b.slot < r.slots.size() and r.slots[b.slot] == b:
		r.slots[b.slot] = null
	var d := b.dest_room
	if d != null:
		d.reserved.erase(b.dest_slot)
	b.dest_room = null
	if b.claimed_by != null and is_instance_valid(b.claimed_by):
		(b.claimed_by as Ant).target_brood = null
	b.claimed_by = null
	if b.carried_by != null and is_instance_valid(b.carried_by):
		var ca := b.carried_by as Ant
		ca.move_brood = null
		ca.carrying_brood = false
		cell = ca.cell
	b.carried_by = null
	brood.erase(b)
	if corpse:
		add_waste(cell, WasteItem.Kind.CORPSE)

# ------------------------------------------------------------------ brood logistics (nurses)
func loose_brood_count() -> int:
	var n := 0
	for b in brood:
		if b.is_loose():
			n += 1
	return n

func free_nursery_slots() -> int:
	var n := 0
	for r in rooms:
		if r.is_nursery():
			n += r.free_slot_count()
	return n

## Reserve a slot for `b` in the best nursery (other than `exclude`); false if there is no room.
## Brood placement quality: the queen chamber is only a stop-gap nursery.
func brood_q(r: Room) -> float:
	if evacuating():
		return float(r.rect.get_center().y) / float(Config.GRID_H)     # deepest chamber wins
	return r.quality - (Config.QUEEN_BROOD_PENALTY if r.type == Room.Type.QUEEN_CHAMBER else 0.0)

func _reserve_dest(b: Brood, exclude: Room, min_quality: float) -> bool:
	var best: Room = null
	for r in rooms:
		if not r.is_nursery() or r == exclude or r.free_slot_count() <= 0:
			continue
		if brood_q(r) < min_quality:
			continue
		if best == null or brood_q(r) > brood_q(best) + 0.001 \
				or (absf(brood_q(r) - brood_q(best)) <= 0.001 and r.free_slot_count() > best.free_slot_count()):
			best = r
	if best == null:
		return false
	var s := best.free_slot()
	if s < 0:
		return false
	best.reserved[s] = b
	b.dest_room = best
	b.dest_slot = s
	return true

func _find_relocation() -> Brood:
	for b in brood:
		var r := b.room
		if r == null or b.carried_by != null or b.claimed_by != null or b.in_transit or b.move_ready > time:
			continue
		for o in rooms:
			if o.is_nursery() and o != r and brood_q(o) - brood_q(r) > Config.BROOD_MOVE_MARGIN \
					and o.free_slot_count() > 0:
				return b
	return null

func claim_brood_move(a: Ant) -> Brood:
	for b in brood:
		if b.is_loose() and b.carried_by == null:
			if _reserve_dest(b, null, 0.0):
				b.carried_by = a
				return b
	var cand := _find_relocation()
	if cand != null and _reserve_dest(cand, cand.room, cand.room.quality + Config.BROOD_MOVE_MARGIN):
		cand.carried_by = a
		brood_relocated += 1
		return cand
	return null

func pickup_brood(b: Brood) -> void:
	var r := b.room
	if r != null and r.slots[b.slot] == b:
		r.slots[b.slot] = null
	b.room = null
	b.in_transit = true

func place_brood(b: Brood) -> void:
	var r := b.dest_room
	if r == null or b.dest_slot < 0:
		return
	r.reserved.erase(b.dest_slot)
	r.slots[b.dest_slot] = b
	b.room = r
	b.slot = b.dest_slot
	b.dest_room = null
	b.dest_slot = -1
	b.in_transit = false
	b.carried_by = null
	b.move_ready = time + Config.BROOD_MOVE_COOLDOWN
	brood_moved += 1

## Carrier died / changed its mind: the brood stays where the carrier stands.
func release_brood(b: Brood, at: Vector2i) -> void:
	var d := b.dest_room
	if d != null:
		d.reserved.erase(b.dest_slot)
	b.dest_room = null
	b.dest_slot = -1
	b.carried_by = null
	if b.in_transit:
		b.in_transit = false
		b.loose_cell = at

func claim_hungry_larva(a: Ant) -> Brood:
	var best: Brood = null
	for b in brood:
		if b.stage == Brood.Stage.LARVA and b.room != null and not b.in_transit and b.claimed_by == null \
				and b.carried_by == null and b.fed < Config.FEED_THRESHOLD:
			if best == null or b.fed < best.fed:
				best = b
	if best != null:
		best.claimed_by = a
	return best

func feed_larva(b: Brood, food: float) -> void:
	b.fed = minf(1.0, b.fed + Config.FEED_GAIN * (food / Config.NURSE_FEED_COST))
	b.starve_t = 0.0
	add_fx(grid.cell_center(b.cell()) + Vector2(0, -8), "heart", "")

# ------------------------------------------------------------------ rooms
func first_active(type: int) -> Room:
	for r in rooms:
		if r.type == type and r.active:
			return r
	return null

func random_nursery_cell() -> Vector2i:
	var list: Array[Room] = []
	for r in rooms:
		if r.is_nursery():
			list.append(r)
	if list.is_empty():
		return Vector2i(-1, -1)
	return list[randi() % list.size()].random_cell()

func room_at(c: Vector2i) -> Room:
	for r in rooms:
		if r.contains(c):
			return r
	return null

## Why a chamber can't go here ("" = valid).
func placement_error(_type: int, rect: Rect2i) -> String:
	if rect.position.x < Config.DIG_MIN_X or rect.end.x - 1 > Config.DIG_MAX_X \
			or rect.position.y < Config.MIN_ROOM_ROW or rect.end.y - 1 > Config.DIG_MAX_Y:
		return "Out of bounds (keep it below the grass and inside the map)"
	for r in rooms:
		if r.rect.intersects(rect):
			return "Overlaps another chamber"
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var c := Vector2i(x, y)
			if grid.is_walkable(c):
				return ""
			for d in SoilGrid.N4:
				if not rect.has_point(c + d) and grid.is_walkable(c + d):
					return ""
	return "Must touch an existing tunnel"

func place_room(type: int, rect: Rect2i) -> Room:
	if placement_error(type, rect) != "":
		return null
	var r := _add_room(type, rect, false)
	if r.active:
		_recount_capacity()
		return r
	for y in range(rect.position.y, rect.end.y):
		for x in range(rect.position.x, rect.end.x):
			var c := Vector2i(x, y)
			if grid.get_cell(c) == SoilGrid.Cell.SOIL and not dig_tasks.has(c):
				var t := DigTask.new()
				t.cell = c
				t.room = r
				dig_tasks[c] = t
			elif dig_tasks.has(c):
				(dig_tasks[c] as DigTask).room = r
	return r

func cancel_room(r: Room) -> void:
	if r.active or r.type == Room.Type.QUEEN_CHAMBER:
		return
	for c in dig_tasks.keys():
		var t: DigTask = dig_tasks[c]
		if t.room == r:
			_drop_task(t)
	rooms.erase(r)

func _recount_capacity() -> void:
	food_capacity = 0.0
	nursery_capacity = 0
	for r in rooms:
		r.quality = 0.0 if r.flooded else Climate.mean_quality(r.rect.get_center().y)
		if not r.active:
			continue
		if r.is_store():
			food_capacity += r.capacity()
		if r.is_nursery():
			nursery_capacity += r.brood_cap()

# ------------------------------------------------------------------ digging
func can_order_dig(c: Vector2i) -> bool:
	if not grid.is_diggable(c) or grid.get_cell(c) != SoilGrid.Cell.SOIL or dig_tasks.has(c):
		return false
	if grid.has_open_neighbor(c):
		return true
	for d in SoilGrid.N4:
		if dig_tasks.has(c + d):
			return true
	return false

func add_dig_order(c: Vector2i) -> bool:
	if not can_order_dig(c):
		return false
	var t := DigTask.new()
	t.cell = c
	dig_tasks[c] = t
	return true

func cancel_dig_order(c: Vector2i) -> bool:
	if not dig_tasks.has(c):
		return false
	var t: DigTask = dig_tasks[c]
	if t.room != null:
		return false
	_drop_task(t)
	return true

func _drop_task(t: DigTask) -> void:
	if t.claimed_by != null and is_instance_valid(t.claimed_by):
		(t.claimed_by as Ant).dig_task = null
	t.claimed_by = null
	dig_tasks.erase(t.cell)

func is_claimable(t: DigTask) -> bool:
	return grid.get_cell(t.cell) == SoilGrid.Cell.SOIL and grid.has_open_neighbor(t.cell)

func claim_dig_task(a: Ant) -> DigTask:
	var best: DigTask = null
	var best_d := 1 << 30
	for t: DigTask in dig_tasks.values():
		if t.claimed_by != null or t.blocked_until > time or not is_claimable(t):
			continue
		var d := absi(t.cell.x - a.cell.x) + absi(t.cell.y - a.cell.y)
		if d < best_d:
			best_d = d
			best = t
	if best != null:
		best.claimed_by = a
	return best

## Open cell next to `target` that is closest to `from`.
func dig_access_cell(target: Vector2i, from: Vector2i) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_d := 1 << 30
	for d in SoilGrid.N4:
		var c := target + d
		if grid.is_walkable(c):
			var dd := absi(c.x - from.x) + absi(c.y - from.y)
			if dd < best_d:
				best_d = dd
				best = c
	return best

## Returns true if a cell was excavated (the digger then carries one soil pellet out).
func complete_dig(t: DigTask) -> bool:
	dig_tasks.erase(t.cell)
	t.claimed_by = null
	var dug := false
	if grid.dig(t.cell):
		dug = true
		total_dug += 1
		add_fx(grid.cell_center(t.cell), "dust", "")
		sfx("dig")
	for r in rooms:
		if not r.active and r.contains(t.cell):
			r.undug = maxi(0, r.undug - 1)
			if r.undug == 0:
				r.activate()
				_recount_capacity()
				log_event("%s finished." % Room.type_name(r.type), Room.icon_name(r.type))
				sfx("chamber_complete")
	return dug

# ------------------------------------------------------------------ v8 fill tool
## Why this tunnel cell can't be filled ("" = ok). Pending fill cells count as already filled.
func fill_error(c: Vector2i) -> String:
	if not SoilGrid.in_bounds(c) or c.y <= Config.SURFACE_ROW:
		return "Only dug tunnel cells can be filled"
	if grid.get_cell(c) != SoilGrid.Cell.TUNNEL:
		return "Only dug tunnel cells can be filled"
	if fill_tasks.has(c):
		return "Already marked for filling"
	var r := room_at(c)
	if r != null:
		if r.type == Room.Type.QUEEN_CHAMBER:
			return "The queen chamber can't be filled"
		if not r.active:
			return "A planned chamber is here - cancel it first"
		if r.is_store() and r.sugar + r.protein > 0.05:
			return "Storage still holds food"
		if r.is_nursery() and (r.brood_count() > 0 or not r.reserved.is_empty()):
			return "Nursery still holds brood"
		if r.type == Room.Type.WASTE and r.waste > 0.05:
			return "Waste chamber is not empty"
	for b in brood:
		if not b.dead and b.carried_by == null and b.cell() == c:
			return "Brood lies here"
	for w in waste_items:
		if w.cell == c:
			return "Refuse lies here"
	for k: Vector3i in dropped.keys():
		if Vector2i(k.x, k.y) == c:
			return "Food lies here"
	if not _connected_without(c):
		return "Would cut the nest off from the surface"
	return ""

## Flood fill from the surface through tunnels, skipping `c` and pending fill cells: every
## other tunnel cell (rooms, ants, brood) must stay reachable.
func _connected_without(c: Vector2i, strict := false) -> bool:
	var W := Config.GRID_W
	var seen := PackedByteArray()
	seen.resize(W * Config.GRID_H)
	var q: Array[Vector2i] = []
	for e in grid.entrances():
		var s := Vector2i(e.x, Config.FIRST_SOIL_ROW)
		if s != c and (strict or not fill_tasks.has(s)):
			seen[s.y * W + s.x] = 1
			q.append(s)
	var n := 0
	var qi := 0
	while qi < q.size():
		var p := q[qi]
		qi += 1
		n += 1
		for d in SoilGrid.N4:
			var o: Vector2i = p + d
			if not SoilGrid.in_bounds(o) or o.y <= Config.SURFACE_ROW or seen[o.y * W + o.x] == 1:
				continue
			if grid.get_cell(o) != SoilGrid.Cell.TUNNEL or o == c or (fill_tasks.has(o) and not strict):
				continue
			seen[o.y * W + o.x] = 1
			q.append(o)
	var total := 0
	for i in grid.walk_idx:
		if i / W > Config.SURFACE_ROW:
			var cc := Vector2i(i % W, i / W)
			if cc != c and (strict or not fill_tasks.has(cc)):
				total += 1
				if seen[i] == 0:
					return false
	return n >= total

func add_fill_order(c: Vector2i) -> bool:
	if fill_error(c) != "":
		return false
	var t := DigTask.new()
	t.cell = c
	fill_tasks[c] = t
	return true

func cancel_fill_order(c: Vector2i) -> bool:
	if not fill_tasks.has(c):
		return false
	var t: DigTask = fill_tasks[c]
	if t.claimed_by != null and is_instance_valid(t.claimed_by):
		(t.claimed_by as Ant).abandon_fill()
	t.claimed_by = null
	fill_tasks.erase(c)
	return true

func claim_fill_task(a: Ant) -> DigTask:
	var best: DigTask = null
	var best_d := 1 << 30
	for t: DigTask in fill_tasks.values():
		if t.claimed_by != null or t.blocked_until > time:
			continue
		var d := absi(t.cell.x - a.cell.x) + absi(t.cell.y - a.cell.y)
		if d < best_d:
			best_d = d
			best = t
	if best != null and fill_tasks.size() > 1 and not _connected_without(best.cell, true):
		best.blocked_until = time + 3.0      # an inner cell: wait until the cells behind it are packed
		return null
	if best != null:
		best.claimed_by = a
	return best

## Open neighbour of a fill cell to stand on (not another pending fill cell).
func fill_access_cell(target: Vector2i, from: Vector2i) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_d := 1 << 30
	for d in SoilGrid.N4:
		var c := target + d
		if grid.is_walkable(c):
			var dd := absi(c.x - from.x) + absi(c.y - from.y) + (40 if fill_tasks.has(c) else 0)
			if dd < best_d:
				best_d = dd
				best = c
	return best

## Nearest entrance column with a soil mound (x), or -1.
func mound_for_fill(from: Vector2i) -> int:
	var best := -1
	var bd := 1 << 30
	for x in mounds.keys():
		if float(mounds[x]) >= 1.0:
			var d := absi(int(x) - from.x)
			if d < bd:
				bd = d
				best = int(x)
	return best

## Take one pellet from the mound at column x (false = mound gone: the ant scrapes topsoil instead).
func take_mound(x: int) -> bool:
	if float(mounds.get(x, 0.0)) >= 1.0:
		mounds[x] = float(mounds[x]) - 1.0
		if float(mounds[x]) < 0.5:
			mounds.erase(x)
		mound_used += 1
		return true
	return false

func ant_on_cell(c: Vector2i, except: Ant) -> bool:
	for a in ants:
		if a != except and a.cell == c and a.state != Ant.State.DEAD:
			return true
	return false

## The fill is done: the cell turns back to soil. Rooms containing it are removed (they were empty).
func complete_fill(t: DigTask) -> bool:
	t.claimed_by = null
	# packing this cell now must not strand another pending fill cell (they are filled leaf-first)
	if not _connected_without(t.cell, true):
		t.blocked_until = time + 4.0
		t.progress = 0.0
		return false
	fill_tasks.erase(t.cell)
	var late := fill_error(t.cell)
	if late != "":
		log_event("Fill cancelled: %s." % late.to_lower(), "alert")
		return false
	if not grid.fill(t.cell):
		return false
	total_filled += 1
	add_fx(grid.cell_center(t.cell), "dust", "")
	sfx("dig")
	var r := room_at(t.cell)
	if r != null:
		rooms.erase(r)
		_recount_capacity()
		log_event("%s filled in - the chamber is gone." % Room.type_name(r.type), Room.icon_name(r.type))
	# anyone routed through the filled cell re-plans
	for a in ants:
		a.on_cell_filled(t.cell)
	return true

## Hauled soil arrives on the surface: the mound beside entrance column `x` grows.
func add_mound(x: int, n: int) -> void:
	mounds[x] = float(mounds.get(x, 0.0)) + float(n)
	soil_hauled += n

func is_entrance_column(x: int) -> bool:
	return grid.get_cell(Vector2i(x, Config.FIRST_SOIL_ROW)) == SoilGrid.Cell.TUNNEL

func is_flooded(c: Vector2i) -> bool:
	if not SoilGrid.in_bounds(c):
		return false
	return flood[c.y * Config.GRID_W + c.x] > Config.FLOOD_WET

func nearest_entrance_x(from: Vector2i) -> int:
	var best := 40
	var bd := 1 << 30
	for e in grid.entrances():
		var d := absi(e.x - from.x) + absi(e.y - from.y)
		if d < bd:
			bd = d
			best = e.x
	return best

# ------------------------------------------------------------------ food
func stock_of(t: int) -> float:
	return sugar_stock if t == Config.Food.SUGAR else protein_stock

func _recount_food() -> void:
	var s := 0.0
	var p := 0.0
	for r in rooms:
		if r.is_store():
			s += r.sugar
			p += r.protein
	sugar_stock = s
	protein_stock = p
	food_stock = s + p

func storage_accepts(t: int) -> bool:
	return food_capacity > 0.0 and stock_of(t) < Config.type_cap(t) * food_capacity - 0.1 \
		and food_stock < food_capacity * 0.97

func storage_full() -> bool:
	return not (storage_accepts(Config.Food.SUGAR) or storage_accepts(Config.Food.PROTEIN))

func deposit_food(amount: float, type: int, near: Vector2i) -> float:
	var allow := maxf(0.0, Config.type_cap(type) * food_capacity - stock_of(type))
	var left := minf(amount, allow)
	var order: Array[Room] = []
	for r in rooms:
		if r.is_store():
			order.append(r)
	order.sort_custom(func(x: Room, y: Room) -> bool:
		return _store_key(x, near) < _store_key(y, near))
	var stored := 0.0
	for r in order:
		var put := minf(left, r.capacity() - r.food())
		if put > 0.0:
			r.add_stock(type, put)
			left -= put
			stored += put
	_recount_food()
	total_foraged += stored
	if stored > 0.0:
		sfx("food_deposit")
	return stored

## Real storage first, the queen chamber's small reserve last.
func _store_key(r: Room, near: Vector2i) -> int:
	return _room_dist(r, near) + (10000 if r.type == Room.Type.QUEEN_CHAMBER else 0)

func return_food(amount: float, type: int, near: Vector2i) -> void:
	var s := deposit_food(amount, type, near)
	total_foraged -= s   # it was only borrowed from the stock

func take_food(amount: float, type: int, near: Vector2i) -> float:
	var left := amount
	var order: Array[Room] = []
	for r in rooms:
		if r.is_store() and r.stock(type) > 0.0:
			order.append(r)
	if near.x >= 0:
		order.sort_custom(func(x: Room, y: Room) -> bool:
			return _room_dist(x, near) < _room_dist(y, near))
	for r in order:
		var got := minf(left, r.stock(type))
		r.add_stock(type, -got)
		left -= got
		if left <= 0.0:
			break
	_recount_food()
	return amount - left

func _room_dist(r: Room, c: Vector2i) -> int:
	if c.x < 0:
		return 0
	var cc := r.rect.get_center()
	return absi(cc.x - c.x) + absi(cc.y - c.y)

func nearest_storage_with_food(from: Vector2i, type: int) -> Vector2i:
	var best: Room = null
	for r in rooms:
		if r.is_store() and r.stock(type) >= Config.NURSE_FEED_COST:
			if best == null or _room_dist(r, from) < _room_dist(best, from):
				best = r
	if best == null:
		return Vector2i(-1, -1)
	return best.random_cell()

func pick_storage_cell(from: Vector2i) -> Vector2i:
	var best: Room = null
	for r in rooms:
		if r.is_store() and r.food() < r.capacity() - 0.1:
			if best == null or _store_key(r, from) < _store_key(best, from):
				best = r
	if best == null:
		return Vector2i(-1, -1)
	return best.random_cell()

func food_near(x: int, type := -1) -> FoodSource:
	for f in foods:
		if f.active and f.amount > 0.0 and absi(f.col - x) <= 1 and (type < 0 or f.type == type):
			return f
	return null

func active_food_count(type := -1) -> int:
	var n := 0
	for f in foods:
		if f.active and (type < 0 or f.type == type):
			n += 1
	return n

## Comfortable stock of one food type. v8: sugar wants more than protein, so foragers keep
## going for sugar while protein is "enough" (the user's day-9 colony had 0 sugar, full protein).
func comfort_of(t := 0) -> float:
	return maxf(Config.FOOD_COMFORT_MIN, Config.FOOD_COMFORT_SHARE[t] * food_capacity)

func urgency_of(t: int) -> float:
	return clampf(1.0 - stock_of(t) / comfort_of(t), 0.0, 1.0)

func food_urgency() -> float:
	return maxf(urgency_of(Config.Food.SUGAR), urgency_of(Config.Food.PROTEIN))

func can_forage() -> bool:
	for t in Config.FOOD_NAMES.size():
		if storage_accepts(t) and active_food_count(t) > 0:
			return true
	return false

## Which food type should the next forager look for? (-1 = none worth looking for)
func pick_seek_type() -> int:
	var w: Array[float] = [0.0, 0.0]
	var total := 0.0
	for t in w.size():
		if storage_accepts(t) and active_food_count(t) > 0:
			w[t] = Config.FOOD_TYPE_WEIGHT[t] * (0.12 + 2.0 * urgency_of(t))
			# v8: the scarce type wins clearly (no protein runs while the colony starves for sugar)
			if urgency_of(1 - t) > 0.6 and urgency_of(t) < 0.3:
				w[t] *= 0.15
			total += w[t]
	if total <= 0.0:
		return -1
	var r := randf() * total
	for t in w.size():
		r -= w[t]
		if r <= 0.0:
			return t
	return w.size() - 1

func pick_entrance(from: Vector2i, type := -1) -> Vector2i:
	var entr := grid.entrances()
	if entr.is_empty():
		return Vector2i(-1, -1)
	var weights: Array[float] = []
	var total := 0.0
	for e in entr:
		var p := 0.0
		if type >= 0:
			for dx in range(-3, 4):
				p += trails[type].get_at(e + Vector2i(dx, 0))
		var w := (0.2 + p) / (1.0 + 0.03 * absi(e.x - from.x) + 0.03 * absi(e.y - from.y))
		weights.append(w)
		total += w
	var r := randf() * total
	for i in entr.size():
		r -= weights[i]
		if r <= 0.0:
			return entr[i]
	return entr[entr.size() - 1]

func random_nest_cell(near: Vector2i, radius: int) -> Vector2i:
	for i in 12:
		var c := near + Vector2i(randi_range(-radius, radius), randi_range(-radius, radius))
		if c.y > Config.SURFACE_ROW and grid.is_walkable(c):
			return c
	return near

# food lying on the floor (a forager found the storage full)
func drop_food(c: Vector2i, amount: float, type: int) -> void:
	var k := Vector3i(c.x, c.y, type)
	dropped[k] = float(dropped.get(k, 0.0)) + amount
	food_dropped_total += amount

func claim_dropped(from: Vector2i) -> Vector3i:
	var best := Vector3i(-1, -1, -1)
	var bd := 1 << 30
	for k: Vector3i in dropped.keys():
		if not storage_accepts(k.z):
			continue
		var d := absi(k.x - from.x) + absi(k.y - from.y)
		if d < bd:
			bd = d
			best = k
	return best

func take_dropped(k: Vector3i) -> float:
	var amt := minf(Config.CARRY_AMOUNT, float(dropped.get(k, 0.0)))
	if amt <= 0.0:
		return 0.0
	var left := float(dropped[k]) - amt
	if left <= 0.05:
		dropped.erase(k)
	else:
		dropped[k] = left
	return amt

# ------------------------------------------------------------------ waste
func add_waste(c: Vector2i, kind: int) -> void:
	var w := WasteItem.new()
	w.cell = c
	w.kind = kind
	w.units = Config.CORPSE_UNITS if kind == WasteItem.Kind.CORPSE else 1.0
	waste_items.append(w)

func _step_waste(dt: float) -> void:
	for r in rooms:
		if r.type == Room.Type.WASTE and r.active and r.waste > 0.0:
			r.waste = maxf(0.0, r.waste - Config.WASTE_DECAY * dt)      # composts away slowly
	_waste_t -= dt
	if _waste_t > 0.0:
		return
	var workers := maxi(1, ants.size() - soldier_count())
	_waste_t = Config.REFUSE_BASE_INTERVAL / maxf(1.0, workers / 10.0) * randf_range(0.7, 1.3)
	var spots: Array[Room] = []
	for r in rooms:
		if r.active and (r.type == Room.Type.NURSERY or r.type == Room.Type.FOOD_STORAGE):
			spots.append(r)
	if spots.is_empty():
		return
	add_waste(spots[randi() % spots.size()].random_cell(), WasteItem.Kind.REFUSE)

func claim_waste(a: Ant) -> WasteItem:
	var best: WasteItem = null
	var bd := 1 << 30
	for w in waste_items:
		if w.claimed_by != null:
			continue
		var d := absi(w.cell.x - a.cell.x) + absi(w.cell.y - a.cell.y)
		if d < bd:
			bd = d
			best = w
	if best != null:
		best.claimed_by = a
	return best

func pick_waste_room(from: Vector2i, units: float) -> Room:
	var best: Room = null
	for r in rooms:
		if r.type == Room.Type.WASTE and r.active and r.waste + units <= r.capacity() + 0.01:
			if best == null or _room_dist(r, from) < _room_dist(best, from):
				best = r
	return best

func take_waste_item(w: WasteItem) -> void:
	waste_items.erase(w)

func deliver_waste(w: WasteItem, r: Room) -> void:
	r.waste += w.units
	waste_disposed += 1

func dump_waste(w: WasteItem, entrance_x: int) -> void:
	middens[entrance_x] = float(middens.get(entrance_x, 0.0)) + w.units
	waste_disposed += 1

func return_waste(w: WasteItem, at: Vector2i) -> void:
	w.cell = at
	w.claimed_by = null
	waste_items.append(w)

# ------------------------------------------------------------------ soldiers & threats
func soldier_count() -> int:
	var n := 0
	for a in ants:
		if a.caste == Ant.Caste.SOLDIER:
			n += 1
	return n

func soldier_target() -> int:
	var soldiers := soldier_count()
	var workers := ants.size() - soldiers
	match soldier_mode:
		SoldierMode.OFF:
			return 0
		SoldierMode.MAX:
			return clampi(ceili(0.25 * workers), 0, Config.SOLDIER_MAX)
	var t := 0
	if time - last_threat_t < 300.0:
		t = 3 + mini(threat_count, 4)
	# v5: "plentiful" = both stocks comfortable (the old test, 70 % of the whole storage, was almost never true
	# because one type may only fill 70 % of the storage and foragers slow down once comfortable)
	var plentiful := sugar_stock >= 0.72 * comfort_of(0) and protein_stock >= 0.8 * comfort_of(1) and workers >= 12
	if plentiful:
		t = maxi(t, 1 + workers / 12)
	return clampi(t, 0, Config.SOLDIER_MAX)

func gyne_count() -> int:
	var n := 0
	for a in ants:
		if a.caste == Ant.Caste.GYNE:
			n += 1
	return n

func brood_of_caste(c: int) -> int:
	var n := 0
	for b in brood:
		if b.caste == c:
			n += 1
	return n

## v8: what the next egg becomes. Auto = old soldier rule + an occasional gyne in a big, fed colony.
func pick_egg_caste() -> int:
	var soldier_ok := soldier_count() + brood_of_caste(Brood.Caste.SOLDIER) < Config.SOLDIER_MAX
	var gyne_ok := gyne_count() + brood_of_caste(Brood.Caste.GYNE) < Config.GYNE_MAX
	if caste_manual:
		var w: Array[float] = [float(caste_w[0]), float(caste_w[1]) if soldier_ok else 0.0, float(caste_w[2]) if gyne_ok else 0.0]
		var tot := w[0] + w[1] + w[2]
		if tot <= 0.0:
			return Brood.Caste.WORKER
		var r := randf() * tot
		for i in 3:
			r -= w[i]
			if r <= 0.0:
				return i
		return Brood.Caste.WORKER
	if want_soldier_egg():
		return Brood.Caste.SOLDIER
	if gyne_ok and worker_count() >= Config.GYNE_AUTO_WORKERS and gyne_count() + brood_of_caste(Brood.Caste.GYNE) < Config.GYNE_GOAL \
			and sugar_stock >= 0.72 * comfort_of(0) and protein_stock >= 0.8 * comfort_of(1) and randf() < 0.15:
		return Brood.Caste.GYNE
	return Brood.Caste.WORKER

func can_fly() -> bool:
	return gyne_count() >= Config.GYNE_GOAL

## The gynes leave for their mating flight: the colony's long-term goal (score milestone).
func start_nuptial_flight() -> bool:
	if not can_fly():
		return false
	var n := 0
	for a in ants.duplicate():
		if a.caste == Ant.Caste.GYNE:
			add_fx(a.position, "pop", "")
			ants.erase(a)
			a.state = Ant.State.DEAD
			a.queue_free()
			n += 1
	flights += 1
	gynes_flown += n
	score += n * 100 + worker_count() * 2
	log_event("NUPTIAL FLIGHT! %d young queens flew off to found new colonies." % n, "queen_chamber")
	sfx("chamber_complete")
	nuptial_flight.emit({"day": day(), "flights": flights, "gynes": n, "gynes_total": gynes_flown, "workers": worker_count(),
		"soldiers": soldier_count(), "born": total_born, "foraged": total_foraged, "dug": total_dug, "score": score})
	return true

# ------------------------------------------------------------------ v8 workforce
func prio_mult(job: int) -> float:
	return Config.PRIO_MULT[clampi(int(work_prio[job]), 0, 4)]

## Wanted number of workers per job (Forage, Nurse, Dig, Clean) for the HUD.
func job_targets() -> Array[int]:
	var n := worker_count()
	var base: Array[float] = [0.40 + 0.3 * food_urgency(), 0.30 if brood.size() > 0 else 0.08,
		0.18 if not dig_tasks.is_empty() or not fill_tasks.is_empty() else 0.0, 0.12 if need_clean > 0 or hygiene < 0.95 else 0.04]
	var w: Array[float] = []
	var tot := 0.0
	for i in 4:
		w.append(base[i] * prio_mult(i))
		tot += w[i]
	var res: Array[int] = []
	for i in 4:
		res.append(roundi(n * w[i] / tot) if tot > 0.0 else 0)
	return res

func job_actual() -> Array[int]:
	_refresh_task_counts()
	return [task_counts[Ant.Task.FORAGE], task_counts[Ant.Task.NURSE], task_counts[Ant.Task.DIG], task_counts[Ant.Task.CLEAN]]

## Age polyethism: how good this ant is at its current job (AGE_EFF_MIN..1).
func age_efficiency(a: Ant) -> float:
	if a.is_queen or a.caste != Ant.Caste.WORKER:
		return 1.0
	var pref: Array = []
	match a.task:
		Ant.Task.NURSE: pref = Config.PREF_NURSE
		Ant.Task.FORAGE: pref = Config.PREF_FORAGE
		Ant.Task.DIG: pref = Config.PREF_DIG
		Ant.Task.CLEAN: pref = Config.PREF_CLEAN
		_: return 1.0
	var f := clampf(a.age / a.lifespan, 0.0, 1.0)
	return Config.AGE_EFF_MIN + (1.0 - Config.AGE_EFF_MIN) * clampf(curve(pref, f), 0.0, 1.0)

# ------------------------------------------------------------------ v8 threat orders
func threat_active() -> bool:
	return not threats.is_empty() or alarm_active()

func current_order() -> int:
	return active_order if active_order >= 0 else standing_order

func sealed() -> bool:
	return threat_active() and current_order() == 1

func evacuating() -> bool:
	return threat_active() and current_order() == 2

func fighting() -> bool:
	return threat_active() and current_order() == 0

func set_alarm_order(o: int) -> void:
	active_order = o
	log_event("Alarm response: %s." % Config.ORDER_NAMES[o], "alert")
	_refresh_needs()

func _step_orders(dt: float) -> void:
	if threat_active():
		_calm_t = 0.0
	else:
		_calm_t += dt
		if active_order >= 0 and _calm_t > 10.0:
			active_order = -1
			log_event("All clear - back to the standing order (%s)." % Config.ORDER_NAMES[standing_order], "alert")

func want_soldier_egg() -> bool:
	var coming := 0
	for b in brood:
		if b.caste == Brood.Caste.SOLDIER:
			coming += 1
	return soldier_count() + coming < soldier_target()

func reset_threat_timer() -> void:
	var lvl := Config.threat_level
	_threat_t = Config.THREAT_FIRST[lvl] * randf_range(0.8, 1.25)

func _step_threat_spawn(dt: float) -> void:
	var lvl := Config.threat_level
	if lvl <= 0:
		return
	_threat_t -= dt
	if _threat_t > 0.0:
		return
	var iv: Array = Config.THREAT_INTERVAL[lvl]
	_threat_t = randf_range(iv[0], iv[1])
	if threats.size() >= lvl:
		return
	spawn_threat(Threat.Kind.SPIDER if randf() < 0.65 else Threat.Kind.RIVAL)

func spawn_threat(kind: int) -> Threat:
	var th := Threat.new()
	ant_container.add_child(th)
	var left := randf() < 0.5
	th.setup(self, kind, 30.0 if left else Config.GRID_W * Config.CELL - 30.0, Config.THREAT_LIFE[maxi(1, Config.threat_level)])
	threats.append(th)
	if kind == Threat.Kind.RIVAL and randf() < Config.RAID_CHANCE[clampi(Config.threat_level, 0, 2)]:
		th.raider = true
	last_threat_t = time
	threat_count += 1
	log_event("WARNING: a %s appeared on the %s side of the surface!" % [Threat.NAMES[kind], "left" if left else "right"], "threat_spider")
	sfx("threat_warning")
	return th

# ------------------------------------------------------------------ raids (v5)
func nearest_entrance_px(x_px: float) -> int:
	var best := -1
	var bd := INF
	for e in grid.entrances():
		var d := absf((e.x + 0.5) * Config.CELL - x_px)
		if d < bd:
			bd = d
			best = e.x
	return best

## Entrance with the most food-trail traffic around it (where a predator would wait).
func busiest_entrance_x() -> int:
	var best := -1
	var bv := -1.0
	for e in grid.entrances():
		var v := home.get_at(e) + trails[0].get_at(e) + trails[1].get_at(e)
		if v > bv:
			bv = v
			best = e.x
	return best

## A cell inside a storage room with food, or a nursery cell holding brood. {} if none.
func raid_target(prefer_food: bool) -> Dictionary:
	var food_cell := Vector2i(-1, -1)
	var brood_cell := Vector2i(-1, -1)
	for r in rooms:
		if not r.active:
			continue
		if r.type == Room.Type.FOOD_STORAGE and r.food() >= 1.0 and food_cell.x < 0:
			food_cell = r.random_cell()
		elif r.type == Room.Type.NURSERY and r.brood_count() > 0 and brood_cell.x < 0:
			for i in r.slots.size():
				if r.slots[i] != null:
					brood_cell = r.slot_cell(i)
					break
	if prefer_food and food_cell.x >= 0 or brood_cell.x < 0 and food_cell.x >= 0:
		return {"kind": "food", "cell": food_cell}
	if brood_cell.x >= 0:
		return {"kind": "brood", "cell": brood_cell}
	return {}

func steal_food(at: Vector2i, amount: float) -> Array:
	var r := room_at(at)
	if r == null or r.type != Room.Type.FOOD_STORAGE:
		r = null
		for o in rooms:
			if o.is_store() and o.food() > 0.0:
				r = o
				break
	if r == null:
		return [0.0, 0]
	var t := Config.Food.SUGAR if r.sugar >= r.protein else Config.Food.PROTEIN
	var got := minf(amount, r.stock(t))
	r.add_stock(t, -got)
	_recount_food()
	food_stolen += got
	return [got, t]

func steal_brood(at: Vector2i) -> Dictionary:
	var best: Brood = null
	var bd := 1 << 30
	for b in brood:
		if b.in_transit or b.carried_by != null:
			continue
		var d := absi(b.cell().x - at.x) + absi(b.cell().y - at.y)
		if d < bd:
			bd = d
			best = b
	if best == null or bd > 3:
		return {}
	var info := {"stage": best.stage, "caste": best.caste, "t": best.t, "fed": best.fed}
	_remove_brood(best, false)
	return info

## An intruder carrying brood was killed: the brood lies loose where it fell, nurses will fetch it.
func rescue_brood(info: Dictionary, at: Vector2i) -> void:
	var b := Brood.new()
	b.uid = next_uid
	next_uid += 1
	b.stage = int(info.get("stage", 0))
	b.caste = int(info.get("caste", 0))
	b.t = float(info.get("t", 0.0))
	b.fed = float(info.get("fed", 0.5))
	b.loose_cell = at
	brood.append(b)

func remove_threat(th: Threat) -> void:
	if th in threats:
		threats.erase(th)
		if th.hp <= 0.0:
			threats_killed += 1
		th.queue_free()

## Nearest intruder inside the nest (Euclidean, px), or null.
func nearest_intruder(p: Vector2, max_px: float) -> Threat:
	var best: Threat = null
	var bd := max_px
	for th in threats:
		if not th.inside:
			continue
		var d := th.position.distance_to(p)
		if d < bd:
			bd = d
			best = th
	return best

func intruder_count() -> int:
	var n := 0
	for th in threats:
		if th.inside:
			n += 1
	return n

func defenders_of(th: Threat) -> int:
	var n := 0
	for a in ants:
		if a.fight_target == th:
			n += 1
	return n

## Surface threats only (intruders inside the nest are handled by nearest_intruder).
func nearest_threat(x_px: float, max_px: float) -> Threat:
	var best: Threat = null
	var bd := max_px
	for th in threats:
		if th.inside:
			continue
		var d := absf(th.position.x - x_px)
		if d < bd:
			bd = d
			best = th
	return best

func note_threat_seen(th: Threat) -> void:
	last_threat_t = time

func alarm_active() -> bool:
	return alarm.peak > Config.ALARM_ACTIVE

# ------------------------------------------------------------------ rain & flooding (v5)
func _step_rain(dt: float) -> void:
	if raining:
		rain_left -= dt
		Climate.wet = minf(1.0, Climate.wet + dt * 0.05 * rain_intensity)
		if rain_left <= 0.0 or not Config.rain_enabled:
			raining = false
			log_event("The rain stops; the water drains away.", "climate")
	else:
		Climate.wet = maxf(0.0, Climate.wet - dt * Config.RAIN_WET_DECAY)
		if Config.rain_enabled:
			_rain_t -= dt
			if _rain_t <= 0.0:
				start_rain(randf_range(0.5, 1.0))
	_rain_tick -= dt
	if _rain_tick <= 0.0:
		_rain_tick = 0.5
		_update_flood(0.5)

func start_rain(intensity: float, duration := -1.0) -> void:
	raining = true
	rain_intensity = clampf(intensity, 0.05, 1.0)
	rain_left = duration if duration > 0.0 else randf_range(Config.RAIN_DURATION[0], Config.RAIN_DURATION[1])
	rain_count += 1
	_rain_t = randf_range(Config.RAIN_INTERVAL[0], Config.RAIN_INTERVAL[1]) + rain_left
	log_event("It starts to rain%s - shallow tunnels may flood." % (" heavily" if rain_intensity > 0.8 else ""), "climate")

func reset_rain_timer() -> void:
	_rain_t = Config.RAIN_FIRST * randf_range(0.8, 1.2)

@warning_ignore("integer_division")
func _update_flood(h: float) -> void:
	var n := 0
	var any_water := false
	for i in grid.walk_idx:
		var y := i / Config.GRID_W
		if y <= Config.SURFACE_ROW:
			continue
		var d := y - Config.FIRST_SOIL_ROW
		var target := 0.0
		if raining and d < Config.FLOOD_ROWS:
			target = clampf(rain_intensity * (1.15 - float(d) / Config.FLOOD_ROWS), 0.0, 1.0)
		var v := flood[i]
		if v < target:
			v = minf(target, v + Config.FLOOD_RATE * rain_intensity * h)
		elif v > target:
			v = maxf(target, v - Config.FLOOD_DRAIN * h)
		flood[i] = v
		if v > 0.0:
			any_water = true
		if v > Config.FLOOD_WET:
			n += 1
		flood_peak = maxf(flood_peak, v)
	flooded_cells = n
	if any_water or n > 0 or raining:
		_apply_flood_quality()

## Flooded rooms count as the worst possible brood chamber, so nurses carry the brood out.
func _apply_flood_quality() -> void:
	for r in rooms:
		var wet := false
		if r.active:
			for y in range(r.rect.position.y, r.rect.end.y):
				for x in range(r.rect.position.x, r.rect.end.x):
					if flood[y * Config.GRID_W + x] > Config.FLOOD_WET:
						wet = true
		r.flooded = wet
		r.quality = 0.0 if wet else Climate.mean_quality(r.rect.get_center().y)

## A* prefers tunnels with a strong home trail (emergent highways) and avoids flooded cells.
@warning_ignore("integer_division")
func _refresh_path_weights() -> void:
	for i in grid.walk_idx:
		var y := i / Config.GRID_W
		if y <= Config.SURFACE_ROW:
			continue
		var w := maxf(Config.HOME_WEIGHT_MIN, 1.0 / (1.0 + Config.HOME_WEIGHT_K * home.a[i]))
		if flood[i] > Config.FLOOD_WET:
			w *= 2.0
		grid.astar.set_point_weight_scale(Vector2i(i % Config.GRID_W, y), w)

# ------------------------------------------------------------------ microclimate
func _refresh_climate() -> void:
	for y in Config.GRID_H:
		row_rate[y] = Climate.rate(Climate.quality_at(y, time))

# ------------------------------------------------------------------ polyethism / utility AI
static func curve(table: Array, x: float) -> float:
	if x <= table[0][0]:
		return table[0][1]
	for i in range(1, table.size()):
		if x <= table[i][0]:
			var x0: float = table[i - 1][0]
			var x1: float = table[i][0]
			var y0: float = table[i - 1][1]
			var y1: float = table[i][1]
			return lerpf(y0, y1, (x - x0) / maxf(x1 - x0, 0.0001))
	return table[table.size() - 1][1]

func worker_count() -> int:
	return ants.size() - soldier_count() - gyne_count()

func score_tasks(a: Ant) -> Array[float]:
	var f := clampf(a.age / a.lifespan, 0.0, 1.0)
	var urg := food_urgency()
	var n := maxi(1, worker_count())
	# nurse: feed hungry larvae (needs protein) + carry brood
	var s_nurse := 0.0
	if nursery_capacity > 0:
		var feed_ok := 1.0 if protein_stock >= Config.NURSE_FEED_COST else 0.25
		var need := clampf(need_hungry / 2.0, 0.0, 1.0) * feed_ok + clampf(need_move / 2.0, 0.0, 1.0)
		s_nurse = curve(Config.PREF_NURSE, f) * (0.15 + clampf(need, 0.0, 1.0))
	# dig (player orders should never starve: any claimable order gives a base score, more orders more)
	var s_dig := 0.0
	var dig_avail := need_dig + (1 if a.task == Ant.Task.DIG else 0)
	if dig_avail > 0:
		s_dig = curve(Config.PREF_DIG, f) * (0.5 + clampf(dig_pending / 6.0, 0.0, 1.0))
	# forage: wanted share of foragers grows with food urgency, any age may be drafted
	var pf := maxf(curve(Config.PREF_FORAGE, f), urg * 0.9)
	var s_for := pf * (0.35 + 0.9 * urg)
	var want_share := Config.FORAGER_SHARE_BASE + Config.FORAGER_SHARE_HUNGRY * urg
	if float(task_counts[Ant.Task.FORAGE]) >= want_share * n + 1.0 and a.task != Ant.Task.FORAGE:
		s_for *= 0.3
	if not can_forage():
		s_for *= 0.05
	if alarm_active():
		s_for *= 0.5     # nobody wants to go out while the alarm is up
	# clean: refuse and corpses, a job for the middle-aged and old
	var s_clean := 0.0
	var clean_avail := need_clean + (1 if a.task == Ant.Task.CLEAN else 0)
	if clean_avail > 0:
		s_clean = curve(Config.PREF_CLEAN, f) * (0.3 + clampf(clean_avail / 3.0, 0.0, 1.0) + (1.0 - hygiene))
	# v8 player priorities (Forage, Nurse, Dig, Clean); level 0 = only in an emergency
	s_for *= maxf(prio_mult(0), 0.05 if urg > 0.8 else 0.0)
	s_nurse *= maxf(prio_mult(1), 0.0)
	s_dig *= maxf(prio_mult(2), 0.0)
	s_clean *= maxf(prio_mult(3), 0.05 if hygiene < Config.HYGIENE_BAD else 0.0)
	if sealed():
		s_for *= 0.02        # entrances sealed: nobody goes out
	var scores: Array[float] = [0.10, s_nurse, s_dig, s_for, s_clean]
	if a.task < scores.size():
		scores[a.task] *= Config.TASK_HYSTERESIS
	for i in scores.size():
		scores[i] += randf() * 0.06
	return scores

func choose_task(a: Ant) -> int:
	var sc := score_tasks(a)
	var best := 0
	for i in sc.size():
		if sc[i] > sc[best]:
			best = i
	return best

func reassign(a: Ant) -> void:
	if a.caste != Ant.Caste.WORKER:
		return
	_refresh_task_counts()
	var t := choose_task(a)
	if t != a.task:
		# reserve the need so a burst of re-evaluations doesn't over-recruit
		if t == Ant.Task.DIG:
			need_dig = maxi(0, need_dig - 1)
		elif t == Ant.Task.NURSE:
			need_hungry = maxi(0, need_hungry - 1)
		elif t == Ant.Task.CLEAN:
			need_clean = maxi(0, need_clean - 1)
	a.set_task(t)

func _refresh_task_counts() -> void:
	task_counts = [0, 0, 0, 0, 0, 0]
	for a in ants:
		task_counts[a.task] += 1

func refresh_now() -> void:
	_refresh_needs()
	_refresh_task_counts()

func _refresh_needs() -> void:
	_refresh_path_weights()
	need_hungry = 0
	need_move = loose_brood_count()
	if _find_relocation() != null:
		need_move += 1
	brood_counts = [0, 0, 0]
	soldier_brood = 0
	for b in brood:
		brood_counts[b.stage] += 1
		if b.caste == Brood.Caste.SOLDIER:
			soldier_brood += 1
		if b.stage == Brood.Stage.LARVA and b.room != null and not b.in_transit and b.claimed_by == null \
				and b.carried_by == null and b.fed < Config.FEED_THRESHOLD:
			need_hungry += 1
	need_dig = 0
	dig_pending = 0
	for t: DigTask in dig_tasks.values():
		if t.claimed_by == null and t.blocked_until <= time:
			dig_pending += 1
			if is_claimable(t):
				need_dig += 1
	for t: DigTask in fill_tasks.values():
		if t.claimed_by == null and t.blocked_until <= time:
			need_dig += 1
	need_clean = 0
	for w in waste_items:
		if w.claimed_by == null:
			need_clean += 1
	var workers := maxi(1, worker_count())
	# items somebody is already fetching count half as much as items nobody has noticed
	var unattended := need_clean + 0.5 * float(waste_items.size() - need_clean)
	hygiene = clampf(1.0 - unattended / (Config.HYGIENE_BASE + Config.HYGIENE_PER_WORKER * workers), 0.0, 1.0)
	if hygiene < Config.HYGIENE_BAD and not _hygiene_warned:
		_hygiene_warned = true
		log_event("Waste is piling up - the brood is at risk! Build a waste chamber / more cleaners.", "clean")
	elif hygiene > 0.8:
		_hygiene_warned = false
	if sugar_stock <= 0.01 and not _starve_warned:
		_starve_warned = true
		log_event("The colony is out of sugar - workers are starving!", "food")
	elif sugar_stock > 2.0:
		_starve_warned = false
	_refresh_task_counts()

# ------------------------------------------------------------------ events, log, effects
func on_ant_died(a: Ant, reason: String) -> void:
	ants.erase(a)
	total_deaths += 1
	death_reasons[reason] = int(death_reasons.get(reason, 0)) + 1
	if a.cell.y > Config.SURFACE_ROW:
		add_waste(a.cell, WasteItem.Kind.CORPSE)
	add_fx(a.position, "skull" if reason.begins_with("killed") else "puff", "")
	if reason.begins_with("killed"):
		sfx("alarm")

func day() -> int:
	return int(time / Config.DAY_LENGTH) + 1

## Plays a one-shot through the optional audio manager (silent when none is attached).
func sfx(n: String, extra_db := 0.0) -> void:
	if audio != null:
		audio.play(n, extra_db)

## icon: optional name of an icon in assets/icons/. It is stored as an "@icon " prefix that the HUD
## strips and turns into an inline image (older saves simply have no prefix).
func log_event(msg: String, icon := "") -> void:
	var t := int(time)
	events.append("%s[%d:%02d] %s" % ["@%s " % icon if icon != "" else "", t / 60, t % 60, msg])
	if events.size() > 60:
		events.pop_front()

func add_fx(p: Vector2, kind: String, text: String) -> void:
	if fx.size() > 80:
		return
	var life := 0.9
	match kind:
		"dust": life = 0.7
		"heart": life = 1.2
		"skull": life = 1.6
		"text": life = 1.4
	fx.append({"p": p, "kind": kind, "t": 0.0, "life": life, "text": text})

func _step_fx(dt: float) -> void:
	var i := fx.size() - 1
	while i >= 0:
		fx[i]["t"] += dt
		if fx[i]["t"] >= fx[i]["life"]:
			fx.remove_at(i)
		i -= 1

# ------------------------------------------------------------------ save / load support
## Remove everything that SaveGame.apply() is about to rebuild.
func clear_world() -> void:
	for a in ants:
		a.state = Ant.State.DEAD
		a.queue_free()
	ants.clear()
	if queen != null:
		queen.state = Ant.State.DEAD
		queen.queue_free()
		queen = null
	for th in threats:
		th.queue_free()
	threats.clear()
	for f in foods:
		f.queue_free()
	foods.clear()
	brood.clear()
	rooms.clear()
	queen_room = null
	dig_tasks.clear()
	waste_items.clear()
	dropped.clear()
	mounds.clear()
	middens.clear()
	fx.clear()
	for t in trails:
		t.clear()
	alarm.clear()
	home.clear()
	flood.fill(0.0)
	raining = false
	rain_intensity = 0.0
	rain_left = 0.0
	Climate.wet = 0.0

func after_load() -> void:
	home.reset_step()
	_apply_flood_quality()
	for t in trails:
		t.reset_step()
	alarm.reset_step()
	_recount_capacity()
	_recount_food()
	_refresh_climate()
	_refresh_needs()
	reset_threat_timer()
	log_event("Game loaded.", "load")

# ------------------------------------------------------------------ picking helpers (UI)
func ant_at(p: Vector2, radius := 11.0) -> Ant:
	var best: Ant = null
	var best_d := radius
	var all: Array[Ant] = ants.duplicate()
	all.append(queen)
	for a in all:
		var d := a.position.distance_to(p)
		if d < best_d:
			best_d = d
			best = a
	return best

func brood_at(c: Vector2i) -> Brood:
	for b in brood:
		if not b.in_transit and b.cell() == c:
			return b
	return null
