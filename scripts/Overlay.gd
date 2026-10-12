class_name Overlay
extends Node2D
## Dynamic drawing layer. Two instances: `top == false` sits under the ants (rooms, brood, waste,
## dig orders, mounds, pheromones, climate); `top == true` sits above (placement ghost, effects).

var top := false
var colony: Colony
var main: Node = null            # Main (for tool state), untyped to avoid a cyclic reference
var show_phero := false
var show_climate := false

const ROOM_COL := {
	Room.Type.QUEEN_CHAMBER: Color(0.75, 0.45, 0.95),
	Room.Type.NURSERY: Color(1.0, 0.60, 0.80),
	Room.Type.FOOD_STORAGE: Color(1.0, 0.80, 0.25),
	Room.Type.WASTE: Color(0.62, 0.72, 0.30),
}
const C := Config.CELL
const ART_DIR := "res://assets/chambers/"
const ART_ALPHA := 0.62          # chamber art is a backdrop: fill indicators, brood and text stay readable
const GHOST_ART_ALPHA := 0.45

var _art := {}                   # Room.Type -> Texture2D, or null when the file is missing (old drawing is used)

# v5 (web performance): pheromone / climate / flood overlays are one 80x45 image, rebuilt a few
# times per second and drawn scaled up by a single Sprite2D, instead of thousands of draw_rect per frame.
const FIELD_HZ := 6.0
var _field_img: Image
var _field_tex: ImageTexture
var _field_spr: Sprite2D
var _field_t := 0.0
var field_updates := 0           # diagnostics
const COL_HOME := Color(0.35, 0.80, 1.0)

func _ready() -> void:
	if not top:
		_field_img = Image.create(Config.GRID_W, Config.GRID_H, false, Image.FORMAT_RGBA8)
		_field_img.fill(Color(0, 0, 0, 0))
		_field_tex = ImageTexture.create_from_image(_field_img)
		_field_spr = Sprite2D.new()
		_field_spr.texture = _field_tex
		_field_spr.centered = false
		_field_spr.scale = Vector2(C, C)
		_field_spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		_field_spr.show_behind_parent = true      # under the chamber art and labels
		_field_spr.visible = false
		add_child(_field_spr)
	for t in ROOM_COL:
		var path := "%s%s.png" % [ART_DIR, Room.icon_name(t)]
		# batch 3: the queen chamber / storage come as "_empty" backdrops (queen, brood and stock are drawn live)
		var empty := "%s%s_empty.png" % [ART_DIR, Room.icon_name(t)]
		if ResourceLoader.exists(empty):
			path = empty
		var tex: Texture2D = null
		if ResourceLoader.exists(path):
			tex = load(path) as Texture2D
		if tex == null and not top:
			push_warning("Overlay: chamber art missing: " + path)
		_art[t] = tex

## Draws `tex` into `dst` without distortion: scaled to cover, centred, overflow cropped
## (the floor of the picture stays at the bottom of the room).
func _draw_art(tex: Texture2D, dst: Rect2, alpha: float) -> void:
	var ts := tex.get_size()
	var want := dst.size.x / dst.size.y
	var src := Rect2(Vector2.ZERO, ts)
	if ts.x / ts.y > want:
		src.size.x = ts.y * want
		src.position.x = (ts.x - src.size.x) * 0.5
	else:
		src.size.y = ts.x / want
		src.position.y = ts.y - src.size.y        # keep the bottom (floor)
	draw_texture_rect_region(tex, dst, src, Color(1, 1, 1, alpha))

func _process(delta: float) -> void:
	queue_redraw()
	if top or colony == null or _field_spr == null:
		return
	var want := show_phero or show_climate or _any_water()
	_field_spr.visible = want
	if not want:
		return
	_field_t -= delta
	if _field_t <= 0.0:
		_field_t = 1.0 / FIELD_HZ
		_rebuild_field()

func _any_water() -> bool:
	return colony.raining or colony.flooded_cells > 0 or Climate.wet > 0.05

## Fills the 80x45 field image (one pixel per cell) and uploads it (same texture object, no reallocation).
@warning_ignore("integer_division")
func _rebuild_field() -> void:
	var img := _field_img
	img.fill(Color(0, 0, 0, 0))
	var w := Config.GRID_W
	if show_climate:
		for y in range(Config.FIRST_SOIL_ROW, Config.GRID_H):
			var tint := _heat_color(Climate.temp(y, colony.time))
			var qc := Color.from_hsv(0.33 * Climate.quality_at(y, colony.time), 0.8, 0.9)
			var soil := Color(tint.r, tint.g, tint.b, 0.20)
			var open := soil.blend(Color(qc.r, qc.g, qc.b, 0.45))
			for x in w:
				img.set_pixel(x, y, open if colony.grid.walk[y * w + x] == 1 else soil)
	var fl := colony.flood
	for i in colony.grid.walk_idx:
		var x := i % w
		var y := i / w
		var r := 0.0
		var g := 0.0
		var b := 0.0
		var a := 0.0
		if show_phero:
			var s := clampf(colony.trails[0].a[i] / Config.PHERO_MAX, 0.0, 1.0)
			var p := clampf(colony.trails[1].a[i] / Config.PHERO_MAX, 0.0, 1.0)
			var h := clampf(colony.home.a[i] / Config.HOME_MAX, 0.0, 1.0)
			var al := clampf(colony.alarm.a[i] / colony.alarm.max_value, 0.0, 1.0)
			# the strongest layer wins (home counts a bit less so food trails stay readable on the surface)
			var vals: Array[float] = [s, p, h * 0.7, al * 1.2]
			var best := -1
			var bv := 0.006
			for k in 4:
				if vals[k] > bv:
					bv = vals[k]
					best = k
			if best >= 0:
				var col: Color = [Config.FOOD_COL[0], Config.FOOD_COL[1], COL_HOME, Color(1.0, 0.1, 0.05)][best]
				var wgt := 0.25 + 0.6 * clampf(bv, 0.0, 1.0)
				r += col.r * wgt
				g += col.g * wgt
				b += col.b * wgt
				a += wgt
		if fl[i] > 0.03:
			var wgt := 0.2 + 0.5 * fl[i]
			r += 0.15 * wgt
			g += 0.40 * wgt
			b += 0.95 * wgt
			a += wgt
		if a > 0.0:
			var base := img.get_pixel(x, y)
			var col := Color(r / a, g / a, b / a, minf(0.85, a))
			img.set_pixel(x, y, base.blend(col) if base.a > 0.0 else col)
	_field_tex.update(img)
	field_updates += 1

func _draw() -> void:
	if colony == null:
		return
	if top:
		_draw_top()
		return
	if show_climate:
		_draw_climate_labels()
	_draw_rooms()
	_draw_brood()
	_draw_waste()
	_draw_dig_orders()
	_draw_mounds()
	if show_phero:
		_text(Vector2(8, Config.FIRST_SOIL_ROW * C + 150), "TRAILS: yellow sugar, pink protein, blue home (nest), red alarm", 10, Color(1, 1, 0.8))

func _cell_rect(c: Vector2i) -> Rect2:
	return Rect2(c.x * C, c.y * C, C, C)

func _rect_px(r: Rect2i) -> Rect2:
	return Rect2(r.position.x * C, r.position.y * C, r.size.x * C, r.size.y * C)

func _text(p: Vector2, txt: String, size: int, col: Color) -> void:
	var font := ThemeDB.fallback_font
	draw_string(font, p + Vector2(1, 1), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.85))
	draw_string(font, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)

# ------------------------------------------------------------------ rooms
func _draw_rooms() -> void:
	for r in colony.rooms:
		var col: Color = ROOM_COL[r.type]
		var px := _rect_px(r.rect)
		if r.active:
			draw_rect(px, Color(col.r, col.g, col.b, 0.13), true)
			var art: Texture2D = _art.get(r.type)
			if art != null:
				_draw_art(art, px, ART_ALPHA)
			if r.type == Room.Type.FOOD_STORAGE:
				_draw_storage_fill(r)
			elif r.type == Room.Type.WASTE:
				_draw_waste_fill(r)
			draw_rect(px, Color(col.r, col.g, col.b, 0.75), false, 1.5)
		else:
			draw_rect(px, Color(col.r, col.g, col.b, 0.07), true)
			var step := 8.0
			var x := px.position.x
			while x < px.end.x:
				var x2 := minf(x + 4.0, px.end.x)
				draw_line(Vector2(x, px.position.y), Vector2(x2, px.position.y), col, 1.5)
				draw_line(Vector2(x, px.end.y), Vector2(x2, px.end.y), col, 1.5)
				x += step
			var y := px.position.y
			while y < px.end.y:
				var y2 := minf(y + 4.0, px.end.y)
				draw_line(Vector2(px.position.x, y), Vector2(px.position.x, y2), col, 1.5)
				draw_line(Vector2(px.end.x, y), Vector2(px.end.x, y2), col, 1.5)
				y += step
		var txt := r.short_label()
		if show_climate and r.type == Room.Type.NURSERY:
			txt = "%d%% comfort" % roundi(r.quality * 100.0)
		_text(Vector2(px.position.x + 3, px.position.y + 11), txt, 10, Color(col.r, col.g, col.b).lightened(0.5))

func _draw_storage_fill(r: Room) -> void:
	var per := r.capacity() / r.cell_count()
	var used := 0.0
	var total := r.food()
	# fill bottom row first, left to right; colour = what lies at that point of the heap
	for row in range(r.rect.size.y - 1, -1, -1):
		for k in r.rect.size.x:
			if used >= total:
				return
			var amount := minf(per, total - used)
			var frac := clampf(amount / per, 0.0, 1.0)
			var t := Config.Food.SUGAR if used + amount * 0.5 < r.sugar else Config.Food.PROTEIN
			used += amount
			var c := Vector2i(r.rect.position.x + k, r.rect.position.y + row)
			var cr := _cell_rect(c)
			var h := (C - 3.0) * frac
			draw_rect(Rect2(cr.position.x + 1, cr.end.y - 2 - h, C - 2, h + 2), Color(0.05, 0.03, 0.02, 0.55), true)
			var fc: Color = Config.FOOD_COL[t]
			draw_rect(Rect2(cr.position.x + 2, cr.end.y - 1 - h, C - 4, h), Color(fc.r, fc.g, fc.b, 0.9), true)
			draw_rect(Rect2(cr.position.x + 2, cr.end.y - 1 - h, C - 4, 2), fc.lightened(0.4), true)

func _draw_waste_fill(r: Room) -> void:
	var per := r.capacity() / r.cell_count()
	var used := 0.0
	for row in range(r.rect.size.y - 1, -1, -1):
		for k in r.rect.size.x:
			if used >= r.waste:
				return
			var frac := clampf((r.waste - used) / per, 0.0, 1.0)
			used += per
			var cr := _cell_rect(Vector2i(r.rect.position.x + k, r.rect.position.y + row))
			var h := (C - 3.0) * frac
			draw_rect(Rect2(cr.position.x + 1, cr.end.y - 2 - h, C - 2, h + 2), Color(0.05, 0.03, 0.02, 0.55), true)
			draw_rect(Rect2(cr.position.x + 2, cr.end.y - 1 - h, C - 4, h), Color(0.40, 0.33, 0.20, 0.95), true)
			Art.dot(self, Vector2(cr.position.x + 5, cr.end.y - 3 - h * 0.5), 1.6, Color(0.55, 0.45, 0.28))
			Art.dot(self, Vector2(cr.position.x + 11, cr.end.y - 4 - h * 0.3), 1.3, Color(0.30, 0.38, 0.18))

# ------------------------------------------------------------------ brood, waste, dropped food
func _draw_brood() -> void:
	for b in colony.brood:
		if b.in_transit:
			continue
		var cr := _cell_rect(b.cell())
		var c := cr.get_center()
		match b.stage:
			Brood.Stage.EGG:
				draw_set_transform(c, 0.0, Vector2(1.0, 1.4))
				Art.dot(self, Vector2.ZERO, 2.6, Color(0.98, 0.98, 0.92))
				draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
			Brood.Stage.LARVA:
				var col := Color(0.97, 0.93, 0.78).lerp(Color(0.85, 0.55, 0.45), 1.0 - clampf(b.fed * 2.0, 0.0, 1.0))
				var pulse := 1.0 + 0.08 * sin(colony.time * 4.0 + b.uid)
				Art.dot(self, c + Vector2(-3, 1), 2.6 * pulse, col)
				Art.dot(self, c + Vector2(0, 2), 3.0 * pulse, col)
				Art.dot(self, c + Vector2(3, 0), 2.4 * pulse, col)
				if b.fed < Config.FEED_THRESHOLD and b.room != null:
					Art.dot(self, c + Vector2(0, -6), 1.8, Color(1.0, 0.25, 0.2))
			Brood.Stage.PUPA:
				draw_set_transform(c, 0.0, Vector2(1.5, 1.0))
				Art.dot(self, Vector2.ZERO, 3.2, Color(0.80, 0.68, 0.45))
				Art.dot(self, Vector2.ZERO, 1.8, Color(0.88, 0.78, 0.55))
				draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		if b.caste == Brood.Caste.SOLDIER:
			Art.dot(self, c + Vector2(5, 5), 1.7, Config.COL_GUARD)

func _draw_waste() -> void:
	for w in colony.waste_items:
		var c := _cell_rect(w.cell).get_center() + Vector2(float((w.cell.x * 7) % 5) - 2.0, float((w.cell.y * 5) % 5) - 2.0)
		if w.kind == WasteItem.Kind.CORPSE:
			Art.dot(self, c, 2.6, Color(0.30, 0.28, 0.28))
			Art.dot(self, c + Vector2(3, 0), 1.7, Color(0.30, 0.28, 0.28))
			draw_line(c + Vector2(-2, 2), c + Vector2(2, 3), Color(0.3, 0.28, 0.28), 1.0)
		else:
			Art.dot(self, c, 2.0, Color(0.42, 0.34, 0.20))
			Art.dot(self, c + Vector2(1.5, -1), 1.0, Color(0.30, 0.40, 0.18))
	for k: Vector3i in colony.dropped.keys():
		var cr := _cell_rect(Vector2i(k.x, k.y))
		var fc: Color = Config.FOOD_COL[k.z]
		var n := clampi(roundi(float(colony.dropped[k]) / 1.0) + 1, 1, 6)
		for i in n:
			Art.dot(self, Vector2(cr.position.x + 3.0 + i * 2.2, cr.end.y - 3.0 - float(i % 2)), 1.7, fc)

func _draw_mounds() -> void:
	var ground := float(Config.FIRST_SOIL_ROW * C)
	for ex: int in colony.mounds.keys():
		var n := float(colony.mounds[ex])
		var cx := (ex + 2.6) * C
		var w := minf(8.0 + 3.0 * sqrt(n), 46.0)
		var h := minf(2.0 + 1.5 * sqrt(n), 15.0)
		Art.hill(self, cx, ground, w, h, Color(0.47, 0.33, 0.21))
		Art.hill(self, cx + w * 0.05, ground, w * 0.55, h * 0.6, Color(0.56, 0.40, 0.26))
	for ex: int in colony.middens.keys():
		var n := float(colony.middens[ex])
		var cx := (ex - 3.2) * C
		var w := minf(6.0 + 2.2 * sqrt(n), 34.0)
		var h := minf(1.5 + 1.1 * sqrt(n), 11.0)
		Art.hill(self, cx, ground, w, h, Color(0.36, 0.34, 0.22))
		Art.dot(self, Vector2(cx - w * 0.3, ground - h * 0.4), 1.4, Color(0.27, 0.36, 0.17))
		Art.dot(self, Vector2(cx + w * 0.3, ground - h * 0.3), 1.2, Color(0.25, 0.22, 0.18))

func _draw_dig_orders() -> void:
	for t: DigTask in colony.dig_tasks.values():
		var cr := _cell_rect(t.cell)
		var col := Color(1.0, 0.78, 0.2, 0.9) if t.claimed_by != null else Color(1.0, 0.6, 0.15, 0.55)
		draw_rect(cr.grow(-2), Color(1.0, 0.7, 0.2, 0.10 + 0.25 * t.progress), true)
		draw_rect(cr.grow(-2), col, false, 1.0)
		if t.progress > 0.0:
			draw_line(cr.position + Vector2(3, 3), cr.end - Vector2(3, 3), Color(0, 0, 0, 0.5), 1.0)

# ------------------------------------------------------------------ pheromones & climate
@warning_ignore("integer_division")
func _draw_phero() -> void:
	var w := Config.GRID_W
	var layer_col: Array[Color] = [Color(1.0, 0.85, 0.15), Color(1.0, 0.25, 0.55)]
	for li in colony.trails.size():
		var ph := colony.trails[li]
		var base := layer_col[li]
		for i in colony.grid.walk_idx:
			var v := ph.a[i]
			if v > 0.02:
				var c := Vector2i(i % w, i / w)
				var t := clampf(v / Config.PHERO_MAX, 0.0, 1.0)
				var r := _cell_rect(c)
				if li == 0:
					draw_rect(Rect2(r.position.x, r.position.y, C, C * 0.5), Color(base.r, base.g, base.b, 0.15 + 0.55 * t), true)
				else:
					draw_rect(Rect2(r.position.x, r.position.y + C * 0.5, C, C * 0.5), Color(base.r, base.g, base.b, 0.15 + 0.55 * t), true)
	var al := colony.alarm
	for i in colony.grid.walk_idx:
		var v := al.a[i]
		if v > 0.05:
			var c := Vector2i(i % w, i / w)
			var t := clampf(v / al.max_value, 0.0, 1.0)
			draw_rect(_cell_rect(c), Color(1.0, 0.1, 0.05, 0.2 + 0.5 * t), true)

func _heat_color(temp: float) -> Color:
	var t := clampf((temp - 14.0) / 20.0, 0.0, 1.0)
	return Color.from_hsv(0.62 * (1.0 - t), 0.75, 0.95)

## Climate colours come from the field image; only the labels are drawn here.
func _draw_climate_labels() -> void:
	var top_y := Config.FIRST_SOIL_ROW
	for y in range(top_y, Config.GRID_H):
		var temp := Climate.temp(y, colony.time)
		if (y - top_y) % 4 == 0:
			_text(Vector2(Config.GRID_W * C - 112, y * C + 12), "%.1f C  %d%% humid" % [temp, roundi(Climate.humidity(y) * 100.0)], 10, Color(1, 1, 1))
	_text(Vector2(Config.GRID_W * C - 470, top_y * C + 30), "CLIMATE: tint = temperature (blue cold, red hot); green cells = good for brood", 10, Color(1, 1, 0.8))

# ------------------------------------------------------------------ top layer
func _draw_top() -> void:
	_draw_fx()
	if colony.raining:
		_draw_rain()
	if main == null:
		return
	if main.ghost_visible:
		var px := _rect_px(main.ghost_rect)
		var ok: bool = main.ghost_ok
		var col: Color = ROOM_COL[main.ghost_type] if ok else Color(1.0, 0.25, 0.2)
		draw_rect(px, Color(col.r, col.g, col.b, 0.28), true)
		var gart: Texture2D = _art.get(main.ghost_type)
		if gart != null and ok:
			_draw_art(gart, px, GHOST_ART_ALPHA)
		draw_rect(px, Color(col.r, col.g, col.b, 0.95), false, 2.0)
		var msg: String = Room.type_name(main.ghost_type) + (" - click to dig" if ok else " - " + str(main.ghost_msg))
		_text(px.position + Vector2(0, -5), msg, 11, Color(1, 1, 1))
	elif main.hover_visible:
		var cr := _cell_rect(main.hover_cell)
		var ok: bool = main.hover_ok
		draw_rect(cr, Color(1.0, 0.8, 0.3, 0.25) if ok else Color(1.0, 0.3, 0.2, 0.18), true)
		draw_rect(cr, Color(1.0, 0.85, 0.4, 0.9) if ok else Color(1.0, 0.35, 0.25, 0.7), false, 1.0)

func _draw_fx() -> void:
	for e in colony.fx:
		var k: float = e["t"] / e["life"]
		var p: Vector2 = e["p"]
		match e["kind"]:
			"dust":
				for i in 4:
					var a := float(i) * 1.7 + p.x
					Art.dot(self, p + Vector2(cos(a), sin(a)) * (3.0 + 7.0 * k), 2.4 * (1.0 - k), Color(0.65, 0.5, 0.35, 0.7 * (1.0 - k)))
			"heart":
				_text(p + Vector2(-3, -10.0 * k), "+", 11, Color(1.0, 0.5, 0.75, 1.0 - k))
			"text":
				_text(p + Vector2(-4, -12.0 * k), String(e["text"]), 10, Color(1.0, 0.95, 0.5, 1.0 - k))
			"skull":
				_text(p + Vector2(-4, -14.0 * k), "x", 13, Color(1.0, 0.2, 0.2, 1.0 - k))
			"puff":
				Art.dot(self, p, 3.0 + 6.0 * k, Color(0.8, 0.8, 0.8, 0.45 * (1.0 - k)))
			"alert":
				_text(p + Vector2(-2, -4.0 * sin(k * PI)), "!", 13, Color(1.0, 0.25, 0.2, 1.0 - k * 0.6))
			"egg", "pop":
				Art.ring(self, p, 3.0 + 9.0 * k, Color(1.0, 0.95, 0.6, 0.9 * (1.0 - k)), 1.5, 12)
			"spark":
				var a2 := p.x * 3.0
				draw_line(p, p + Vector2(cos(a2), sin(a2)) * 8.0 * k, Color(1.0, 0.9, 0.5, 1.0 - k), 1.5)

## Rain streaks over the sky band: a fixed number (cheap, no nodes created).
func _draw_rain() -> void:
	var n := int(30 + 50 * colony.rain_intensity)
	var ground := float(Config.FIRST_SOIL_ROW * C)
	var t := colony.time
	var col := Color(0.70, 0.80, 1.0, 0.45)
	for i in n:
		var x := fposmod(float(i) * 97.3 + t * 40.0, float(Config.GRID_W * C))
		var y := fposmod(float(i) * 53.1 + t * 420.0, ground)
		draw_line(Vector2(x, y), Vector2(x - 2.0, y + 9.0), col, 1.0)
