class_name Threat
extends Node2D
## A surface intruder: a spider (slow, deadly) or a rival-colony scout (quick, weaker).
## It wanders along the surface, hunts ants that are outside and is fought by soldiers.

enum Kind { SPIDER, RIVAL }

const NAMES := ["spider", "rival scout"]

var colony: Colony
var kind: int = Kind.SPIDER
var hp := 6.0
var max_hp := 6.0
var life := 60.0
var dir := 1.0
var speed := 26.0
var kill_time := 1.4
var soldier_dps := 1.0
var atk_t := 0.0
var victim: Ant = null
var leaving := false
var anim := 0.0
var turn_t := 2.0
var idle_t := 0.0               # spider: time without prey (then it ambushes an entrance)
# v5: raids into the nest (rival scouts)
var raider := false             # will try to enter the nest
var inside := false
var cell := Vector2i.ZERO
var path: Array[Vector2i] = []
var path_i := 0
var raid_phase := 0             # 0 = on the surface, 1 = going to the loot, 2 = leaving with it
var raid_goal := ""             # "food" or "brood"
var loot_food := 0.0
var loot_type := 0
var loot_brood := {}            # stage / caste / progress of a stolen brood item
var raid_t := 0.0
var bite_t := 0.0

func setup(c: Colony, k: int, x_px: float, life_s: float) -> void:
	colony = c
	kind = k
	life = life_s
	if k == Kind.SPIDER:
		max_hp = 6.0
		speed = 26.0
		kill_time = 1.0
		soldier_dps = 0.8
	else:
		max_hp = 3.0
		speed = 42.0
		kill_time = 2.0
		soldier_dps = 0.6
	hp = max_hp
	position = Vector2(x_px, Config.FIRST_SOIL_ROW * Config.CELL - 5.0)
	dir = 1.0 if x_px < Config.GRID_W * Config.CELL * 0.5 else -1.0
	z_index = 6

func cell_x() -> int:
	return clampi(floori(position.x / Config.CELL), 0, Config.GRID_W - 1)

func step(dt: float) -> void:
	anim += dt
	if inside:
		_step_inside(dt)
		queue_redraw()
		return
	life -= dt
	if life <= 0.0 and not leaving:
		leaving = true
		colony.log_event("The %s wanders off." % NAMES[kind], "threat_spider")
	if leaving:
		var edge := -1.0 if position.x < Config.GRID_W * Config.CELL * 0.5 else 1.0
		position.x += edge * speed * 1.3 * dt
		if position.x < -30.0 or position.x > Config.GRID_W * Config.CELL + 30.0:
			colony.remove_threat(self)
		queue_redraw()
		return
	if raider and raid_phase == 0 and _try_enter(dt):
		queue_redraw()
		return
	# hunt the nearest ant on the surface
	if victim == null or victim.state == Ant.State.DEAD or victim.cell.y != Config.SURFACE_ROW \
			or absf(victim.position.x - position.x) > 260.0:
		victim = null
		atk_t = 0.0
		var best := 260.0
		for a in colony.ants:
			if a.cell.y == Config.SURFACE_ROW and a.state != Ant.State.DEAD:
				var d := absf(a.position.x - position.x)
				if d < best:
					best = d
					victim = a
	idle_t = 0.0 if victim != null else idle_t + dt
	if victim != null:
		var dx := victim.position.x - position.x
		if absf(dx) > 13.0:
			dir = signf(dx)
			# lunge: a predator closes the last few cells much faster than it stalks
			position.x += dir * speed * (2.4 if absf(dx) < 72.0 else 1.0) * dt
			atk_t = 0.0
		else:
			atk_t += dt
			if victim.caste == Ant.Caste.SOLDIER:
				victim.hp -= soldier_dps * dt
				if victim.hp <= 0.0:
					colony.log_event("A soldier was killed by the %s." % NAMES[kind], "soldier")
					victim.die("killed by a " + NAMES[kind])
					victim = null
			elif atk_t >= kill_time:
				colony.note_threat_seen(self)
				colony.add_fx(victim.position, "skull", "")
				victim.die("killed by a " + NAMES[kind])
				victim = null
				atk_t = 0.0
	elif kind == Kind.SPIDER and idle_t > Config.AMBUSH_AFTER:
		# nothing to hunt for a while: lurk next to the busiest entrance
		var ex := colony.busiest_entrance_x()
		if ex >= 0:
			var tx := (ex + 2.5) * Config.CELL
			if absf(tx - position.x) > 4.0:
				dir = signf(tx - position.x)
				position.x += dir * speed * 0.5 * dt
	else:
		turn_t -= dt
		if turn_t <= 0.0:
			turn_t = randf_range(1.5, 4.0)
			if randf() < 0.5:
				dir = -dir
		position.x += dir * speed * 0.6 * dt
		if position.x < 20.0:
			dir = 1.0
		elif position.x > Config.GRID_W * Config.CELL - 20.0:
			dir = -1.0
	queue_redraw()

func hit(dmg: float) -> void:
	if hp <= 0.0:
		return
	hp -= dmg
	colony.sfx("fight")
	colony.add_fx(position + Vector2(randf_range(-6, 6), -4), "spark", "")
	if hp <= 0.0:
		if inside:
			colony.intruders_killed += 1
			colony.log_event("The intruder was killed inside the nest%s." % (" - its loot is recovered" if (loot_food > 0.0 or not loot_brood.is_empty()) else ""), "soldier")
			if loot_food > 0.0:
				colony.drop_food(cell, loot_food, loot_type)
				colony.food_stolen -= loot_food
				loot_food = 0.0
			if not loot_brood.is_empty():
				colony.rescue_brood(loot_brood, cell)
				loot_brood = {}
		else:
			colony.log_event("Soldiers killed the %s!" % NAMES[kind], "soldier")
		colony.remove_threat(self)

# ------------------------------------------------------------------ raids inside the nest (v5)
## Walk to the nearest entrance and slip in. Returns true while busy with that.
func _try_enter(dt: float) -> bool:
	var ex := colony.nearest_entrance_px(position.x)
	if ex < 0:
		raider = false
		return false
	var tx := (ex + 0.5) * Config.CELL
	if absf(tx - position.x) > 3.0:
		dir = signf(tx - position.x)
		position.x += dir * speed * dt
		return true
	# at the hole: pick a target and go in
	var goal := colony.raid_target(randf() < 0.5)
	if goal.is_empty():
		raider = false
		return false
	cell = Vector2i(ex, Config.SURFACE_ROW)
	var pth := colony.grid.find_path(cell, goal["cell"])
	if pth.is_empty():
		raider = false
		return false
	raid_goal = goal["kind"]
	path = pth
	path_i = 1
	inside = true
	raid_phase = 1
	raid_t = 0.0
	colony.raids += 1
	colony.last_threat_t = colony.time
	colony.alarm.deposit(Vector2i(ex, Config.FIRST_SOIL_ROW), 3.0)
	colony.log_event("A %s slipped into the nest - it is after the %s!" % [NAMES[kind], "food" if raid_goal == "food" else "brood"], "alert")
	colony.sfx("alarm")
	return true

func _step_inside(dt: float) -> void:
	raid_t += dt
	colony.alarm.deposit(cell, 3.0 * dt)
	# fight back against the nearest ant in reach; while engaged it does not move
	var foe: Ant = null
	var best := Config.DEFEND_RADIUS * Config.CELL + 4.0
	for a in colony.ants:
		if a.fight_target == self and a.state == Ant.State.FIGHT:
			var d := a.position.distance_to(position)
			if d < best:
				best = d
				foe = a
	if foe != null:
		bite_t += dt
		foe.hp -= Config.INTRUDER_DPS * dt
		if foe.hp <= 0.0:
			colony.add_fx(foe.position, "skull", "")
			foe.die("killed by an intruder")
		return
	if raid_t > 90.0 and raid_phase == 1:
		_head_out()          # lost: give up and leave
	if path_i >= path.size():
		_on_raid_arrive()
		return
	var next := path[path_i]
	var target := colony.grid.stand_pos(next)
	var dvec := target - position
	var step := Config.RAID_SPEED * dt * (Config.FLOOD_SLOW if colony.is_flooded(cell) else 1.0)
	if dvec.length() <= step:
		position = target
		cell = next
		path_i += 1
	else:
		position += dvec.normalized() * step
		if absf(dvec.x) > 0.1:
			dir = signf(dvec.x)

func _on_raid_arrive() -> void:
	if raid_phase == 1:
		if raid_goal == "food":
			var got: Array = colony.steal_food(cell, Config.RAID_STEAL_FOOD)
			loot_food = got[0]
			loot_type = got[1]
		else:
			loot_brood = colony.steal_brood(cell)
		if loot_food > 0.0 or not loot_brood.is_empty():
			var what := "%.0f %s" % [loot_food, String(Config.FOOD_NAMES[loot_type]).to_lower()] if loot_food > 0.0 else "a piece of brood"
			colony.log_event("The intruder grabbed %s!" % what, "alert")
		_head_out()
	elif raid_phase == 2:
		# back on the surface: escape with the loot
		inside = false
		raider = false
		leaving = true
		if not loot_brood.is_empty():
			colony.brood_stolen += 1
		loot_brood = {}
		position = colony.grid.stand_pos(cell)
		position.y = Config.FIRST_SOIL_ROW * Config.CELL - 5.0
		colony.log_event("The intruder escaped%s." % (" with stolen loot" if loot_food > 0.0 else ""), "threat_spider")

func _head_out() -> void:
	raid_phase = 2
	var e := colony.pick_entrance(cell)
	var pth: Array[Vector2i] = colony.grid.find_path(cell, e) if e.x >= 0 else ([] as Array[Vector2i])
	if pth.is_empty():
		path = [cell]
		path_i = 1
		return
	path = pth
	path_i = 1

func _body_tex() -> Texture2D:
	var key := "spider" if kind == Kind.SPIDER else "rival_scout"
	var sp: Array = Art.sprite(key)
	return sp[0] if not sp[1] else null    # a full sprite already has legs: use procedural drawing instead

func _draw() -> void:
	var legs := sin(anim * 9.0)
	var btex := _body_tex()
	var fx := 1.0 if dir > 0.0 else -1.0
	if btex != null and kind == Kind.SPIDER:
		var body := Color(0.16, 0.10, 0.12)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.5, 1.5))     # legs sized for the 72x48 batch-3 body
		for i in 4:
			var ox := (-4.0 + i * 2.8) * fx
			var sw := legs * 2.0 * (1.0 if i % 2 == 0 else -1.0)
			draw_polyline(PackedVector2Array([Vector2(ox * 0.6, 0), Vector2(ox - 5.0 + sw, -6.0), Vector2(ox - 8.0 + sw, 4.0)]), body, 1.3)
			draw_polyline(PackedVector2Array([Vector2(ox * 0.6, 0), Vector2(ox + 6.0 - sw, -6.0), Vector2(ox + 9.0 - sw, 4.0)]), body, 1.3)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(0.5 * fx, 0.5))
		draw_texture(btex, -btex.get_size() * 0.5)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	elif btex != null:
		var lb := Color(0.28, 0.12, 0.40)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(2.1 * fx, 2.1))
		for i in 3:
			var lx := -1.0 + i * 1.6
			var sw := legs * 1.2 * (1.0 if i % 2 == 0 else -1.0)
			draw_line(Vector2(lx, 0), Vector2(lx + sw, 4.2), lb, 1.0)
			draw_line(Vector2(lx, 0), Vector2(lx - sw, -4.2), lb, 1.0)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(0.5 * fx, 0.5))
		draw_texture(btex, -btex.get_size() * 0.5)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	elif kind == Kind.SPIDER:
		var body := Color(0.16, 0.10, 0.12)
		for i in 4:
			var ox := -4.0 + i * 2.8
			var sw := legs * 2.0 * (1.0 if i % 2 == 0 else -1.0)
			draw_polyline(PackedVector2Array([Vector2(ox * 0.6, 0), Vector2(ox - 5.0 + sw, -6.0), Vector2(ox - 8.0 + sw, 4.0)]), body, 1.3)
			draw_polyline(PackedVector2Array([Vector2(ox * 0.6, 0), Vector2(ox + 6.0 - sw, -6.0), Vector2(ox + 9.0 - sw, 4.0)]), body, 1.3)
		Art.dot(self, Vector2(-3.5, 0), 5.5, body)
		Art.dot(self, Vector2(3.5, -0.5), 3.4, body.lightened(0.1))
		Art.dot(self, Vector2(5.0, -1.5), 0.9, Color(1, 0.2, 0.2))
		Art.dot(self, Vector2(5.6, 0.2), 0.9, Color(1, 0.2, 0.2))
	else:
		var body := Color(0.28, 0.12, 0.40)
		var halo := Color(1, 0.9, 0.9, 0.5)
		draw_set_transform(Vector2.ZERO, 0.0 if dir > 0.0 else PI, Vector2(1.4, 1.4))
		for i in 3:
			var lx := -1.0 + i * 1.6
			var sw := legs * 1.2 * (1.0 if i % 2 == 0 else -1.0)
			draw_line(Vector2(lx, 0), Vector2(lx + sw, 4.2), body, 1.0)
			draw_line(Vector2(lx, 0), Vector2(lx - sw, -4.2), body, 1.0)
		Art.dot(self, Vector2(-4.4, 0), 3.8, halo)
		Art.dot(self, Vector2(4.0, 0), 2.8, halo)
		Art.dot(self, Vector2(-4.4, 0), 3.1, body)
		Art.dot(self, Vector2(0.4, 0), 2.1, body.lightened(0.1))
		Art.dot(self, Vector2(4.0, 0), 2.0, Color(0.55, 0.15, 0.25))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if hp < max_hp:
		draw_rect(Rect2(-9, -14, 18, 2.5), Color(0, 0, 0, 0.7))
		draw_rect(Rect2(-9, -14, 18.0 * clampf(hp / max_hp, 0.0, 1.0), 2.5), Color(0.95, 0.25, 0.2))
	draw_string(ThemeDB.fallback_font, Vector2(-4, -17), "!", HORIZONTAL_ALIGNMENT_CENTER, 8.0, 12, Color(1, 0.3, 0.2))
