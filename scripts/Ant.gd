class_name Ant
extends Node2D
## One ant (worker, soldier or queen). No physics: ants walk cell-to-cell along A* paths inside
## tunnels / on the surface row. Behaviour = small state machine + a task chosen by the
## colony's utility scoring (see Colony.choose_task). Soldiers ignore the task chooser: they
## patrol the entrances and answer the alarm pheromone.

enum Task { IDLE, NURSE, DIG, FORAGE, CLEAN, GUARD }
enum State { WAIT, MOVE, SEARCH, DIGGING, FEEDING, DEAD, HIDE, FIGHT }
enum Purpose { NONE, WANDER, TO_ENTRANCE, DEPOSIT, PICKUP_FOOD, TO_LARVA, TO_DIG, PICKUP_BROOD, CARRY_BROOD,
	PICKUP_WASTE, DROP_WASTE, DUMP_WASTE, DROP_FOOD, PICKUP_DROPPED, HIDE, PATROL, RESPOND, HAUL_SOIL, RESPOND_IN }
enum Caste { WORKER, SOLDIER }

const TASK_NAMES := ["Idle", "Nurse", "Dig", "Forage", "Clean", "Guard"]
const STATE_NAMES := ["waiting", "walking", "searching surface", "digging", "feeding larva", "dead", "hiding", "fighting"]
const COL_DIG_BAR := Color(1.0, 0.8, 0.2)

var colony: Colony
var grid: SoilGrid
var is_queen := false
var caste: int = Caste.WORKER
var age := 0.0
var lifespan := 600.0
var hp := Config.SOLDIER_HP
var task: int = Task.IDLE
var state: int = State.WAIT
var purpose: int = Purpose.NONE
var cell := Vector2i.ZERO
var prev_cell := Vector2i(-1, -1)
var path: Array[Vector2i] = []
var path_i := 0
var wait_timer := 0.0
var eval_timer := 0.0
var state_time := 0.0
var carry_food := 0.0          # forager load
var carry_type: int = Config.Food.SUGAR
var carry_nurse := 0.0         # protein a nurse carries to a larva
var hold_timer := 0.0
var trail_richness := 0.5
var seek_type: int = Config.Food.SUGAR
var hunger := 0.0
var heading := 1
var jitter := Vector2.ZERO
var dig_task: DigTask = null
var target_brood: Brood = null  # larva we are going to feed
var move_brood: Brood = null    # brood we are carrying / going to carry
var carrying_brood := false
var waste_item: WasteItem = null
var carrying_waste := false
var drop_key := Vector3i(-1, -1, -1)
var dig_t := 0.0
var hide_t := 0.0
var fear_t := 0.0
var attack_t := 0.0
var face := 0.0
var anim := 0.0
var phase0 := 0.0
var selected := false
var search_t := 0.0
# v5
var out_t := 0.0                # seconds since this ant set out from the nest (home trail strength)
var homing := false             # walking home along the home trail with food (surface)
var home_t := 0.0
var home_dst := Vector2i(-1, -1)
var soil := 0                   # soil pellets carried to the surface mound
var haul_x := -1
var fight_target: Threat = null # intruder inside the nest we are fighting

func setup(col: Colony, start_cell: Vector2i, caste_ := 0, queen := false) -> void:
	colony = col
	grid = col.grid
	is_queen = queen
	caste = caste_
	cell = start_cell
	jitter = Vector2(randf_range(-3.0, 3.0), randf_range(-2.0, 2.0)) if not queen else Vector2.ZERO
	position = grid.stand_pos(cell) + jitter
	face = randf() * TAU
	phase0 = randf() * TAU
	eval_timer = randf_range(Config.TASK_EVAL_MIN, Config.TASK_EVAL_MAX)
	wait_timer = randf_range(0.0, 1.5)
	if caste == Caste.SOLDIER:
		lifespan = Config.SOLDIER_LIFESPAN * randf_range(0.85, 1.15)
		task = Task.GUARD
	elif not queen:
		lifespan = maxf(200.0, Config.LIFESPAN_MEAN + randf_range(-1.0, 1.0) * Config.LIFESPAN_VARIANCE)
		hp = Config.WORKER_HP
	z_index = 5 if not queen else 4

# ------------------------------------------------------------------ main step
func step(dt: float) -> void:
	if state == State.DEAD:
		return
	age += dt
	out_t += dt
	state_time += dt
	anim += dt
	if colony.sugar_stock <= 0.01:
		hunger = minf(1.0, hunger + dt / Config.STARVE_TIME)
	else:
		hunger = maxf(0.0, hunger - dt * Config.HUNGER_RECOVER)
	if not is_queen:
		if hunger >= 1.0:
			die("starved")
			return
		if age >= lifespan:
			die("old age")
			return
		if cell.y == Config.SURFACE_ROW and caste == Caste.WORKER and randf() < Config.SURFACE_DEATH_RATE * dt:
			die("killed on the surface")
			return
		fear_t -= dt
		if fear_t <= 0.0:
			fear_t = 0.4
			_check_threats()
		if caste == Caste.WORKER:
			eval_timer -= dt
			if eval_timer <= 0.0:
				eval_timer = randf_range(Config.TASK_EVAL_MIN, Config.TASK_EVAL_MAX)
				if can_reassign():
					colony.reassign(self)
			if carry_nurse > 0.0 and state == State.WAIT and target_brood == null:
				hold_timer += dt
				if hold_timer > 8.0:
					colony.return_food(carry_nurse, Config.Food.PROTEIN, cell)
					carry_nurse = 0.0
					hold_timer = 0.0
	match state:
		State.WAIT:
			wait_timer -= dt
			if wait_timer <= 0.0:
				_decide()
		State.MOVE:
			if _follow(dt):
				_on_arrive()
		State.SEARCH:
			_step_search(dt)
		State.DIGGING:
			_step_digging(dt)
		State.FEEDING:
			wait_timer -= dt
			if wait_timer <= 0.0:
				_finish_feeding()
		State.HIDE:
			hide_t -= dt
			if hide_t <= 0.0:
				state = State.WAIT
				wait_timer = randf_range(0.0, 2.0)
		State.FIGHT:
			_step_fight(dt)
	queue_redraw()

func can_reassign() -> bool:
	if is_queen or caste != Caste.WORKER:
		return false
	if carry_food > 0.0 or carry_nurse > 0.0 or carrying_brood or carrying_waste or soil > 0:
		return false
	return state == State.WAIT or state == State.SEARCH \
		or (state == State.MOVE and purpose in [Purpose.WANDER, Purpose.TO_ENTRANCE])

func set_task(t: int) -> void:
	if t == task:
		return
	task = t
	_release_claims()
	path.clear()
	path_i = 0
	purpose = Purpose.NONE
	state_time = 0.0
	if cell.y == Config.SURFACE_ROW and t != Task.FORAGE:
		# leave the surface: walk back into the nest
		var e := colony.pick_entrance(cell)
		if e.x >= 0:
			var inside := Vector2i(e.x, Config.FIRST_SOIL_ROW + 2)
			if not grid.is_walkable(inside):
				inside = Vector2i(e.x, Config.FIRST_SOIL_ROW)
			if _go_to(inside, Purpose.WANDER):
				return
	state = State.WAIT
	wait_timer = randf_range(0.0, 0.6)

func _release_claims() -> void:
	if dig_task != null:
		if dig_task.claimed_by == self:
			dig_task.claimed_by = null
			dig_task.progress = 0.0
		dig_task = null
	if target_brood != null:
		if target_brood.claimed_by == self:
			target_brood.claimed_by = null
		target_brood = null
	if move_brood != null:
		if not move_brood.dead and move_brood.carried_by == self:
			colony.release_brood(move_brood, cell)
		move_brood = null
		carrying_brood = false
	if waste_item != null:
		if carrying_waste:
			colony.return_waste(waste_item, cell)
		elif waste_item.claimed_by == self:
			waste_item.claimed_by = null
		waste_item = null
		carrying_waste = false
	homing = false
	fight_target = null

func die(reason: String) -> void:
	if state == State.DEAD:
		return
	state = State.DEAD
	if reason != "old age":
		colony.sfx("ant_death")
	if soil > 0:
		colony.soil_lost += soil
		soil = 0
	_release_claims()
	colony.on_ant_died(self, reason)
	queue_free()

# ------------------------------------------------------------------ threats
func _check_threats() -> void:
	if colony.threats.is_empty():
		return
	if cell.y != Config.SURFACE_ROW:
		_check_intruders()
		return
	var th := colony.nearest_threat(position.x, Config.FEAR_RADIUS * Config.CELL)
	if th == null:
		return
	colony.alarm.deposit(cell, 2.0)
	colony.note_threat_seen(th)
	if caste == Caste.WORKER and state != State.HIDE and purpose != Purpose.HIDE and randf() > Config.FLEE_CHANCE:
		fear_t = 3.0          # did not react in time: carries on for a few seconds
		return
	if caste == Caste.WORKER and not is_queen and purpose != Purpose.HIDE \
			and not (state == State.MOVE and (purpose == Purpose.DEPOSIT or purpose == Purpose.DROP_FOOD or purpose == Purpose.DUMP_WASTE)) \
			and state != State.HIDE:
		colony.add_fx(position + Vector2(0, -10), "alert", "")
		_release_claims_for_flight()
		var e := colony.pick_entrance(cell)
		if e.x >= 0 and _go_to(Vector2i(e.x, Config.FIRST_SOIL_ROW), Purpose.HIDE):
			return

## Inside the nest: workers close to an intruder join the fight (a few at a time).
func _check_intruders() -> void:
	if is_queen or caste != Caste.WORKER or state == State.FIGHT or purpose == Purpose.RESPOND_IN:
		return
	if carry_food > 0.0 or carrying_brood or carrying_waste or soil > 0 or state == State.DIGGING:
		return
	var it := colony.nearest_intruder(position, 3.5 * Config.CELL)
	if it == null:
		return
	colony.alarm.deposit(cell, 1.5)
	if colony.defenders_of(it) >= 3:
		return
	_release_claims()
	fight_target = it
	if not _go_to(it.cell, Purpose.RESPOND_IN):
		fight_target = null

func _release_claims_for_flight() -> void:
	# keep what we carry (food), give back every claim others could be waiting for
	if carrying_waste or carrying_brood:
		return
	_release_claims()

# ------------------------------------------------------------------ decisions
func _decide() -> void:
	if is_queen:
		_wander_in(colony.queen_room.rect if colony.queen_room else Rect2i(cell, Vector2i(1, 1)))
		return
	if caste == Caste.SOLDIER:
		_decide_soldier()
		return
	if carry_food > 0.0:
		_go_deposit()
		return
	if carrying_waste:
		_go_dispose()
		return
	if soil > 0 and (soil >= Config.SOIL_CARRY or task != Task.DIG):
		_go_haul()
		return
	if carrying_brood or move_brood != null:
		_release_claims()
	match task:
		Task.NURSE: _decide_nurse()
		Task.DIG: _decide_dig()
		Task.FORAGE: _decide_forage()
		Task.CLEAN: _decide_clean()
		_: _wander_near(6)

func _decide_nurse() -> void:
	if carry_nurse > 0.0:
		if target_brood == null or target_brood.dead or target_brood.stage != Brood.Stage.LARVA:
			target_brood = colony.claim_hungry_larva(self)
		if target_brood != null:
			if _go_to(target_brood.cell(), Purpose.TO_LARVA):
				return
			_release_claims()
		_wander_nursery()
		return
	target_brood = colony.claim_hungry_larva(self)
	if target_brood != null:
		var s := colony.nearest_storage_with_food(cell, Config.Food.PROTEIN)
		if s.x >= 0 and _go_to(s, Purpose.PICKUP_FOOD):
			return
		_release_claims()
		wait_timer = 2.0
		return
	move_brood = colony.claim_brood_move(self)
	if move_brood != null:
		if _go_to(move_brood.cell(), Purpose.PICKUP_BROOD):
			return
		_release_claims()
		wait_timer = 2.0
		return
	_wander_nursery()

func _decide_dig() -> void:
	dig_task = colony.claim_dig_task(self)
	if dig_task == null and soil > 0:
		_go_haul()
		return
	if dig_task == null:
		wait_timer = 1.0
		eval_timer = 0.0     # nothing to dig: ask the colony again right away
		return
	var access := colony.dig_access_cell(dig_task.cell, cell)
	if access.x >= 0 and _go_to(access, Purpose.TO_DIG):
		return
	dig_task.blocked_until = colony.time + 10.0
	_release_claims()
	wait_timer = 1.0

func _decide_clean() -> void:
	waste_item = colony.claim_waste(self)
	if waste_item == null:
		wait_timer = 1.5
		eval_timer = 0.0
		return
	if _go_to(waste_item.cell, Purpose.PICKUP_WASTE):
		return
	_release_claims()
	wait_timer = 2.0

func _decide_forage() -> void:
	if colony.alarm_active() and cell.y != Config.SURFACE_ROW:
		wait_timer = randf_range(2.0, 4.0)      # the alarm is up: stay home
		return
	var k := colony.claim_dropped(cell)
	if k.x >= 0:
		drop_key = k
		if _go_to(Vector2i(k.x, k.y), Purpose.PICKUP_DROPPED):
			return
	seek_type = colony.pick_seek_type()
	if seek_type < 0:
		_wander_near(6)
		wait_timer += 2.0
		return
	if cell.y == Config.SURFACE_ROW:
		_begin_search()
		return
	var e := colony.pick_entrance(cell, seek_type)
	out_t = 0.0
	if e.x < 0 or not _go_to(e, Purpose.TO_ENTRANCE):
		_wander_near(6)

func _decide_soldier() -> void:
	var it := colony.nearest_intruder(position, 1e9)
	if it != null:
		fight_target = it
		if _go_to(it.cell, Purpose.RESPOND_IN):
			return
		fight_target = null
	var x := -1
	if colony.alarm_active():
		x = colony.alarm.best_on_surface(0.12)
	if x >= 0:
		var target := Vector2i(x, Config.SURFACE_ROW)
		if target == cell:
			state = State.FIGHT
			attack_t = 0.0
			return
		if _go_to(target, Purpose.RESPOND):
			return
	var e := colony.pick_entrance(cell)
	if e.x < 0:
		_wander_near(6)
		return
	var tgt := Vector2i(clampi(e.x + randi_range(-3, 3), 0, Config.GRID_W - 1), Config.SURFACE_ROW)
	if tgt == cell or not _go_to(tgt, Purpose.PATROL):
		state = State.WAIT
		wait_timer = randf_range(2.0, 4.0)

## Carry the soil pellets out of the nest and drop them on the mound beside the nearest entrance.
func _go_haul() -> void:
	var e := colony.pick_entrance(cell)
	if e.x >= 0:
		haul_x = e.x
		var side := 1 if (e.x + soil) % 2 == 0 else -1
		for t in [Vector2i(e.x + side, Config.SURFACE_ROW), Vector2i(e.x - side, Config.SURFACE_ROW), Vector2i(e.x, Config.SURFACE_ROW)]:
			if _go_to(t, Purpose.HAUL_SOIL):
				return
	colony.soil_lost += soil      # no way out: the pellets are packed into the tunnel wall
	soil = 0
	state = State.WAIT
	wait_timer = 0.5

func _go_deposit() -> void:
	var dst := colony.pick_storage_cell(cell)
	if dst.x >= 0 and _go_to(dst, Purpose.DEPOSIT):
		return
	_go_drop()

func _go_drop() -> void:
	var e := colony.pick_entrance(cell)
	if e.x >= 0 and _go_to(Vector2i(e.x, Config.FIRST_SOIL_ROW), Purpose.DROP_FOOD):
		return
	colony.drop_food(cell, carry_food, carry_type)
	carry_food = 0.0
	state = State.WAIT
	wait_timer = 1.0

func _go_dispose() -> void:
	var r := colony.pick_waste_room(cell, waste_item.units)
	if r != null and _go_to(r.random_cell(), Purpose.DROP_WASTE):
		return
	if colony.alarm_active():
		state = State.WAIT        # predator about: hold on to the refuse for a moment instead of going out
		wait_timer = randf_range(2.5, 5.0)
		return
	var e := colony.pick_entrance(cell)
	if e.x >= 0 and _go_to(Vector2i(e.x, Config.SURFACE_ROW), Purpose.DUMP_WASTE):
		return
	colony.return_waste(waste_item, cell)
	waste_item = null
	carrying_waste = false
	state = State.WAIT
	wait_timer = 2.0

func _wander_near(radius: int) -> void:
	var t := colony.random_nest_cell(cell, radius)
	if t == cell or not _go_to(t, Purpose.WANDER):
		state = State.WAIT
		wait_timer = randf_range(1.0, 3.0)

func _wander_nursery() -> void:
	var r := colony.random_nursery_cell()
	if r.x < 0 or not _go_to(r, Purpose.WANDER):
		_wander_near(5)

func _wander_in(rect: Rect2i) -> void:
	var t := Vector2i(rect.position.x + randi() % rect.size.x, rect.position.y + randi() % rect.size.y)
	if t == cell or not _go_to(t, Purpose.WANDER):
		state = State.WAIT
		wait_timer = randf_range(2.0, 6.0)

# ------------------------------------------------------------------ movement
func _go_to(target: Vector2i, p: int) -> bool:
	var pth := grid.find_path(cell, target)
	if pth.is_empty():
		return false
	path = pth
	path_i = 1 if pth[0] == cell else 0
	purpose = p
	state = State.MOVE
	state_time = 0.0
	return true

func _speed() -> float:
	var s := Config.QUEEN_SPEED if is_queen else (Config.SOLDIER_SPEED if caste == Caste.SOLDIER else Config.WORKER_SPEED)
	s *= 1.0 - 0.5 * hunger
	if carry_food > 0.0 or carrying_brood or carrying_waste or soil > 0:
		s *= 0.9
	if colony.is_flooded(cell):
		s *= Config.FLOOD_SLOW
	return s

## Advances along `path`; returns true once the end is reached.
func _follow(dt: float) -> bool:
	var remaining := _speed() * dt
	while remaining > 0.0 and path_i < path.size():
		var next := path[path_i]
		var target := grid.stand_pos(next) + jitter
		var d := position.distance_to(target)
		if d <= remaining:
			position = target
			remaining -= d
			prev_cell = cell
			cell = next
			path_i += 1
			_on_enter_cell(next)
		else:
			var dir := (target - position) / d
			position += dir * remaining
			face = lerp_angle(face, dir.angle(), 0.25)
			remaining = 0.0
	return path_i >= path.size()

func _on_enter_cell(c: Vector2i) -> void:
	if carry_food > 0.0 and (purpose == Purpose.DEPOSIT or homing):
		colony.trails[carry_type].deposit(c, Config.PHERO_DEPOSIT * (0.4 + 0.6 * trail_richness))
	elif caste == Caste.WORKER and carry_food <= 0.0 and (purpose == Purpose.TO_ENTRANCE or state == State.SEARCH):
		# outbound: lay the home trail, strongest close to the nest (little time spent outside)
		colony.home.deposit(c, Config.HOME_DEPOSIT * exp(-out_t / Config.HOME_DECAY_T))

func _on_arrive() -> void:
	path.clear()
	path_i = 0
	match purpose:
		Purpose.WANDER:
			state = State.WAIT
			wait_timer = randf_range(1.0, 4.0) if not is_queen else randf_range(4.0, 12.0)
		Purpose.TO_ENTRANCE:
			_begin_search()
		Purpose.DEPOSIT:
			var stored := colony.deposit_food(carry_food, carry_type, cell)
			if stored >= 0.5:
				colony.add_fx(position + Vector2(0, -8), "text", "+%d" % roundi(stored))
			carry_food -= stored
			if carry_food > 0.05:
				_go_drop()        # storage filled up on the way: leave it by the entrance
				return
			carry_food = 0.0
			state = State.WAIT
			wait_timer = 0.3
		Purpose.DROP_FOOD:
			colony.drop_food(cell, carry_food, carry_type)
			carry_food = 0.0
			state = State.WAIT
			wait_timer = 0.5
		Purpose.PICKUP_DROPPED:
			var amt := colony.take_dropped(drop_key)
			if amt > 0.0:
				carry_food = amt
				carry_type = drop_key.z
				trail_richness = 0.3
				_go_deposit()
				return
			state = State.WAIT
			wait_timer = 0.3
		Purpose.PICKUP_FOOD:
			var got := colony.take_food(Config.NURSE_FEED_COST, Config.Food.PROTEIN, cell)
			if got > 0.01 and target_brood != null and not target_brood.dead:
				carry_nurse = got
				hold_timer = 0.0
				if _go_to(target_brood.cell(), Purpose.TO_LARVA):
					return
			_release_claims()
			if got > 0.01:
				colony.return_food(got, Config.Food.PROTEIN, cell)
			state = State.WAIT
			wait_timer = 2.0
		Purpose.TO_LARVA:
			if target_brood != null and not target_brood.dead and target_brood.stage == Brood.Stage.LARVA:
				state = State.FEEDING
				wait_timer = 1.0
			else:
				_release_claims()
				state = State.WAIT
				wait_timer = 0.3
		Purpose.TO_DIG:
			if dig_task != null and colony.dig_tasks.get(dig_task.cell) == dig_task \
					and grid.get_cell(dig_task.cell) == SoilGrid.Cell.SOIL:
				state = State.DIGGING
				dig_t = 0.0
				face = (grid.cell_center(dig_task.cell) - position).angle()
			else:
				_release_claims()
				state = State.WAIT
				wait_timer = 0.2
		Purpose.PICKUP_BROOD:
			var b := move_brood
			if b != null and not b.dead and b.carried_by == self and not b.in_transit and b.dest_room != null:
				colony.pickup_brood(b)
				carrying_brood = true
				if _go_to(b.dest_room.slot_cell(b.dest_slot), Purpose.CARRY_BROOD):
					return
			_release_claims()
			state = State.WAIT
			wait_timer = 0.5
		Purpose.CARRY_BROOD:
			if move_brood != null and not move_brood.dead:
				colony.place_brood(move_brood)
			move_brood = null
			carrying_brood = false
			state = State.WAIT
			wait_timer = 0.3
		Purpose.PICKUP_WASTE:
			if waste_item != null and waste_item.claimed_by == self and waste_item in colony.waste_items:
				colony.take_waste_item(waste_item)
				carrying_waste = true
				_go_dispose()
				return
			waste_item = null
			state = State.WAIT
			wait_timer = 0.3
		Purpose.DROP_WASTE:
			var r := colony.room_at(cell)
			if r != null and r.type == Room.Type.WASTE and r.waste + waste_item.units <= r.capacity() + 0.01:
				colony.deliver_waste(waste_item, r)
				waste_item = null
				carrying_waste = false
				state = State.WAIT
				wait_timer = 0.3
			else:
				_go_dispose()
		Purpose.DUMP_WASTE:
			colony.dump_waste(waste_item, cell.x)
			colony.add_fx(position, "puff", "")
			waste_item = null
			carrying_waste = false
			state = State.WAIT
			wait_timer = 0.5
		Purpose.HIDE:
			state = State.HIDE
			hide_t = randf_range(12.0, 25.0)
		Purpose.PATROL:
			state = State.WAIT
			wait_timer = randf_range(2.0, 5.0)
		Purpose.RESPOND:
			state = State.FIGHT
			attack_t = 0.0
		Purpose.RESPOND_IN:
			if fight_target != null and colony.threats.has(fight_target) and fight_target.inside:
				state = State.FIGHT
				attack_t = 0.0
			else:
				fight_target = null
				state = State.WAIT
				wait_timer = 0.3
		Purpose.HAUL_SOIL:
			if soil > 0:
				colony.add_mound(haul_x if haul_x >= 0 else cell.x, soil)
				colony.add_fx(position, "dust", "")
			soil = 0
			state = State.WAIT
			wait_timer = 0.3
		_:
			state = State.WAIT
			wait_timer = 0.5
	state_time = 0.0

# ------------------------------------------------------------------ surface foraging
func _trail() -> PheroGrid:
	return colony.trails[clampi(seek_type, 0, colony.trails.size() - 1)]

func _begin_search() -> void:
	state = State.SEARCH
	state_time = 0.0
	search_t = colony.time
	path.clear()
	path_i = 0
	prev_cell = Vector2i(-1, -1)
	var tr := _trail()
	# prefer the side where there is a trail, otherwise random
	var l := tr.get_at(cell + Vector2i(-1, 0)) + tr.get_at(cell + Vector2i(-2, 0))
	var r := tr.get_at(cell + Vector2i(1, 0)) + tr.get_at(cell + Vector2i(2, 0))
	if l + r > 0.05:
		heading = -1 if randf() * (l + r) < l else 1
	else:
		heading = 1 if randf() < 0.5 else -1

func _step_search(dt: float) -> void:
	if cell.y != Config.SURFACE_ROW:
		state = State.WAIT
		return
	if path_i < path.size():
		if _follow(dt):
			path.clear()
			path_i = 0
		return
	if homing:
		_step_homing()
		return
	# standing on a cell: look for food, then pick the next cell
	var wanted := seek_type if state_time < 45.0 else -1
	var f := colony.food_near(cell.x, wanted)
	if f != null and colony.storage_accepts(f.type):
		var got := f.take(Config.CARRY_AMOUNT)
		if got > 0.0:
			carry_food = got
			carry_type = f.type
			colony.search_log.append(Vector2(f.pickups, colony.time - search_t))
			trail_richness = f.richness()
			colony.trails[carry_type].deposit(cell, Config.PHERO_DEPOSIT * (0.4 + 0.6 * trail_richness))
			var dst := colony.pick_storage_cell(cell)
			if dst.x >= 0 and _start_homing(dst):
				return
			if dst.x >= 0 and _go_to(dst, Purpose.DEPOSIT):
				return
			f.give_back(got)
			carry_food = 0.0
	var nxt := _search_next()
	path = [cell, nxt]
	path_i = 1

# ------------------------------------------------------------------ homing along the home trail
## Loaded forager on the surface: follow the home pheromone gradient back to an entrance, then A*
## to the storage. Falls back to A* when there is no signal or it takes too long.
func _start_homing(dst: Vector2i) -> bool:
	var h := colony.home
	if maxf(h.get_at(cell), maxf(h.get_at(cell + Vector2i(-1, 0)), h.get_at(cell + Vector2i(1, 0)))) < Config.HOME_FOLLOW_MIN:
		return false
	homing = true
	home_t = colony.time
	home_dst = dst
	path.clear()
	path_i = 0
	_step_homing()
	return true

func _step_homing() -> void:
	if colony.is_entrance_column(cell.x):
		homing = false
		colony.homing_ok += 1
		if not _go_to(home_dst, Purpose.DEPOSIT):
			_go_deposit()
		return
	var h := colony.home
	var l := h.get_at(cell + Vector2i(-1, 0)) if cell.x > 0 else -1.0
	var r := h.get_at(cell + Vector2i(1, 0)) if cell.x < Config.GRID_W - 1 else -1.0
	if colony.time - home_t > Config.HOME_GIVEUP or maxf(l, r) < Config.HOME_FOLLOW_MIN * 0.5:
		homing = false
		colony.homing_fallback += 1
		if not _go_to(home_dst, Purpose.DEPOSIT):
			_go_deposit()
		return
	var dx := -1 if l > r else 1
	if randf() > Config.HOME_FOLLOW_P:
		dx = -dx
	var nxt := Vector2i(clampi(cell.x + dx, 0, Config.GRID_W - 1), cell.y)
	path = [cell, nxt]
	path_i = 1

func _search_next() -> Vector2i:
	var tr := _trail()
	var cands: Array[Vector2i] = []
	for dx in [-1, 1]:
		var n := Vector2i(cell.x + dx, cell.y)
		if n.x >= 0 and n.x < Config.GRID_W and n != prev_cell:
			cands.append(n)
	if cands.is_empty():
		cands.append(prev_cell if prev_cell.x >= 0 else cell + Vector2i(heading, 0))
	# follow the trail by weighted probability?
	var weights: Array[float] = []
	var total := 0.0
	var trail := false
	for n in cands:
		var p := tr.get_at(n)
		if p > Config.PHERO_FOLLOW_MIN:
			trail = true
		var w := p + Config.PHERO_EPS
		weights.append(w)
		total += w
	var pick := cands[0]
	if trail and randf() > Config.PHERO_RANDOM_PICK:
		var r := randf() * total
		for i in cands.size():
			r -= weights[i]
			if r <= 0.0:
				pick = cands[i]
				break
			pick = cands[i]
	else:
		# persistent random walk, biased to keep going away from where we came from
		if randf() < Config.SURFACE_TURN_PROB:
			heading = -heading
		var n := Vector2i(cell.x + heading, cell.y)
		if n.x < 0 or n.x >= Config.GRID_W:
			heading = -heading
			n = Vector2i(cell.x + heading, cell.y)
		pick = n
	heading = signi(pick.x - cell.x) if pick.x != cell.x else heading
	return pick

# ------------------------------------------------------------------ digging / feeding / fighting
func _step_digging(dt: float) -> void:
	if dig_task == null or colony.dig_tasks.get(dig_task.cell) != dig_task:
		_release_claims()
		state = State.WAIT
		wait_timer = 0.2
		return
	dig_t += dt
	dig_task.progress = clampf(dig_t / Config.DIG_TIME, 0.0, 1.0)
	if dig_t >= Config.DIG_TIME:
		var t := dig_task
		dig_task = null
		if colony.complete_dig(t):
			soil += 1
		state = State.WAIT
		wait_timer = 0.1
		state_time = 0.0

func _finish_feeding() -> void:
	if target_brood != null and not target_brood.dead:
		colony.feed_larva(target_brood, carry_nurse)
		carry_nurse = 0.0
		target_brood.claimed_by = null
	target_brood = null
	state = State.WAIT
	wait_timer = 0.3
	state_time = 0.0

func _step_fight_inside(dt: float) -> void:
	var it := fight_target
	if it == null or not colony.threats.has(it) or not it.inside:
		fight_target = null
		state = State.WAIT
		wait_timer = 0.4
		return
	var d := position.distance_to(it.position)
	if d > Config.DEFEND_RADIUS * Config.CELL + 4.0:
		attack_t = 0.0
		if not _go_to(it.cell, Purpose.RESPOND_IN):
			fight_target = null
			state = State.WAIT
			wait_timer = 0.5
		return
	face = (it.position - position).angle()
	colony.alarm.deposit(cell, 2.0 * dt)
	attack_t += dt
	if attack_t >= 0.5:
		attack_t = 0.0
		var dps := Config.SOLDIER_DAMAGE if caste == Caste.SOLDIER else Config.WORKER_BITE
		it.hit(dps * 0.5)

func _step_fight(dt: float) -> void:
	if fight_target != null:
		_step_fight_inside(dt)
		return
	if cell.y != Config.SURFACE_ROW:
		state = State.WAIT
		return
	var th := colony.nearest_threat(position.x, 14.0 * Config.CELL)
	if th == null:
		state = State.WAIT
		wait_timer = 0.6
		return
	colony.alarm.deposit(cell, 4.0 * dt)
	var dx := th.position.x - position.x
	if absf(dx) > 12.0:
		var dir := signf(dx)
		position.x += dir * Config.SOLDIER_SPEED * 1.3 * dt
		face = 0.0 if dir > 0.0 else PI
		cell = Vector2i(clampi(floori(position.x / Config.CELL), 0, Config.GRID_W - 1), Config.SURFACE_ROW)
		position.y = grid.stand_pos(cell).y + jitter.y
	else:
		face = 0.0 if dx > 0.0 else PI
		attack_t += dt
		if attack_t >= 0.5:
			attack_t = 0.0
			th.hit(Config.SOLDIER_DAMAGE * 0.5)

# ------------------------------------------------------------------ info / drawing
func task_color() -> Color:
	match task:
		Task.NURSE: return Config.COL_NURSE
		Task.DIG: return Config.COL_DIG
		Task.FORAGE: return Config.COL_FORAGE
		Task.CLEAN: return Config.COL_CLEAN
		Task.GUARD: return Config.COL_GUARD
	return Config.COL_IDLE

func info_text() -> String:
	if is_queen:
		return "Queen - lays eggs while protein >= %.0f, sugar lasts and the nursery has room." % Config.LAY_PROTEIN_MIN
	var carry := "nothing"
	if carry_food > 0.0:
		carry = "%.1f %s (to storage)" % [carry_food, String(Config.FOOD_NAMES[carry_type]).to_lower()]
	elif carry_nurse > 0.0:
		carry = "%.1f protein (for a larva)" % carry_nurse
	elif carrying_brood:
		carry = "a brood item (to a nursery)"
	elif carrying_waste:
		carry = "refuse / a corpse"
	elif soil > 0:
		carry = "%d soil pellet%s (to the mound)" % [soil, "s" if soil > 1 else ""]
	elif state == State.DIGGING:
		carry = "digging a soil cell"
	if homing:
		carry += " - following the home trail"
	var kind := "Worker" if caste == Caste.WORKER else "Soldier (HP %.1f/%.0f)" % [maxf(hp, 0.0), Config.SOLDIER_HP]
	return "%s  age %ds / %ds (%d%%)\nTask: %s (%s)\nCarrying: %s   Hunger: %d%%" % [
		kind, int(age), int(lifespan), int(100.0 * age / lifespan),
		TASK_NAMES[task], STATE_NAMES[state], carry, int(hunger * 100.0)]

# Optional sprite art (assets/sprites): [texture, has_own_legs], resolved once per caste.
static var _spr_cache := {}
const SPRITE_SCALE := {"worker_ant": 0.5, "soldier_ant": 0.5, "queen_ant": 0.48}   # batch-3 sprites are 2x canvases (48x30 / 64x36 / 96x48)
const ART_K := 1.5      # code legs / antennae grow with the bigger batch-3 sprites

func _sprite() -> Array:
	var key := "queen_ant" if is_queen else ("soldier_ant" if caste == Caste.SOLDIER else "worker_ant")
	if not _spr_cache.has(key):
		_spr_cache[key] = Art.sprite(key)
	return _spr_cache[key]

func _draw() -> void:
	if state == State.DEAD:
		return
	var soldier := caste == Caste.SOLDIER
	var s := 1.0
	if is_queen:
		s = 1.9
	elif soldier:
		s = 1.3
	var body := Color(0.52, 0.18, 0.09)
	if is_queen:
		body = Color(0.40, 0.12, 0.08)
	elif soldier:
		body = Color(0.38, 0.06, 0.05)
	var halo := Color(1.0, 0.92, 0.80, 0.55)
	var ab := task_color()
	if is_queen:
		ab = Color(0.85, 0.55, 0.20)
	var moving := state == State.MOVE or state == State.SEARCH or (state == State.FIGHT and attack_t == 0.0)
	var phase := anim * (15.0 if moving else 0.0) + phase0
	var bob := sin(phase * 2.0) * 0.35 if moving else 0.0
	var pulse := 1.0
	if is_queen:
		pulse = 1.0 + 0.06 * sin(anim * 2.0) + (0.12 if colony.lay_timer < 1.5 else 0.0)
	var spr := _sprite()
	var tex: Texture2D = spr[0]
	var sprite_legs: bool = spr[1]          # full sprite already has legs -> do not draw code legs
	# the queen sprite is a lot smaller than the old 1.9x drawing, so her legs are shorter and sit on her thorax
	var leg_s := (1.25 * ART_K if is_queen else s * ART_K) if tex != null else s
	var lx0 := 1.6 if (tex != null and is_queen) else 0.0
	draw_set_transform(Vector2(0, bob), face, Vector2(leg_s, leg_s))
	# legs: tripod gait, two segments
	# all 12 leg segments go out in two batched multiline commands (halo, then body)
	if not (tex != null and sprite_legs):
		var segs := PackedVector2Array()
		segs.resize(24)
		var k := 0
		for i in 3:
			var lx := -1.2 + i * 1.7 + lx0
			for side: float in [-1.0, 1.0]:
				var ph := phase + float(i) * TAU / 3.0 + (PI if side > 0.0 else 0.0)
				var swing := sin(ph) * (2.0 if moving else 0.3)
				var lift := maxf(0.0, cos(ph)) * 0.9 if moving else 0.0
				var hip := Vector2(lx, 0)
				var knee := Vector2(lx + swing * 0.4, side * 3.0 - side * lift)
				var foot := Vector2(lx + swing, side * 5.2)
				segs[k] = hip; segs[k + 1] = knee; segs[k + 2] = knee; segs[k + 3] = foot
				k += 4
		draw_multiline(segs, halo, 1.6)
		draw_multiline(segs, body, 0.9)
	var ant_s := s * ART_K if tex != null else s
	draw_set_transform(Vector2(0, bob), face, Vector2(ant_s, ant_s))
	# antennae twitch
	var tw := sin(anim * 5.0 + phase0) * 0.35 + (sin(phase) * 0.15 if moving else 0.0)
	var head_x := 4.0
	if tex != null and soldier:
		head_x = 4.4                # sprite soldier has a bigger head
	var head_dip := 0.0
	if state == State.DIGGING:
		head_dip = sin(anim * 22.0) * 1.2
		head_x += 0.8
	draw_line(Vector2(head_x + 1.0, head_dip), Vector2(7.6, 2.4 + tw * 2.0 + head_dip), body, 0.9)
	draw_line(Vector2(head_x + 1.0, head_dip), Vector2(7.6, -2.4 - tw * 2.0 + head_dip), body, 0.9)
	# body: abdomen, thorax, head (halo first)
	draw_set_transform(Vector2(0, bob), face, Vector2(s, s))
	var hr := 2.0 if not soldier else 2.9
	if tex != null:
		# sprite body, flipped (not rotated upside down) when facing left; tint keeps the task readable
		var ss: float = SPRITE_SCALE[("queen_ant" if is_queen else ("soldier_ant" if soldier else "worker_ant"))]
		var k := 1.0 + (pulse - 1.0) * 0.5
		var flip := -1.0 if cos(face) < 0.0 else 1.0
		draw_set_transform(Vector2(0, bob), face, Vector2(ss * k, ss * k * flip))
		var tint := Color.WHITE if is_queen else Color.WHITE.lerp(ab, 0.18)
		draw_texture(tex, -tex.get_size() * 0.5, tint)
		draw_set_transform(Vector2(0, bob), face, Vector2(s, s))
		if not is_queen:
			Art.dot(self, Vector2(-4.0, 0), 1.5, Color(ab.r, ab.g, ab.b, 0.9))    # abdomen task dot
	else:
		Art.dot(self, Vector2(-4.4, 0), 3.9 * pulse, halo)
		Art.dot(self, Vector2(0.4, 0), 2.9, halo)
		Art.dot(self, Vector2(head_x, head_dip), hr + 0.8, halo)
		Art.dot(self, Vector2(-4.4, 0), 3.1 * pulse, ab)
		Art.dot(self, Vector2(-4.4, 0), 2.0 * pulse, ab.darkened(0.15))
		Art.dot(self, Vector2(0.4, 0), 2.1, body)
		Art.dot(self, Vector2(head_x, head_dip), hr, body)
	if soldier and (tex == null or state == State.FIGHT):
		# mandibles
		var open := 0.5 + 0.5 * sin(anim * 14.0) if state == State.FIGHT else 0.0
		draw_line(Vector2(head_x + 2.4, head_dip + 0.8), Vector2(head_x + 5.0, head_dip + 1.8 + open * 1.5), Color(0.9, 0.8, 0.6), 1.1)
		draw_line(Vector2(head_x + 2.4, head_dip - 0.8), Vector2(head_x + 5.0, head_dip - 1.8 - open * 1.5), Color(0.9, 0.8, 0.6), 1.1)
	if carry_food > 0.0:
		Art.dot(self, Vector2(7.5, 0), 2.3, Config.FOOD_COL[carry_type])
	elif carry_nurse > 0.0:
		Art.dot(self, Vector2(7.5, 0), 1.9, Color(1.0, 0.95, 0.75))
	elif carrying_brood:
		draw_set_transform(Vector2(0, bob), face, Vector2(s * 1.5, s))
		Art.dot(self, Vector2(6.0, 0), 2.4, Color(0.97, 0.95, 0.85))
		draw_set_transform(Vector2(0, bob), face, Vector2(s, s))
	elif carrying_waste:
		Art.dot(self, Vector2(7.2, 0), 2.1, Color(0.45, 0.36, 0.22))
	elif soil > 0:
		draw_rect(Rect2(6.0, -1.8, 3.6, 3.6), Color(0.62, 0.46, 0.30))
		draw_rect(Rect2(6.0, -1.8, 3.6, 3.6), Color(0.25, 0.17, 0.10), false, 0.6)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	# task marker + selection ring
	var my := -7.0 * s
	Art.dot(self, Vector2(0, my), 2.0, Color(0, 0, 0, 0.6))
	Art.dot(self, Vector2(0, my), 1.5, task_color() if not is_queen else Color(1, 0.85, 0.2))
	if state == State.DIGGING:
		var prog := dig_task.progress if dig_task != null else 0.0
		draw_rect(Rect2(-6, 7, 12, 2), Color(0, 0, 0, 0.6))
		draw_rect(Rect2(-6, 7, 12.0 * prog, 2), COL_DIG_BAR)
	if state == State.HIDE:
		draw_string(ThemeDB.fallback_font, Vector2(-4, -9), "z", HORIZONTAL_ALIGNMENT_CENTER, 8.0, 9, Color(0.8, 0.9, 1.0, 0.8))
	if soldier and hp < Config.SOLDIER_HP:
		draw_rect(Rect2(-6, 8, 12, 2), Color(0, 0, 0, 0.6))
		draw_rect(Rect2(-6, 8, 12.0 * clampf(hp / Config.SOLDIER_HP, 0.0, 1.0), 2), Color(0.95, 0.25, 0.2))
	if selected:
		draw_arc(Vector2.ZERO, 11.0 * (1.0 if not is_queen else 1.6), 0.0, TAU, 24, Color(1, 1, 1, 0.9), 1.5)
