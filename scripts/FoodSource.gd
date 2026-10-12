class_name FoodSource
extends Node2D
## A finite food pile on the surface. Never freed: when empty it hides, waits, and
## re-appears at a new random surface cell, so nobody holds a dangling reference.

const TEX := preload("res://assets/food_pile.png")

var col: int = 0
var amount: float = 40.0
var max_amount: float = 40.0
var active: bool = true
var respawn_t: float = 0.0
var colony: Colony
var type: int = Config.Food.SUGAR
var pickups := 0               # trips served since the last relocation (diagnostics)

func setup(c: Colony, column: int, amt: float, food_type := 0) -> void:
	colony = c
	type = food_type
	relocate(column, amt)

func relocate(column: int, amt: float) -> void:
	col = column
	pickups = 0
	amount = amt
	max_amount = amt
	active = true
	position = Vector2(col * Config.CELL + Config.CELL * 0.5, Config.FIRST_SOIL_ROW * Config.CELL)
	queue_redraw()

func richness() -> float:
	return clampf(amount / maxf(max_amount, 0.001), 0.0, 1.0)

func take(requested: float) -> float:
	if not active:
		return 0.0
	var got := minf(requested, amount)
	pickups += 1
	amount -= got
	if amount <= 0.01:
		amount = 0.0
		active = false
		respawn_t = Config.FOOD_RESPAWN
	queue_redraw()
	return got

func give_back(x: float) -> void:
	if active:
		amount += x
		queue_redraw()

func step(dt: float) -> void:
	if active:
		return
	respawn_t -= dt
	if respawn_t <= 0.0:
		var c := colony.pick_food_column(self)
		relocate(c, randf_range(Config.FOOD_AMOUNT_MIN, Config.FOOD_AMOUNT_MAX))

func _draw() -> void:
	if not active:
		return
	var r := 0.35 + 0.65 * clampf(amount / Config.FOOD_AMOUNT_MAX, 0.0, 1.0)
	var wpx := 40.0 * r + 12.0
	var hpx := wpx * float(TEX.get_height()) / float(TEX.get_width())
	draw_texture_rect(TEX, Rect2(-wpx * 0.5, -hpx + 2.0, wpx, hpx), false, Color(1.0, 0.95, 0.62) if type == Config.Food.SUGAR else Color(1.0, 0.62, 0.62))
	var font := ThemeDB.fallback_font
	var tcol: Color = Config.FOOD_COL[type]
	draw_circle(Vector2(0, 1.0), 2.6, tcol)        # small type marker on the ground
	var txt := "%d" % int(ceil(amount))
	var tp := Vector2(-8.0, -hpx - 2.0)
	draw_string(font, tp + Vector2(1, 1), txt, HORIZONTAL_ALIGNMENT_CENTER, 16.0, 11, Color(0, 0, 0, 0.7))
	draw_string(font, tp, txt, HORIZONTAL_ALIGNMENT_CENTER, 16.0, 11, tcol.lightened(0.5))
