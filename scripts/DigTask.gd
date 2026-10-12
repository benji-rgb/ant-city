class_name DigTask
extends RefCounted
## A pending order to turn one SOIL cell into TUNNEL.

var cell: Vector2i = Vector2i.ZERO
var room: Room = null           # set when the cell belongs to a planned chamber
var claimed_by: Ant = null
var progress: float = 0.0       # 0..1 while a worker digs (for the visual crack)
var blocked_until: float = 0.0  # sim time; set when no path could be found
