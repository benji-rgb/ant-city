class_name Brood
extends RefCounted
## One individual egg / larva / pupa. It either sits in a nursery slot, lies "loose" somewhere
## (e.g. a freshly laid egg in the queen chamber) or is being carried by a nurse.

enum Stage { EGG, LARVA, PUPA }
enum Caste { WORKER, SOLDIER, GYNE }

var uid: int = 0
var stage: int = Stage.EGG
var caste: int = Caste.WORKER
var t: float = 0.0            # progress inside the current stage
var fed: float = 0.8          # larvae: 1 = full, 0 = starving
var starve_t: float = 0.0
var slot: int = 0
var loose_cell: Vector2i = Vector2i.ZERO     # location while room == null
var claimed_by: Ant = null    # nurse that is going to feed this larva
var carried_by: Ant = null    # nurse that is moving it (also set while still walking to it)
var in_transit: bool = false  # picked up and on the way
var dest_slot: int = -1
var move_ready: float = 0.0   # sim time after which it may be relocated again
var dead: bool = false

# Rooms are referenced weakly: Room.slots holds the brood, so a strong back-reference would be a cycle.
var _room: WeakRef = null
var _dest: WeakRef = null

var room: Room:
	get: return _room.get_ref() as Room if _room != null else null
	set(v): _room = weakref(v) if v != null else null

var dest_room: Room:
	get: return _dest.get_ref() as Room if _dest != null else null
	set(v): _dest = weakref(v) if v != null else null

func cell() -> Vector2i:
	var r := room
	if r != null:
		return r.slot_cell(slot)
	return loose_cell

func is_loose() -> bool:
	return room == null and not in_transit

func stage_name() -> String:
	var n: String = ["Egg", "Larva", "Pupa"][stage]
	return n if caste == Caste.WORKER else n + " (soldier)"
