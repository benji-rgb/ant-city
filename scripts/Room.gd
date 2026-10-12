class_name Room
extends RefCounted
## A chamber: a rectangle of grid cells with a function and a capacity.

enum Type { QUEEN_CHAMBER, NURSERY, FOOD_STORAGE, WASTE }

var type: int = Type.NURSERY
var rect: Rect2i = Rect2i()
var active: bool = false      # becomes true once every cell has been dug
var undug: int = 0            # cells still to dig while planned
var sugar: float = 0.0        # FOOD_STORAGE contents
var protein: float = 0.0
var waste: float = 0.0        # WASTE contents (units)
var slots: Array = []         # NURSERY: Array of Brood (or null)
var reserved: Dictionary = {} # NURSERY: slot index -> Brood that is being carried here
var quality: float = 1.0      # mean brood comfort (0..1) from the microclimate, refreshed by Colony

static func type_name(t: int) -> String:
	match t:
		Type.QUEEN_CHAMBER: return "Queen chamber"
		Type.NURSERY: return "Nursery"
		Type.WASTE: return "Waste chamber"
		_: return "Food storage"

## Name of the matching icon in assets/icons/ (also used as the chamber art key prefix).
static func icon_name(t: int) -> String:
	match t:
		Type.QUEEN_CHAMBER: return "queen_chamber"
		Type.NURSERY: return "nursery"
		Type.WASTE: return "waste_chamber"
		_: return "food_storage"

func food() -> float:
	return sugar + protein

func stock(t: int) -> float:
	return sugar if t == Config.Food.SUGAR else protein

func add_stock(t: int, amount: float) -> void:
	if t == Config.Food.SUGAR:
		sugar += amount
	else:
		protein += amount

func cell_count() -> int:
	return rect.size.x * rect.size.y

func capacity() -> float:
	match type:
		Type.FOOD_STORAGE: return cell_count() * Config.STORAGE_PER_CELL
		Type.NURSERY: return float(cell_count() * Config.BROOD_PER_CELL)
		Type.WASTE: return cell_count() * Config.WASTE_PER_CELL
		_: return 1.0

func contains(c: Vector2i) -> bool:
	return rect.has_point(c)

func activate() -> void:
	active = true
	undug = 0
	if type == Type.NURSERY and slots.is_empty():
		slots.resize(cell_count() * Config.BROOD_PER_CELL)
		for i in slots.size():
			slots[i] = null

func free_slot() -> int:
	if not active:
		return -1
	var free: Array[int] = []
	for i in slots.size():
		if slots[i] == null and not reserved.has(i):
			free.append(i)
	if free.is_empty():
		return -1
	return free[randi() % free.size()]

func free_slot_count() -> int:
	var n := 0
	for i in slots.size():
		if slots[i] == null and not reserved.has(i):
			n += 1
	return n

func brood_count() -> int:
	var n := 0
	for s in slots:
		if s != null:
			n += 1
	return n

@warning_ignore("integer_division")
func slot_cell(i: int) -> Vector2i:
	var per := Config.BROOD_PER_CELL
	var k := i / per
	return Vector2i(rect.position.x + k % rect.size.x, rect.position.y + k / rect.size.x)

func random_cell() -> Vector2i:
	return Vector2i(rect.position.x + randi() % rect.size.x, rect.position.y + randi() % rect.size.y)

func label() -> String:
	var n := Room.type_name(type)
	if not active:
		return "%s (digging %d/%d)" % [n, cell_count() - undug, cell_count()]
	match type:
		Type.FOOD_STORAGE: return "Storage S%.0f P%.0f /%.0f" % [sugar, protein, capacity()]
		Type.NURSERY: return "%s %d/%d" % [n, brood_count(), int(capacity())]
		Type.WASTE: return "%s %.0f/%.0f" % [n, waste, capacity()]
	return n

## Compact text drawn on the chamber itself (neighbouring chambers must not overlap their labels).
func short_label() -> String:
	if not active:
		return "digging %d/%d" % [cell_count() - undug, cell_count()]
	match type:
		Type.FOOD_STORAGE: return "S%.0f P%.0f" % [sugar, protein]
		Type.NURSERY: return "Nursery %d/%d" % [brood_count(), int(capacity())]
		Type.WASTE: return "Waste %.0f/%.0f" % [waste, capacity()]
	return "Queen"
