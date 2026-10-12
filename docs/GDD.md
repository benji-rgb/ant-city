# Ant City — Game Design Document (v4)

## Pillars
1. **Emergence over micromanagement.** The player sets *intent* (dig here, build a nursery / waste chamber there, how many
   soldiers, how dangerous the world is); ants decide who does what.
2. **Readable cross-section.** Everything is visible at 1280x720: tunnels, chambers, brood, food levels, who is doing which job,
   trails (P) and climate (H) on demand, an event log for what just happened.
3. **Realistic-enough ant biology.** Pheromone recruitment (per food type + alarm), age polyethism (nurse -> work inside ->
   forage), brood carried between chambers, a queen who only lays when the colony can afford it, refuse management, castes.
4. **A colony that can fail slowly.** Starvation, dirt, predators and bad planning degrade the colony over minutes, not instantly.

## Simulation model
* Fixed step `SIM_DT = 1/60 s`. Main accumulates `real_delta * speed` (1x/2x/4x; pause = no accumulation). Entities have no
  `_process`/physics; `Colony.sim_step(dt)` advances everything (trails, alarm, food piles, ants, threats, brood, laying, upkeep,
  waste, threat spawning, effects, climate cache, needs), so results are independent of frame rate (checked with dt 0.0167 / 0.033 / 0.1).
* 1 colony **day** = 60 sim seconds. A worker lives ~600 s (+-150), a soldier ~900 s. Egg 20 s, larva 55 s (well fed), pupa 35 s
  (all divided by the climate factor, below).

## World & digging (`SoilGrid`)
* 80x45 grid, 16 px cells. Row 8 is the walkable **surface row**, row 9 the grass-covered top soil.
* Cell types `AIR / SOIL / TUNNEL`. Walkable = TUNNEL + surface row. `AStarGrid2D` (diagonals only if both orthogonal neighbours
  are free) is updated incrementally when a cell is dug. `SoilGrid.load_cells()` swaps the whole map for loading.
* **Dig orders** (`DigTask`): can only be *painted* on soil that touches an open cell or another pending order. Workers can only
  *claim* an order whose cell currently touches an open cell; they walk there, dig 3 s, the cell becomes TUNNEL.
* **Soil mounds**: every dug cell adds one pellet to the mound of the nearest entrance (`Colony.mounds`, drawn by `Overlay`;
  purely visual, size ~ sqrt(pellets)). Refuse dumped outside builds a grey-green **midden** on the other side of the entrance.
* Start nest: shaft at column 40, small storage (west), small nursery (east), side tunnel with a 4x2 waste chamber, queen chamber.

## Chambers (`Room`)
| Type | Capacity | Function |
|---|---|---|
| Queen chamber | – | Queen wanders inside it; **eggs are laid here**. Fixed at start. |
| Nursery | 1 brood per cell | Holds `Brood` in slots. Larvae are fed here; workers/soldiers emerge here. |
| Food storage | 5 food per cell (sugar + protein; one type may fill at most 70 %) | Deposits, feeding, upkeep. Gold = sugar stacks, red = protein stacks. |
| Waste chamber | 6 units per cell | Cleaners dump refuse / corpses here; contents compost away at 0.04 units/s per chamber. |

Player placement (Nursery / Storage / Waste tools): rectangle (5x3, R rotates) inside the map, below row 11, no overlap, touching
a tunnel; it becomes dig orders and is drawn dashed until dug, then activates. Labels are drawn compactly on the chamber
(`Room.short_label`) so neighbouring chambers don't overprint; full text is in the info panel.

## Brood, the queen and nurses
* The queen lays one egg per ~15 s (x0.8..1.2) in the **queen chamber** (a *loose* `Brood`, `room == null`) **only if** protein >= 3,
  sugar > 0, she isn't starving and `free nursery slots - loose brood > 0`. Laying slows to 25 % when protein < 12.
  A worker egg costs 0.5 protein, a soldier egg 1.0.
* **Nurses carry brood** (`claim_brood_move`): loose brood first (any stage; larvae can't be fed until placed), then relocation
  (below). The destination slot is *reserved* in `Room.reserved` when the nurse claims the brood, so two nurses never pick the same
  slot; pick-up empties the old slot, arrival fills the new one. If the carrier dies / is reassigned the brood stays where it stood
  and the reservation is released. Pupae that are due wait to emerge until they are placed.
* **Larvae** have a *fed* level decaying over 40 s; below 0.5 they are "hungry" (red dot). A nurse takes 0.5 **protein** from storage
  and feeds it (+0.6). Development 100 % if fed > 0.25, 35 % below, 0 % at fed = 0; 50 s at 0 and the larva dies (leaves a corpse).
* `Brood` references its `Room` through a `WeakRef` property (Room.slots holds the brood strongly) -> the v2 reference cycle is gone.

## Microclimate (`Climate`)
Depth = row - 9 (cells below the grass).
```
mean_temp(d) = 20 + 7 * (1 - exp(-d/9))                       # deeper = warmer on average (20 -> ~27 C)
temp(d, t)   = mean + exp(-d/6) * (7 * day(t) + 4 * season(t)) # day swing 7 C at the surface, gone by ~d=20; season period 8 days
humidity(d)  = 0.30 + 0.60 * (1 - exp(-d/10))                  # 30 % at the surface -> ~90 % deep
quality      = temp_q * humid_q   temp_q = 1 inside 23..28 C, falling linearly to 0 over 8 C;  humid_q = min(1, humidity / 0.6)
rate         = 0.25 + 0.75 * quality                           # development speed multiplier for eggs, larvae (when fed), pupae
```
Room comfort for planning (`Room.quality`) uses the day-averaged value at the chamber's centre row. Starter nursery ~0.88,
nurseries at row 16+ ~0.98. **Nurses relocate brood** from a chamber to another one with free slots when it is better by >= 0.08
(each brood item then has a 90 s cooldown); new eggs go to the best nursery with room.
The H key tints soil rows by temperature, marks open cells green/red by brood comfort and prints temp/humidity per row; chamber labels show comfort %.

## Food: sugar & protein
* Piles: slots `[sugar, sugar, sugar, protein, protein]`, 30–50 units, respawn 25 s after being emptied at a new column
  (the slot keeps its type). Start stock 26 sugar, 12 protein.
* **Sugar** fuels workers (0.016/s each), soldiers (0.028/s) and the queen (0.03/s). **Protein** pays for eggs and larva feeding.
* Foragers choose a *seek type* when they leave (`pick_seek_type`): weight = `{0.78, 0.22}[type] * (0.12 + 2*urgency(type))`,
  where `urgency = clamp(1 - stock/comfort)`, `comfort = max(12, 0.3*capacity)`; types that storage won't accept or without a pile are skipped.
  They only take a pile of that type for the first 45 s of a search, then any type. HUD shows both stocks.
* **Full storage**: a forager arriving with food into a full store walks to the entrance and *drops* it on the floor
  (`Colony.dropped`, drawn as dots); foragers with nothing to carry first fetch dropped food (if the store accepts that type).
  At the pile, a forager won't take food the store can't hold (it stays on the pile). Nothing is ever deleted.

## Pheromones (`PheroGrid`, 3 instances)
* **Sugar trail**, **protein trail** (loaded foragers lay `0.5 * (0.4 + 0.6*richness)` per cell on the way home in the layer of the type they carry)
  and **alarm** (evaporation 0.10/s, cap 3). Every 0.2 s: 10 % diffusion to walkable 4-neighbours, then `exp(-evap*dt)`
  (trail half-life ~17 s; a depleted source's trail is gone in ~100 s).
* Searching foragers follow *their type's* layer on the surface row with probability ∝ `pheromone + 0.03` (10 % ignore it), else a
  persistent random walk. Leaving the nest, an entrance is chosen by the trail near it.
* Not modelled: a *home* pheromone. Inside the nest ants use A* (= perfect path memory); judged not worth it, see TODO.

## Workers, polyethism and the task chooser
Tasks: **Nurse**, **Dig**, **Forage**, **Clean**, **Idle** (+ **Guard** for soldiers, not chosen). Every worker re-evaluates every 3–6 s when
not carrying anything / mid-action.
```
nurse  = pref_nurse(age) * (0.15 + clamp(hungry_larvae/2) * (protein ok ? 1 : 0.25) + clamp(brood_to_carry/2))
dig    = pref_dig(age)   * (0.5 + clamp(pending_orders/6))                 # only if some order is claimable
forage = max(pref_forage(age), 0.9*urgency) * (0.35 + 0.9*urgency)         # urgency = max(urgency sugar, urgency protein)
           x0.3 if enough foragers already, x0.05 if nothing can be stored / no pile, x0.5 while the alarm is up
clean  = pref_clean(age) * (0.3 + clamp(waste_items/3) + (1 - hygiene))    # only if there is waste
idle   = 0.10
```
Current task x1.25 (hysteresis), small random term. `pref_clean`: young 0.1, mid 0.45–0.85, old 0.6. A switch to Dig / Nurse / Clean
reserves the cached need so a burst of re-evaluations doesn't over-recruit.

## Waste & hygiene
* One **refuse pellet** appears in a nursery/storage every `40 / (workers/10)` s (±30 %); every ant that dies inside the nest and every dead
  brood leaves a **corpse** (2 units). `WasteItem`s are claimed by cleaners, carried to the nearest waste chamber with room, otherwise to the
  surface next to an entrance (midden). With the alarm up, cleaners wait instead of going out.
* `hygiene = clamp(1 - unattended / (8 + 0.25*workers))` where unattended = unclaimed items + 0.5 * claimed ones.
  Below 0.6, each egg/larva dies of disease with probability `(0.6 - hygiene)/0.6 * 0.012` per second ("died of disease" in the log).

## Soldiers
* `Ant.caste = SOLDIER`: 6 HP, 1.2 dmg/s, speed 52 px/s, lifespan 900 s, upkeep 0.028 sugar/s, no foraging, immune to the ambient surface death.
* **Production** (`soldier_target`, `Soldiers` button): *Off* = 0; *Max* = 25 % of workers (cap 12); *Auto* = `3 + min(threats seen, 4)` for 5 minutes after the
  last threat, or `1 + workers/12` when food is plentiful (stock > 70 % capacity, protein >= half of comfort, >= 12 workers). The queen lays soldier eggs while
  `soldiers + soldier brood < target`.
* **Behaviour**: patrol (walk to a random surface cell within 3 cells of a random entrance, stand 2–5 s). When `alarm.peak > 0.25` they walk to the
  surface cell with the strongest alarm (**RESPOND**), then **FIGHT**: run along the surface at 1.3x speed to the nearest threat within 14 cells and hit it every 0.5 s;
  fighting soldiers keep the alarm refreshed.

## Threats (`Threat`) — difficulty `Config.threat_level` (HUD button)
| Level | First | Interval | Life | At once |
|---|---|---|---|---|
| Off | – | – | – | 0 |
| Gentle (default) | ~150 s | 190–300 s | 55 s | 1 |
| Normal | ~100 s | 110–190 s | 80 s | 2 |

65 % spider (6 HP, 26 px/s, lunges at 2.4x within 4.5 cells, kills a worker after 1.0 s in reach, 0.8 dmg/s to soldiers), 35 % rival scout (3 HP, 42 px/s, kills in 2.0 s,
0.6 dmg/s). They spawn at a map edge, hunt the nearest ant on the surface within 16 cells, otherwise wander; after their lifetime they leave.
Surface ants check every 0.4 s for a threat within 5 cells: soldiers just raise the alarm; workers also flee into the nearest entrance and hide 12–25 s
(carried food is kept). Foragers don't go out while the alarm is up. There is also a tiny ambient surface death rate (0.00012/s per worker).

## HUD, feedback, help
Stats panel (day, surface temperature, workers by task, soldiers + goal, hygiene, brood by stage, sugar / protein, warnings), tool buttons (5), speed/pause,
trail (P) and climate (H) toggles, soldier / threat / save / load buttons, info panel (hover a chamber, click ants/brood/chambers), tool hint line,
**event log** (bottom-left, last 6 events), **help overlay** (F1, auto-hides after 25 s). Effects (`Colony.fx`, simulated time): dust when a cell is dug, "+" when a larva is
fed, "+n" when food is stored, "!" when an ant spots a threat, "x" for deaths, rings for eggs / emerging ants, sparks on hits.
**Ant animation (code only)**: tripod-gait two-segment legs, body bob, antenna twitching, head dipping while digging, mandibles opening while fighting,
queen abdomen pulse (stronger just before laying), "z" while hiding.

## Save / load (`SaveGame`)
`user://ant_city_save.json` (F5 / F9), version 3. Stores: time, timers, options (soldier mode, threat level), statistics, the map (base64 bytes), rooms (incl. contents),
brood (stage, progress, fed, slot / loose position), ants (cell, age, lifespan, hp, hunger, task, caste, carried food), queen, food piles, **all three pheromone grids**
(base64 float32), dig orders, waste items, dropped food, mounds / middens, the last 20 log lines. Not stored (rebuilt): paths, claims, what an ant was about to do
(ants wake up idle and re-decide), brood in transit (stored lying where its carrier stood), carried refuse (stored as an item on the floor), predators (cleared; timer restarts).
Invalid files (missing, garbage, wrong version, missing keys, wrong sizes) are rejected with a message in the event log and the running colony is not touched.

## Art, icons and sound (v4)
Presentation only: no simulation rule depends on it. All assets are optional and guarded (`Art.tex`, `ResourceLoader.exists`).
- **Sound**: `GameAudio` (see README). Event hooks live in the simulation as `Colony.sfx(name)`: dig complete, `Threat.hit`, `spawn_threat`, alarm rising edge (`alarm.peak > ALARM_ACTIVE`), ant killed outside. The simulation never waits for or depends on audio.
- **Icons**: `GameUI.icon(name)`; stats lines use worker / soldier / nursery / food / climate icons and a warning icon when a warning is shown; the event log is a `RichTextLabel` with inline images.
- **Rooms**: chamber PNG per room type (`Room.icon_name`), cover-scaled, 62 % alpha; fill indicators get a dark backing.
- **Sprites**: scale 0.5 (worker, soldier, scout, spider), 0.45 (queen); queen legs are drawn shorter (1.25x instead of 1.9x) and rooted on her thorax because the sprite is smaller than the old drawing.
- **Sky**: rows 0-8 (y 0-144) from `sky_surface.png`; the soil starts at y = 144 = `FIRST_SOIL_ROW * CELL`, so no offset or scale was needed.

## Tuning knobs (all in `scripts/Config.gd`)
Food: `START_SUGAR/PROTEIN`, `SUGAR_RATE_*`, `EGG_PROTEIN_COST`, `SOLDIER_EGG_PROTEIN_COST`, `LAY_*`, `TYPE_CAP_FRAC`, `FOOD_LAYOUT`, `FOOD_TYPE_WEIGHT`, `FOOD_*`.
Waste: `REFUSE_BASE_INTERVAL`, `CORPSE_UNITS`, `WASTE_*`, `HYGIENE_*`, `BROOD_DISEASE_RATE`, `PREF_CLEAN`.
Soldiers/threats: `SOLDIER_*`, `ALARM_ACTIVE`, `THREAT_FIRST/INTERVAL/LIFE`, `FEAR_RADIUS`, `threat_level`.
Climate: `TEMP_*`, `HUMID_*`, `BROOD_TEMP_*`, `BROOD_RATE_FLOOR`, `BROOD_MOVE_*`.
Colony: `EGG_INTERVAL`, `STORAGE_PER_CELL`, `LIFESPAN_MEAN`, `DIG_TIME`, `PREF_NURSE/DIG/FORAGE`, `FORAGER_SHARE_*`, `PHERO_*`, brood timings, `MAX_WORKERS`.

## Measured behaviour (built-in self-test, headless, `--selftest`, Godot 4.3)
* Default settings (gentle threats, auto soldiers), seeds 1–4, 30 sim minutes: workers grow from 10 to 44–48 peak and settle at 37–43, 5–7 soldiers, 7–8 threats seen,
  5–6 killed by soldiers, 0–3 workers killed outside, no larva starved, no disease, min hygiene 0.82–0.86, brood relocations ~8 per run, zero invariant violations.
* 3 simulated hours (seed 6): 719 ants born, 43 threats (41 killed), min hygiene 0.78, waste 1227 items handled, population 39 at the end, no problems.
* Soldiers off + Normal threats: 11 threats in 30 min, none killed, only 1 ant lost (the foragers flee, but the colony forages less while the alarm is up).
* No food at all: the colony starves out within ~10 sim minutes (measured: all workers dead by t=600 s). No protein pile at all: no eggs are laid and the colony ages out (expected, by design).
* Save/load round trip: map, rooms, ants, brood, stocks, waste and all three pheromone grids restored bit-identically (checked by hashing) and 160 s of further simulation ran cleanly.


## v5 additions
- **Home pheromone** (`Colony.home`, PheroGrid): outbound ants deposit `HOME_DEPOSIT` decaying with time out of the nest
  (`HOME_DECAY_T`). Returning ants above `HOME_FOLLOW_MIN` follow the gradient with probability `HOME_FOLLOW_P`, give up after
  `HOME_GIVEUP` s and fall back to A*. In tunnels the A* weights are lowered on strong home trail (`HOME_WEIGHT_K/MIN`) and raised on flooded cells.
- **Raids**: `RAID_CHANCE` of rival scouts are raiders. Phases: enter via the busiest entrance -> path to brood / storage -> steal
  (`RAID_STEAL_FOOD` or one brood) -> leave. Workers within `DEFEND_RADIUS` bite (`WORKER_BITE`, max 3 per intruder), soldiers hunt
  them; intruders bite back (`INTRUDER_DPS`). Killed raiders drop their loot (brood is rescued).
- **Soil**: `complete_dig` gives the digger a pellet (`SOIL_CARRY`), carried (slower) to the mound of the nearest entrance.
- **Rain**: first after `RAIN_FIRST`, then every ~`RAIN_INTERVAL`, lasting `RAIN_DURATION`. Raises humidity via `Climate.wet`;
  heavy rain fills the top `FLOOD_ROWS` open cells (`FLOOD_RATE`, drains with `FLOOD_DRAIN`); flooded rooms have quality 0, brood
  there grows slower and may die (`FLOOD_BROOD_DEATH`), nurses move it.
- **Rendering budget (web)**: per frame ~8-9k primitives / ~390 draw calls with 40 ants and the trails overlay (v4: ~19-21k / ~400).
  Before/after in headless Chrome + SwiftShader (WebGL2), seed 3, ffwd 600 s then 270 s real at 4x with the overlays cycling:

  | | v4 | v5 |
  |---|---|---|
  | primitives / frame | 16.5k - 19.7k | 8.2k - 9.2k |
  | draw calls / frame | 345 - 418 | 342 - 404 |
  | objects (start -> end) | 1543 -> 1553 | 1545 -> 1558 |
  | resources | 49 flat | 51 flat |
  | texture memory | 10.4 -> 10.5 MB | 10.4 -> 10.6 MB |
  | video memory | 20.8 -> 23.1 MB | 20.7 -> 20.9 MB |
  | WebGL context lost | no | no |

  Native (Xvfb, GL 3.3) per-node breakdown at t=1500 (42 ants): ants 10.9k -> 3.4k primitives, overlay 2.8k -> 0.76k, food 288 -> 64.


## v6 additions
- **Founding start** (`Config.classic_start = false`): shaft col 40 rows 9-18 and `FOUND_QUEEN_RECT` (4x2, rows 19-20, below the flood rows).
  `FOUND_WORKERS` 4 young workers, `FOUND_EGGS` 3 + `FOUND_LARVAE` 1 brood, `FOUND_SUGAR` / `FOUND_PROTEIN` in the queen chamber.
- **Room fallbacks**: `Room.is_store()` / `is_nursery()` include the queen chamber (`QUEEN_FOOD_CAP`, `QUEEN_BROOD_SLOTS`).
  Deposits go to real storage first (`_store_key`), brood prefers real nurseries (`brood_q` = quality - `QUEEN_BROOD_PENALTY`),
  so nurses move brood out once a nursery is dug. Waste without a waste chamber goes to the surface midden (as before).
- **Tutorial** (`Tutorial.gd`, a Control in the HUD layer): steps = [title, text, highlight, needs Next]; `_step_done()` checks dig orders,
  planned rooms of each type, the P overlay or foraged food. `poll()` is public so the self-test can drive it.

## v8 additions - player decisions
* `Colony.work_prio[5]` (0..4) -> `Config.PRIO_MULT` multiplies s_forage / s_nurse / s_dig / s_clean in `score_tasks`; Guard scales
  `soldier_target()`. `job_targets()` (base shares x multipliers, normalised to workers) vs `job_actual()` for the HUD.
  `age_efficiency(ant)` = 0.7 + 0.3 x age-curve for the current job, applied to walking speed and fill speed.
* Castes: `Brood.Caste` / `Ant.Caste` = WORKER, SOLDIER, GYNE (same order). `pick_egg_caste()`: manual weights `caste_w` or Auto.
  `Config.CASTE_PROTEIN / CASTE_SUGAR / CASTE_TIME`. Gynes: idle in the queen chamber, eat `SUGAR_RATE_GYNE`, excluded from
  worker_count / reassign. `start_nuptial_flight()` needs `GYNE_GOAL` = 3, removes them (no corpse, no death), adds score,
  emits `nuptial_flight(summary)` -> UI summary panel (game pauses).
* Threat orders: `standing_order`, `active_order` (alarm banner; resets 10 s after the all-clear). `sealed()`: forage score x0.02,
  `_decide_forage` waits inside, `Threat._try_enter` gives up. `fighting()`: surface workers within 6 cells of a threat join the
  fight with 50 % chance (0.15 x soldier damage). `evacuating()`: `brood_q()` = depth, so relocation moves brood deepest.
* Food: `Config.TYPE_CAP` [0.75, 0.40] per-type storage share, `FOOD_COMFORT_SHARE` [0.42, 0.22], scarce type x(1/0.15) in
  `pick_seek_type`, `FOOD_LAYOUT` 4 sugar + 2 protein.
* Fill: `Colony.fill_tasks` (DigTask records), `fill_error(c)`, `_connected_without(c, strict)` BFS from the entrances,
  `claim_fill_task` (skips inner cells while outer ones are pending), `complete_fill` (re-checks, `SoilGrid.fill`, removes an emptied
  chamber, ants routed through the cell re-plan). Ant: Purpose GET_SOIL / TO_FILL, State FILLING, `fill_soil` pellet. Soil
  bookkeeping: dug = hauled + lost + carried + `soil_used` (mound pellets are counted in `mound_used`).
* Save: `v8` dict (priorities, castes, orders, flights, score, fill orders, counters) + per-ant `fs`; older saves load with defaults.
