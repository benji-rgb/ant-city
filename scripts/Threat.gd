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
	hp -= dmg
	colony.sfx("fight")
	colony.add_fx(position + Vector2(randf_range(-6, 6), -4), "spark", "")
	if hp <= 0.0:
		colony.log_event("Soldiers killed the %s!" % NAMES[kind], "soldier")
		colony.remove_threat(self)

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
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(1.4 * fx, 1.4))
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
		draw_circle(Vector2(-3.5, 0), 5.5, body)
		draw_circle(Vector2(3.5, -0.5), 3.4, body.lightened(0.1))
		draw_circle(Vector2(5.0, -1.5), 0.9, Color(1, 0.2, 0.2))
		draw_circle(Vector2(5.6, 0.2), 0.9, Color(1, 0.2, 0.2))
	else:
		var body := Color(0.28, 0.12, 0.40)
		var halo := Color(1, 0.9, 0.9, 0.5)
		draw_set_transform(Vector2.ZERO, 0.0 if dir > 0.0 else PI, Vector2(1.4, 1.4))
		for i in 3:
			var lx := -1.0 + i * 1.6
			var sw := legs * 1.2 * (1.0 if i % 2 == 0 else -1.0)
			draw_line(Vector2(lx, 0), Vector2(lx + sw, 4.2), body, 1.0)
			draw_line(Vector2(lx, 0), Vector2(lx - sw, -4.2), body, 1.0)
		draw_circle(Vector2(-4.4, 0), 3.8, halo)
		draw_circle(Vector2(4.0, 0), 2.8, halo)
		draw_circle(Vector2(-4.4, 0), 3.1, body)
		draw_circle(Vector2(0.4, 0), 2.1, body.lightened(0.1))
		draw_circle(Vector2(4.0, 0), 2.0, Color(0.55, 0.15, 0.25))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if hp < max_hp:
		draw_rect(Rect2(-9, -14, 18, 2.5), Color(0, 0, 0, 0.7))
		draw_rect(Rect2(-9, -14, 18.0 * clampf(hp / max_hp, 0.0, 1.0), 2.5), Color(0.95, 0.25, 0.2))
	draw_string(ThemeDB.fallback_font, Vector2(-4, -17), "!", HORIZONTAL_ALIGNMENT_CENTER, 8.0, 12, Color(1, 0.3, 0.2))
