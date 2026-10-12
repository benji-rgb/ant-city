class_name SaveGame
extends RefCounted
## Save / load the whole colony as JSON in user://. Transient behaviour (paths, claims, what an
## ant was about to do) is not stored: ants wake up idle at their cell and re-decide, brood that
## was being carried is stored lying where its carrier stood. Everything that matters to the
## simulation (map, chambers, food, brood, ants, pheromones, waste, threats timers) is kept.

const VERSION := 3
const DEFAULT_PATH := "user://ant_city_save.json"
const AUTO_PATH := "user://ant_city_autosave.json"   # v5: periodic autosave (web: survives a lost WebGL context)

## The newer of the manual save and the autosave ("" when there is none).
static func newest_path() -> String:
	var best := ""
	var best_t := -1
	for p in [DEFAULT_PATH, AUTO_PATH]:
		if FileAccess.file_exists(p):
			var t := FileAccess.get_modified_time(p)
			if t > best_t:
				best_t = t
				best = p
	return best

static func _f32(a: PackedFloat32Array) -> String:
	return Marshalls.raw_to_base64(a.to_byte_array())

static func _unf32(s: String) -> PackedFloat32Array:
	return Marshalls.base64_to_raw(s).to_float32_array()

static func _v2(c: Vector2i) -> Array:
	return [c.x, c.y]

static func _c(a: Array) -> Vector2i:
	return Vector2i(int(a[0]), int(a[1]))

# ------------------------------------------------------------------ save
static func to_dict(col: Colony) -> Dictionary:
	var d := {}
	d["version"] = VERSION
	d["time"] = col.time
	d["lay_timer"] = col.lay_timer
	d["soldier_mode"] = col.soldier_mode
	d["threat_level"] = Config.threat_level
	d["next_uid"] = col.next_uid
	d["last_threat_t"] = col.last_threat_t
	d["threat_count"] = col.threat_count
	d["stats"] = {
		"born": col.total_born, "deaths": col.total_deaths, "foraged": col.total_foraged, "laid": col.total_laid,
		"dug": col.total_dug, "starved_larvae": col.starved_larvae, "diseased": col.diseased_brood,
		"waste_disposed": col.waste_disposed, "threats_killed": col.threats_killed, "brood_moved": col.brood_moved,
		"dropped_total": col.food_dropped_total}
	d["cells"] = Marshalls.raw_to_base64(col.grid.cells)
	var room_idx := {}
	var rooms: Array = []
	for i in col.rooms.size():
		var r: Room = col.rooms[i]
		room_idx[r] = i
		rooms.append({"type": r.type, "rect": [r.rect.position.x, r.rect.position.y, r.rect.size.x, r.rect.size.y],
			"active": r.active, "undug": r.undug, "sugar": r.sugar, "protein": r.protein, "waste": r.waste})
	d["rooms"] = rooms
	d["queen_room"] = room_idx.get(col.queen_room, 0)
	var brood: Array = []
	for b in col.brood:
		var ri := -1
		var lc := b.loose_cell
		if b.in_transit and b.carried_by != null and is_instance_valid(b.carried_by):
			lc = (b.carried_by as Ant).cell
		elif b.room != null:
			ri = room_idx.get(b.room, -1)
		brood.append({"uid": b.uid, "stage": b.stage, "caste": b.caste, "t": b.t, "fed": b.fed, "starve": b.starve_t,
			"room": ri, "slot": b.slot, "loose": _v2(lc), "ready": b.move_ready})
	d["brood"] = brood
	var ants: Array = []
	var waste: Array = []
	for w in col.waste_items:
		waste.append([w.cell.x, w.cell.y, w.kind, w.units])
	for a in col.ants:
		if a.carrying_waste and a.waste_item != null:
			waste.append([a.cell.x, a.cell.y, a.waste_item.kind, a.waste_item.units])
		ants.append({"cell": _v2(a.cell), "age": a.age, "life": a.lifespan, "hp": a.hp, "hunger": a.hunger,
			"task": a.task, "caste": a.caste, "cf": a.carry_food, "ct": a.carry_type, "cn": a.carry_nurse, "soil": a.soil, "out": a.out_t, "fs": a.fill_soil})
	d["ants"] = ants
	d["waste"] = waste
	d["queen"] = {"cell": _v2(col.queen.cell), "hunger": col.queen.hunger}
	var foods: Array = []
	for f in col.foods:
		foods.append({"col": f.col, "amount": f.amount, "max": f.max_amount, "active": f.active, "respawn": f.respawn_t,
			"type": f.type, "pickups": f.pickups})
	d["foods"] = foods
	d["trails"] = [_f32(col.trails[0].a), _f32(col.trails[1].a)]
	d["alarm"] = _f32(col.alarm.a)
	d["home"] = _f32(col.home.a)                 # v5 (optional on load)
	d["flood"] = _f32(col.flood)
	d["rain"] = {"on": col.raining, "i": col.rain_intensity, "left": col.rain_left, "t": col._rain_t,
		"n": col.rain_count, "wet": Climate.wet}
	d["v5"] = {"homing_ok": col.homing_ok, "homing_fallback": col.homing_fallback, "soil_hauled": col.soil_hauled,
		"soil_lost": col.soil_lost, "raids": col.raids, "food_stolen": col.food_stolen, "brood_stolen": col.brood_stolen,
		"intruders_killed": col.intruders_killed, "flood_peak": col.flood_peak, "flood_deaths": col.flood_deaths}
	var fills: Array = []
	for t: DigTask in col.fill_tasks.values():
		fills.append(_v2(t.cell))
	d["v8"] = {"work_prio": col.work_prio.duplicate(), "caste_manual": col.caste_manual, "caste_w": col.caste_w.duplicate(),
		"standing_order": col.standing_order, "active_order": col.active_order, "flights": col.flights,
		"gynes_flown": col.gynes_flown, "score": col.score, "fills": fills, "total_filled": col.total_filled,
		"soil_used": col.soil_used, "mound_used": col.mound_used}
	var dig: Array = []
	for t: DigTask in col.dig_tasks.values():
		dig.append({"cell": _v2(t.cell), "room": room_idx.get(t.room, -1) if t.room != null else -1})
	d["dig"] = dig
	var dropped: Array = []
	for k: Vector3i in col.dropped.keys():
		dropped.append([k.x, k.y, k.z, col.dropped[k]])
	d["dropped"] = dropped
	var mounds := {}
	for k in col.mounds:
		mounds[str(k)] = col.mounds[k]
	d["mounds"] = mounds
	var middens := {}
	for k in col.middens:
		middens[str(k)] = col.middens[k]
	d["middens"] = middens
	d["events"] = col.events.slice(maxi(0, col.events.size() - 20))
	return d

static func save(col: Colony, path := DEFAULT_PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(to_dict(col)))
	f.close()
	return true

static func exists(path := DEFAULT_PATH) -> bool:
	return FileAccess.file_exists(path)

# ------------------------------------------------------------------ load
static func load_file(col: Colony, path := DEFAULT_PATH) -> String:
	if not FileAccess.file_exists(path):
		return "No save file yet (press K to save)."
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return "Could not open the save file."
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return "The save file is damaged."
	var d: Dictionary = parsed
	if int(d.get("version", 0)) != VERSION:
		return "Save file has version %s, expected %d." % [str(d.get("version", "?")), VERSION]
	return apply(col, d)

static func apply(col: Colony, d: Dictionary) -> String:
	# validate the essentials first so a bad file does not leave a half-cleared colony
	for key in ["cells", "rooms", "ants", "brood", "foods", "trails", "alarm", "queen"]:
		if not d.has(key):
			return "Save file is missing '%s'." % key
	var cells := Marshalls.base64_to_raw(String(d["cells"]))
	if cells.size() != Config.GRID_W * Config.GRID_H:
		return "Save file has a map of the wrong size."
	var tr: Array = d["trails"]
	var n := Config.GRID_W * Config.GRID_H
	if tr.size() != 2 or _unf32(String(tr[0])).size() != n or _unf32(String(tr[1])).size() != n \
			or _unf32(String(d["alarm"])).size() != n:
		return "Save file has damaged pheromone data."
	col.clear_world()
	col.grid.load_cells(cells)
	col.time = float(d.get("time", 0.0))
	col.lay_timer = float(d.get("lay_timer", 5.0))
	col.soldier_mode = int(d.get("soldier_mode", 0))
	Config.threat_level = clampi(int(d.get("threat_level", 1)), 0, 2)
	col.next_uid = int(d.get("next_uid", 1))
	col.last_threat_t = float(d.get("last_threat_t", -9999.0))
	col.threat_count = int(d.get("threat_count", 0))
	var st: Dictionary = d.get("stats", {})
	col.total_born = int(st.get("born", 0))
	col.total_deaths = int(st.get("deaths", 0))
	col.total_foraged = float(st.get("foraged", 0.0))
	col.total_laid = int(st.get("laid", 0))
	col.total_dug = int(st.get("dug", 0))
	col.starved_larvae = int(st.get("starved_larvae", 0))
	col.diseased_brood = int(st.get("diseased", 0))
	col.waste_disposed = int(st.get("waste_disposed", 0))
	col.threats_killed = int(st.get("threats_killed", 0))
	col.brood_moved = int(st.get("brood_moved", 0))
	col.food_dropped_total = float(st.get("dropped_total", 0.0))
	# rooms
	for rd in d["rooms"]:
		var r := Room.new()
		r.type = int(rd["type"])
		var a: Array = rd["rect"]
		r.rect = Rect2i(int(a[0]), int(a[1]), int(a[2]), int(a[3]))
		r.undug = int(rd["undug"])
		r.sugar = float(rd["sugar"])
		r.protein = float(rd["protein"])
		r.waste = float(rd["waste"])
		if bool(rd["active"]):
			r.activate()
		col.rooms.append(r)
	col.queen_room = col.rooms[clampi(int(d.get("queen_room", 0)), 0, col.rooms.size() - 1)]
	# brood
	for bd in d["brood"]:
		var b := Brood.new()
		b.uid = int(bd["uid"])
		b.stage = int(bd["stage"])
		b.caste = int(bd["caste"])
		b.t = float(bd["t"])
		b.fed = float(bd["fed"])
		b.starve_t = float(bd["starve"])
		b.move_ready = float(bd["ready"])
		b.loose_cell = _c(bd["loose"])
		var ri := int(bd["room"])
		if ri >= 0 and ri < col.rooms.size():
			var r: Room = col.rooms[ri]
			var s := int(bd["slot"])
			if r.active and s >= 0 and s < r.slots.size() and r.slots[s] == null:
				r.slots[s] = b
				b.room = r
				b.slot = s
			else:
				b.loose_cell = r.random_cell()
		col.brood.append(b)
	# ants
	var q: Dictionary = d["queen"]
	var queen := Ant.new()
	col.ant_container.add_child(queen)
	queen.setup(col, _c(q["cell"]), Ant.Caste.WORKER, true)
	queen.lifespan = 1e9
	queen.hunger = float(q["hunger"])
	col.queen = queen
	for ad in d["ants"]:
		var a := Ant.new()
		col.ant_container.add_child(a)
		a.setup(col, _c(ad["cell"]), int(ad["caste"]))
		a.age = float(ad["age"])
		a.lifespan = float(ad["life"])
		a.hp = float(ad["hp"])
		a.hunger = float(ad["hunger"])
		a.task = int(ad["task"])
		a.carry_food = float(ad["cf"])
		a.carry_type = int(ad["ct"])
		a.carry_nurse = float(ad["cn"])
		a.soil = int(ad.get("soil", 0))
		a.fill_soil = int(ad.get("fs", 0))
		a.out_t = float(ad.get("out", 0.0))
		col.ants.append(a)
	# surface food
	for fd in d["foods"]:
		var f := FoodSource.new()
		col.food_container.add_child(f)
		f.setup(col, int(fd["col"]), float(fd["amount"]), int(fd["type"]))
		f.max_amount = float(fd["max"])
		f.active = bool(fd["active"])
		f.respawn_t = float(fd["respawn"])
		f.pickups = int(fd["pickups"])
		col.foods.append(f)
	col.trails[0].a = _unf32(String(tr[0]))
	col.trails[1].a = _unf32(String(tr[1]))
	col.alarm.a = _unf32(String(d["alarm"]))
	if d.has("home"):
		var hm := _unf32(String(d["home"]))
		if hm.size() == col.home.a.size():
			col.home.a = hm
	if d.has("flood"):
		var fl := _unf32(String(d["flood"]))
		if fl.size() == col.flood.size():
			col.flood = fl
	var rn: Dictionary = d.get("rain", {})
	if not rn.is_empty():
		col.raining = bool(rn["on"])
		col.rain_intensity = float(rn["i"])
		col.rain_left = float(rn["left"])
		col._rain_t = float(rn["t"])
		col.rain_count = int(rn["n"])
		Climate.wet = float(rn["wet"])
	var v5: Dictionary = d.get("v5", {})
	for k in v5:
		col.set(k, v5[k])
	for dd in d.get("dig", []):
		var t := DigTask.new()
		t.cell = _c(dd["cell"])
		var ri := int(dd["room"])
		if ri >= 0 and ri < col.rooms.size():
			t.room = col.rooms[ri]
		col.dig_tasks[t.cell] = t
	# v8 (older saves: defaults)
	var v8: Dictionary = d.get("v8", {})
	col.work_prio = (v8.get("work_prio", [2, 2, 2, 2, 2]) as Array).map(func(x): return int(x))
	col.caste_manual = bool(v8.get("caste_manual", false))
	col.caste_w = (v8.get("caste_w", [6, 2, 0]) as Array).map(func(x): return int(x))
	col.standing_order = int(v8.get("standing_order", 0))
	col.active_order = int(v8.get("active_order", -1))
	col.flights = int(v8.get("flights", 0))
	col.gynes_flown = int(v8.get("gynes_flown", 0))
	col.score = int(v8.get("score", 0))
	col.total_filled = int(v8.get("total_filled", 0))
	col.soil_used = int(v8.get("soil_used", 0))
	col.mound_used = int(v8.get("mound_used", 0))
	col.fill_tasks.clear()
	for fc in v8.get("fills", []):
		var ft := DigTask.new()
		ft.cell = _c(fc)
		if col.grid.get_cell(ft.cell) == SoilGrid.Cell.TUNNEL:
			col.fill_tasks[ft.cell] = ft
	for w in d.get("waste", []):
		var item := WasteItem.new()
		item.cell = Vector2i(int(w[0]), int(w[1]))
		item.kind = int(w[2])
		item.units = float(w[3])
		col.waste_items.append(item)
	for k in d.get("dropped", []):
		col.dropped[Vector3i(int(k[0]), int(k[1]), int(k[2]))] = float(k[3])
	for k in d.get("mounds", {}):
		col.mounds[int(k)] = float(d["mounds"][k])
	for k in d.get("middens", {}):
		col.middens[int(k)] = float(d["middens"][k])
	col.events.clear()
	for e in d.get("events", []):
		col.events.append(String(e))
	col.after_load()
	return ""
