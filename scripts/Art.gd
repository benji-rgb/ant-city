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

# ------------------------------------------------------------------ cheap shapes (web / ANGLE)
## v7: in Godot 4.3's Compatibility renderer every draw_colored_polygon / draw_polyline /
## draw_multiline / draw_arc / draw_circle builds a polygon with its OWN GL vertex buffers, created
## and destroyed on every redraw. With ~40 ants redrawn each frame that was ~1300 glCreateBuffer +
## glDeleteBuffer per second - the prime suspect for Chrome/ANGLE (D3D11) dropping the context.
## Rects, lines and textured quads are batched into shared buffers instead, so all per-frame
## shapes use those: a dot is a quad with a cached circle texture, polylines are draw_line segments.
static var _dot_tex: Texture2D

static func dot_texture() -> Texture2D:
	if _dot_tex == null:
		var n := 32
		var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
		var c := (n - 1) * 0.5
		for y in n:
			for x in n:
				var d := Vector2(x - c, y - c).length()
				img.set_pixel(x, y, Color(1, 1, 1, clampf(c + 0.5 - d, 0.0, 1.0)))
		_dot_tex = ImageTexture.create_from_image(img)     # created once for the whole game
	return _dot_tex

static func dot(ci: CanvasItem, p: Vector2, r: float, col: Color) -> void:
	if not (r > 0.05) or not p.is_finite():
		return
	if r < 0.9:
		ci.draw_rect(Rect2(p - Vector2(r, r), Vector2(r, r) * 2.0), col, true)
		return
	ci.draw_texture_rect(dot_texture(), Rect2(p - Vector2(r, r), Vector2(r, r) * 2.0), false, col)

static func lines(ci: CanvasItem, pts: PackedVector2Array, col: Color, w: float) -> void:
	for i in pts.size() - 1:
		ci.draw_line(pts[i], pts[i + 1], col, w)

static func ring(ci: CanvasItem, p: Vector2, r: float, col: Color, w: float, segs := 16) -> void:
	var prev := p + Vector2(r, 0)
	for i in range(1, segs + 1):
		var a := TAU * float(i) / float(segs)
		var q := p + Vector2(cos(a), sin(a)) * r
		ci.draw_line(prev, q, col, w)
		prev = q

## A soft hill made of stacked rects (no polygon buffers).
static func hill(ci: CanvasItem, cx: float, ground: float, w: float, h: float, col: Color) -> void:
	var rows := maxi(1, int(ceil(h / 2.0)))
	for k in rows:
		var t := float(k) / float(rows)
		var hw := w * sqrt(maxf(0.0, 1.0 - t * t))
		ci.draw_rect(Rect2(cx - hw, ground + 1.0 - (k + 1) * (h / rows), hw * 2.0, h / rows + 0.5), col, true)
