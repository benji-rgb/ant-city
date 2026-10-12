class_name PheroGrid
extends RefCounted
## A pheromone field on the same grid as the soil. Evaporates and diffuses slightly.
## Used for the sugar trail, the protein trail and the alarm signal.

var grid: SoilGrid
var a := PackedFloat32Array()
var b := PackedFloat32Array()
var evap_rate := Config.PHERO_EVAP
var diffuse := Config.PHERO_DIFFUSE
var max_value := Config.PHERO_MAX
var _acc := 0.0
var total := 0.0
var peak := 0.0

func _init(g: SoilGrid, evaporation := Config.PHERO_EVAP, diffusion := Config.PHERO_DIFFUSE, cap := Config.PHERO_MAX) -> void:
	grid = g
	evap_rate = evaporation
	diffuse = diffusion
	max_value = cap
	a.resize(SoilGrid.W * SoilGrid.H)
	b.resize(SoilGrid.W * SoilGrid.H)
	a.fill(0.0)
	b.fill(0.0)

## Called after the field was replaced from a save: restart the diffusion timer so a load is
## reproducible (the pre-load accumulator must not leak into the loaded state).
func reset_step() -> void:
	_acc = 0.0
	total = 0.0
	peak = 0.0
	for v in a:
		total += v
		peak = maxf(peak, v)

func clear() -> void:
	a.fill(0.0)
	b.fill(0.0)
	total = 0.0
	peak = 0.0

func deposit(c: Vector2i, amount: float) -> void:
	if not grid.is_walkable(c):
		return
	var i := c.y * SoilGrid.W + c.x
	a[i] = minf(a[i] + amount, max_value)

func get_at(c: Vector2i) -> float:
	if not SoilGrid.in_bounds(c):
		return 0.0
	return a[c.y * SoilGrid.W + c.x]

## Surface-row cell with the highest concentration (x = -1 if none above `min_value`).
func best_on_surface(min_value: float) -> int:
	var best := -1
	var bv := min_value
	var base := Config.SURFACE_ROW * SoilGrid.W
	for x in SoilGrid.W:
		if a[base + x] > bv:
			bv = a[base + x]
			best = x
	return best

func step(dt: float) -> void:
	_acc += dt
	if _acc < Config.PHERO_STEP:
		return
	var h := _acc
	_acc = 0.0
	var evap := exp(-evap_rate * h)
	var dif := diffuse
	var w := SoilGrid.W
	var walk := grid.walk
	var sum := 0.0
	var pk := 0.0
	for i in grid.walk_idx:
		var v := a[i]
		var n := 0
		var s := 0.0
		var x := i % w
		if x > 0 and walk[i - 1] == 1:
			n += 1
			s += a[i - 1]
		if x < w - 1 and walk[i + 1] == 1:
			n += 1
			s += a[i + 1]
		if i >= w and walk[i - w] == 1:
			n += 1
			s += a[i - w]
		if i + w < a.size() and walk[i + w] == 1:
			n += 1
			s += a[i + w]
		var nv := v
		if n > 0:
			nv = v + dif * (s / n - v)
		nv *= evap
		if nv < 0.002:
			nv = 0.0
		b[i] = nv
		sum += nv
		if nv > pk:
			pk = nv
	var tmp := a
	a = b
	b = tmp
	total = sum
	peak = pk
