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
