class_name Art
extends RefCounted
## Guarded texture loading for the optional art assets: a missing / unloadable file yields null
## and the caller falls back to its procedural drawing.

static var _cache := {}
static var missing: Array[String] = []

static func tex(path: String) -> Texture2D:
	if _cache.has(path):
		return _cache[path]
	var t: Texture2D = null
	if ResourceLoader.exists(path):
		t = load(path) as Texture2D
	if t == null:
		missing.append(path)
	_cache[path] = t
	return t

## Sprite from assets/sprites/. Prefers the legless "_body" variant (the code animates legs and
## antennae on top); falls back to the full sprite. Returns [texture, has_own_legs].
static func sprite(name: String) -> Array:
	var b := tex("res://assets/sprites/%s_body.png" % name)
	if b != null:
		return [b, false]
	var f := tex("res://assets/sprites/%s.png" % name)
	return [f, true]

# ------------------------------------------------------------------ cheap shapes (web performance)
## Godot's draw_circle emits a ~64-segment fan per call; with hundreds of ants that was ~20k
## primitives per frame. A dot here is a 10-sided polygon (8 triangles) - same look at ant size.
const DOT_SIDES := 10
static var _unit_dot := PackedVector2Array()

static func dot(ci: CanvasItem, p: Vector2, r: float, col: Color) -> void:
	if not (r > 0.05) or not p.is_finite():
		return
	if r < 0.9:      # the polygon triangulator rejects sub-pixel polygons: a tiny square looks the same
		ci.draw_rect(Rect2(p - Vector2(r, r), Vector2(r, r) * 2.0), col, true)
		return
	if _unit_dot.is_empty():
		for i in DOT_SIDES:
			var a := TAU * float(i) / float(DOT_SIDES)
			_unit_dot.append(Vector2(cos(a), sin(a)))
	var pts := PackedVector2Array()
	pts.resize(DOT_SIDES)
	for i in DOT_SIDES:
		pts[i] = p + _unit_dot[i] * r
	ci.draw_colored_polygon(pts, col)
