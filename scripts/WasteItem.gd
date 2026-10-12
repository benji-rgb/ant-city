class_name WasteItem
extends RefCounted
## A corpse or a refuse pellet lying in the nest until a cleaner carries it away.

enum Kind { REFUSE, CORPSE }

var cell: Vector2i = Vector2i.ZERO
var kind: int = Kind.REFUSE
var units: float = 1.0
var claimed_by: Ant = null
