class_name SoilGrid
extends Node2D
## Side-view cross-section: sky, grass, soil and dug tunnels on a 80x45 grid (16 px cells).
## Owns the A* graph (walkable = TUNNEL cells + the surface row) and the baked ground texture.

enum Cell { AIR, SOIL, TUNNEL }

signal cell_dug(cell: Vector2i)

const W := Config.GRID_W
const H := Config.GRID_H
const C := Config.CELL
const N4: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

var cells := PackedByteArray()
var walk := PackedByteArray()          # 1 where walkable (fast lookup for pheromone diffusion)
var walk_idx := PackedInt32Array()     # indices of every walkable cell
var astar := AStarGrid2D.new()

var _image: Image
var _texture: ImageTexture
var _dirty := false
var _soil_tiles: Array = []            # [band][variant] -> Image
var _tunnel_tiles: Array[Image] = []
var _sky_tiles: Array[Image] = []
var _grass_top: Array[Image] = []
var _surface_tile: Image
var _sky_art: Image = null             # assets/backgrounds/sky_surface.png tiled to the map width (null = procedural sky)
const SKY_PATH := "res://assets/backgrounds/sky_surface.png"
var _rng := RandomNumberGenerator.new()

func setup() -> void:
	_rng.seed = 20261011
	cells.resize(W * H)
	walk.resize(W * H)
	for y in H:
		for x in W:
			cells[y * W + x] = Cell.AIR if y < Config.FIRST_SOIL_ROW else Cell.SOIL
	_carve_start_nest()
	_rebuild_walk()
	_setup_astar()
	_make_tiles()
	_image = Image.create(W * C, H * C, false, Image.FORMAT_RGBA8)
	for y in H:
		for x in W:
			_paint_cell(Vector2i(x, y))
	_paint_decor()
	_texture = ImageTexture.create_from_image(_image)
	queue_redraw()

func _process(_delta: float) -> void:
	if _dirty:
		_dirty = false
		_texture.update(_image)   # at most once per frame, only after a dig

func _draw() -> void:
	if _texture:
		draw_texture(_texture, Vector2.ZERO)

# ------------------------------------------------------------------ queries
static func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < W and c.y < H

func get_cell(c: Vector2i) -> int:
	if not in_bounds(c):
		return Cell.SOIL
	return cells[c.y * W + c.x]

func is_walkable(c: Vector2i) -> bool:
	if not in_bounds(c):
		return false
	return walk[c.y * W + c.x] == 1

func is_diggable(c: Vector2i) -> bool:
	return c.x >= Config.DIG_MIN_X and c.x <= Config.DIG_MAX_X \
		and c.y >= Config.FIRST_SOIL_ROW and c.y <= Config.DIG_MAX_Y

func has_open_neighbor(c: Vector2i) -> bool:
	for d in N4:
		if is_walkable(c + d):
			return true
	return false

func cell_center(c: Vector2i) -> Vector2:
	return Vector2(c.x * C + C * 0.5, c.y * C + C * 0.5)

## Where an ant stands in a cell (a little lower on the surface so it touches the grass).
func stand_pos(c: Vector2i) -> Vector2:
	var p := cell_center(c)
	if c.y == Config.SURFACE_ROW:
		p.y += 3.0
	return p

static func world_to_cell(p: Vector2) -> Vector2i:
	return Vector2i(clampi(floori(p.x / C), 0, W - 1), clampi(floori(p.y / C), 0, H - 1))

func find_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var res: Array[Vector2i] = []
	if not is_walkable(from) or not is_walkable(to):
		return res
	var p: Array[Vector2i] = astar.get_id_path(from, to)
	return p

## Surface cells that sit right above an open shaft cell.
func entrances() -> Array[Vector2i]:
	var res: Array[Vector2i] = []
	for x in W:
		if cells[Config.FIRST_SOIL_ROW * W + x] == Cell.TUNNEL:
			res.append(Vector2i(x, Config.SURFACE_ROW))
	return res

# ------------------------------------------------------------------ digging
func dig(c: Vector2i) -> bool:
	if not is_diggable(c) or get_cell(c) != Cell.SOIL:
		return false
	cells[c.y * W + c.x] = Cell.TUNNEL
	walk[c.y * W + c.x] = 1
	walk_idx.append(c.y * W + c.x)
	astar.set_point_solid(c, false)
	_paint_cell(c)
	for d in N4:
		if in_bounds(c + d):
			_paint_cell(c + d)
	_dirty = true
	cell_dug.emit(c)
	return true

## Replace the whole map (loading a save).
func load_cells(data: PackedByteArray) -> void:
	cells = data.duplicate()
	_rebuild_walk()
	for y in H:
		for x in W:
			astar.set_point_solid(Vector2i(x, y), walk[y * W + x] == 0)
			_paint_cell(Vector2i(x, y))
	_paint_decor()
	_dirty = true

# ------------------------------------------------------------------ setup helpers
func _carve_rect(r: Rect2i) -> void:
	for y in range(r.position.y, r.end.y):
		for x in range(r.position.x, r.end.x):
			cells[y * W + x] = Cell.TUNNEL

func _carve_start_nest() -> void:
	if not Config.classic_start:
		# v6 founding: a short entrance shaft and the small queen chamber only (below the flood rows)
		_carve_rect(Rect2i(40, 9, 1, 10))
		_carve_rect(Config.FOUND_QUEEN_RECT)
		return
	_carve_rect(Rect2i(40, 9, 1, 12))     # entrance shaft: col 40, rows 9..20
	_carve_rect(Rect2i(34, 12, 6, 1))     # tunnel west to the storage
	_carve_rect(Rect2i(29, 12, 5, 2))     # storage chamber (cols 29..33, rows 12..13)
	_carve_rect(Rect2i(41, 15, 5, 1))     # tunnel east to the nursery
	_carve_rect(Rect2i(46, 14, 5, 2))     # nursery chamber (cols 46..50, rows 14..15)
	_carve_rect(Rect2i(36, 18, 4, 1))     # small side tunnel
	_carve_rect(Rect2i(38, 21, 5, 3))     # queen chamber (cols 38..42, rows 21..23)
	_carve_rect(Rect2i(32, 18, 4, 2))     # waste chamber (cols 32..35, rows 18..19), joins the side tunnel

func _rebuild_walk() -> void:
	walk_idx.clear()
	for y in H:
		for x in W:
			var i := y * W + x
			var ok := (y == Config.SURFACE_ROW) or cells[i] == Cell.TUNNEL
			walk[i] = 1 if ok else 0
			if ok:
				walk_idx.append(i)

func _setup_astar() -> void:
	astar.region = Rect2i(0, 0, W, H)
	astar.cell_size = Vector2(1, 1)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	astar.update()
	for y in H:
		for x in W:
			if walk[y * W + x] == 0:
				astar.set_point_solid(Vector2i(x, y), true)

# ------------------------------------------------------------------ procedural art
## Loads the sky picture and fits it to the above-ground area (W*C x (SURFACE_ROW+1)*C):
## tiled horizontally, scaled only if its height does not match. Null when missing.
func _load_sky() -> Image:
	var t := Art.tex(SKY_PATH)
	if t == null:
		return null
	var src := t.get_image()
	if src == null or src.is_empty():
		return null
	if src.is_compressed():
		src.decompress()
	src.convert(Image.FORMAT_RGBA8)
	var sky_h := (Config.SURFACE_ROW + 1) * C
	if src.get_height() != sky_h:
		push_warning("sky_surface.png is %d px high, expected %d: scaling" % [src.get_height(), sky_h])
		src.resize(maxi(1, roundi(float(src.get_width()) * sky_h / src.get_height())), sky_h, Image.INTERPOLATE_BILINEAR)
	var out := Image.create(W * C, sky_h, false, Image.FORMAT_RGBA8)
	var x := 0
	while x < W * C:
		out.blit_rect(src, Rect2i(0, 0, mini(src.get_width(), W * C - x), sky_h), Vector2i(x, 0))
		x += src.get_width()
	return out

func _make_tiles() -> void:
	_sky_art = _load_sky()
	var soil_bands := [Color(0.50, 0.36, 0.23), Color(0.43, 0.30, 0.20), Color(0.36, 0.25, 0.17)]
	for b in soil_bands.size():
		var variants: Array[Image] = []
		for v in 6:
			variants.append(_soil_tile(soil_bands[b]))
		_soil_tiles.append(variants)
	for v in 4:
		_tunnel_tiles.append(_tunnel_tile())
	for y in Config.SURFACE_ROW + 1:
		var t := float(y) / float(Config.SURFACE_ROW)
		var col := Color(0.32, 0.60, 0.92).lerp(Color(0.74, 0.89, 0.97), t)
		var img := Image.create(C, C, false, Image.FORMAT_RGBA8)
		img.fill(col)
		_sky_tiles.append(img)
	# surface row: sky with grass blades along the bottom
	_surface_tile = _sky_tiles[Config.SURFACE_ROW].duplicate()
	for x in C:
		var h := _rng.randi_range(2, 6)
		for k in h:
			var shade := _rng.randf_range(-0.05, 0.05)
			_surface_tile.set_pixel(x, C - 1 - k, Color(0.25 + shade, 0.62 + shade, 0.22 + shade))
	# row 9 soil top: grass layer
	for b in 6:
		var img := (_soil_tiles[0][b] as Image).duplicate() as Image
		for x in C:
			for y in 5:
				var shade := _rng.randf_range(-0.04, 0.04)
				img.set_pixel(x, y, Color(0.20 + shade, 0.46 + shade, 0.16 + shade))
		_grass_top.append(img)

func _soil_tile(base: Color) -> Image:
	var img := Image.create(C, C, false, Image.FORMAT_RGBA8)
	for y in C:
		for x in C:
			var n := _rng.randf_range(-0.035, 0.035)
			img.set_pixel(x, y, Color(base.r + n, base.g + n * 0.9, base.b + n * 0.8))
	for k in _rng.randi_range(1, 3):
		var cx := _rng.randi_range(2, C - 3)
		var cy := _rng.randi_range(2, C - 3)
		var light := _rng.randf() < 0.5
		var col := Color(base.r + 0.14, base.g + 0.12, base.b + 0.10) if light else Color(base.r - 0.12, base.g - 0.10, base.b - 0.08)
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if absi(dx) + absi(dy) < 3:
					img.set_pixel(cx + dx, cy + dy, col)
	return img

func _tunnel_tile() -> Image:
	var img := Image.create(C, C, false, Image.FORMAT_RGBA8)
	for y in C:
		for x in C:
			var n := _rng.randf_range(-0.015, 0.015)
			img.set_pixel(x, y, Color(0.17 + n, 0.12 + n, 0.09 + n))
	return img

func _paint_cell(c: Vector2i) -> void:
	var tile: Image
	var t := get_cell(c)
	var h := (c.x * 73 + c.y * 151) % 6
	if t == Cell.AIR:
		if _sky_art != null:
			tile = _sky_art.get_region(Rect2i(c.x * C, c.y * C, C, C))
		else:
			tile = _surface_tile if c.y == Config.SURFACE_ROW else _sky_tiles[c.y]
	elif t == Cell.SOIL:
		if c.y == Config.FIRST_SOIL_ROW:
			tile = _grass_top[h]
		else:
			var band := 0 if c.y < 16 else (1 if c.y < 30 else 2)
			tile = _soil_tiles[band][h]
	else:
		tile = _tunnel_tiles[h % 4]
	_image.blit_rect(tile, Rect2i(0, 0, C, C), Vector2i(c.x * C, c.y * C))
	if t == Cell.TUNNEL:
		var rim := Color(0.60, 0.44, 0.30)
		var o := Vector2i(c.x * C, c.y * C)
		if get_cell(c + Vector2i(0, -1)) == Cell.SOIL:
			_image.fill_rect(Rect2i(o.x, o.y, C, 1), rim)
		if get_cell(c + Vector2i(0, 1)) == Cell.SOIL:
			_image.fill_rect(Rect2i(o.x, o.y + C - 1, C, 1), Color(0.10, 0.07, 0.05))
		if get_cell(c + Vector2i(-1, 0)) == Cell.SOIL:
			_image.fill_rect(Rect2i(o.x, o.y, 1, C), rim)
		if get_cell(c + Vector2i(1, 0)) == Cell.SOIL:
			_image.fill_rect(Rect2i(o.x + C - 1, o.y, 1, C), rim)

func _blob(cx: int, cy: int, rx: int, ry: int, col: Color) -> void:
	for y in range(cy - ry, cy + ry + 1):
		for x in range(cx - rx, cx + rx + 1):
			if x < 0 or y < 0 or x >= W * C or y >= Config.SURFACE_ROW * C:
				continue
			var dx := float(x - cx) / rx
			var dy := float(y - cy) / ry
			if dx * dx + dy * dy <= 1.0:
				var base := _image.get_pixel(x, y)
				_image.set_pixel(x, y, base.lerp(Color(col.r, col.g, col.b), col.a))

func _paint_decor() -> void:
	_blob(1190, 40, 20, 20, Color(1.0, 0.95, 0.6, 0.95))
	if _sky_art != null:
		return                          # the sky picture already has clouds, hills and grass
	for cl in [[150, 36], [520, 22], [820, 50], [1010, 28]]:
		var cx: int = cl[0]
		var cy: int = cl[1]
		_blob(cx, cy, 30, 9, Color(1, 1, 1, 0.55))
		_blob(cx - 16, cy - 5, 14, 9, Color(1, 1, 1, 0.55))
		_blob(cx + 12, cy - 7, 16, 10, Color(1, 1, 1, 0.55))
