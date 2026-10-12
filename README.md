# Ant City (v4) — Godot 4 side-view ant colony simulator

A cross-section ant nest. You don't control individual ants: you designate **where to dig** and **which
chambers to build**, and the colony (queen, workers, soldiers, brood) organises itself with pheromone trails,
age-based task allocation, two food types, waste, a microclimate and the occasional predator.

Targets **Godot 4.3** (GL Compatibility renderer, 1280x720). Nothing here needs 4.4+. UI text is English.

## How to run
1. Install Godot 4.3 or newer (godotengine.org).
2. Import / open the `ant_city_v4` folder (or `project.godot`) and press **F5** in the editor
   (inside the running game F5 is "save", see below).
   - CLI: `godot --path ant_city_v4`
   - Headless smoke test: `godot --headless --path ant_city_v4 --quit-after 300`

## Controls
| Input | Action |
|---|---|
| **1 / 2 / 3 / 4 / 5** or the buttons | Tools: Select, Dig, Nursery, Storage, **Waste** |
| Dig tool: **left-drag** | Paint dig orders (soil cell must touch a tunnel / the surface, or another order) |
| Dig tool: **right-drag** | Cancel dig orders |
| Nursery / Storage / Waste: **click** | Designate a 5x3 chamber (ghost = green if valid, red + reason if not) |
| **R** | Rotate the chamber ghost (5x3 <-> 3x5) |
| Right-click a *planned* chamber | Cancel it |
| Select tool: **click** an ant / brood / chamber | Inspect it in the top-right panel |
| **Space** | Pause |
| **- / +** or 1x 2x 4x buttons | Simulation speed |
| **P** | Pheromone overlay (yellow = sugar trail, pink = protein trail, red = alarm) |
| **H** | Climate overlay (temperature tint per depth, green cells = good for brood; hover shows the numbers) |
| **F5 / F9** (or the Save / Load buttons) | Save / load the colony to `user://ant_city_save.json` |
| **F1** | Help overlay (also shown for the first 25 s) |
| **Soldiers: Auto / Off / Max** button | How many soldiers the queen raises |
| **Threats: Off / Gentle / Normal** button | Predator frequency (difficulty) |
| **M** / sound button (bottom-right) | Mute / unmute (HUD shows `Sound 60% [M]` or `MUTED [M]`) |
| **[** / **]** | Master volume -10 % / +10 % (saved in `user://settings.cfg`) |
| **Esc** | Back to Select |

Ant colours (marker above the ant + abdomen): pink = Nurse, orange = Dig, green = Forage, olive = Clean,
red = Soldier (guard), grey = Idle. Carried items: yellow dot = sugar, red-pink dot = protein, pale dot = larva
food or brood, brown dot = refuse. A red dot over a larva = it is hungry. An "x" = something died, "!" = an ant saw a predator.

## What's in the game
* **Soil grid** (80x45 cells of 16 px), digging by dig orders, `AStarGrid2D` over tunnels + surface row.
* **Chambers**: Queen chamber, Nursery, Food storage (sugar + protein), **Waste chamber**. Planned chambers are dug out by workers.
* **Brood logistics (new)**: the queen lays eggs *in her chamber*; nurses carry eggs / larvae to a nursery and, if a
  clearly better-climate nursery has room, relocate brood there. Larvae are fed protein by nurses.
* **Two food types (new)**: sugar (fuel for workers/soldiers/queen) and protein (eggs cost protein, larvae are fed protein).
  Three sugar piles + two protein piles on the surface; foragers each look for one type (weighted by what the colony lacks)
  and follow that type's own pheromone trail.
* **Full storage (new)**: foragers never lose food: if the store fills up they leave the load at the nest entrance;
  other foragers carry it in once there is space.
* **Waste (new)**: refuse pellets and corpses accumulate in the nest; **cleaners** carry them to a waste chamber (or dump them
  outside on a midden next to the entrance when it is full). Unattended waste lowers the hygiene meter; below 60 % brood falls ill.
* **Soldiers (new)**: a second caste, produced automatically when the colony was threatened recently or food is plentiful
  (or always / never, via the button). They patrol the entrances, are stronger and don't forage.
* **Threats (new)**: spiders and rival-colony scouts roam the surface and kill ants outside. Workers that see one flee,
  lay **alarm pheromone** and hide; soldiers climb the alarm gradient and fight. Gentle by default, configurable.
* **Microclimate (new)**: deeper = damper and steadier; brood develops fastest at 23-28 C and >= 60 % humidity (H overlay).
* **Soil mounds (new)**: every dug cell adds to a visible soil mound beside the nearest entrance.
* **Art & sound (v4)**: sprite art for workers / soldiers / queen / spider / rival scout (legless `*_body` sprites with the code-animated legs and
  antennae on top), a sky background, chamber pictures, HUD icons, ambient loops and sound effects. Every asset is optional: a missing
  or unloadable file falls back to the old procedural drawing / silence (see "Art and sound" below).
* **Save / load (new)**, ant leg/antenna animation, effect popups, an event log and in-game help.
* From v2: pheromone recruitment, age polyethism with a utility-based task chooser, finite food piles that respawn.

See `docs/GDD.md` for how each system works and the tuning knobs (`scripts/Config.gd`), and `docs/TODO.md` for the roadmap.

## Project layout
```
scenes/Main.tscn        one node; Main.gd builds everything in code
scripts/Config.gd       every tuning constant (+ the runtime threat level)
scripts/Main.gd         input, tools, speed/pause, fixed-step sim loop, save/load hooks
scripts/SoilGrid.gd     grid, A*, baked ground texture, digging
scripts/PheroGrid.gd    pheromone field (used 3x: sugar trail, protein trail, alarm)
scripts/Colony.gd       rooms, brood logistics, food, waste, soldiers/threat spawning, dig orders, utility task AI
scripts/Ant.gd          worker / soldier / queen state machine + procedural, animated drawing
scripts/Threat.gd       surface predators (spider, rival scout)
scripts/Climate.gd      depth based temperature / humidity / brood comfort functions
scripts/SaveGame.gd     JSON save / load
scripts/Room.gd, Brood.gd, DigTask.gd, WasteItem.gd   data classes
scripts/FoodSource.gd   respawning food piles (sugar or protein)
scripts/Audio.gd         sound manager (ambient loops, throttled one-shots, volume / mute)
scripts/Art.gd           guarded texture loading + sprite lookup
scripts/Overlay.gd      rooms / brood / waste / mounds / pheromone / climate / effects drawing
scripts/UI.gd           code-built HUD (stats, buttons, info, event log, help)
scripts/SelfTest.gd     developer test harness (only runs with command-line flags)
assets/food_pile.png    transparent food sprite (tinted in code per food type)
assets/audio/  7 WAV   assets/icons/  23 PNG (64x64)   assets/chambers/  4 PNG   assets/sprites/  10 PNG   assets/backgrounds/sky_surface.png
assets/*.jpg            original starter art, unused
```

## Art and sound
Files come from the art agent's batch 1 + 2 (`ant_city_v3_art/ART_NOTES.md`); see that file for sizes, palette and licensing (all generated by code, original).
* **Audio** (`Audio.gd`, a node created by `Main`, no autoload): `ambient_surface` and `ambient_nest` loop (loop mode set at runtime over the whole sample)
  and are crossfaded by the mouse height (above the ground line = surface, below = nest). One-shots: `dig` (when a cell is excavated), `fight`
  (a soldier hits a predator), `threat_warning` (a predator appears), `alarm` (alarm pheromone rises, or a worker is killed outside), `ui_click`
  (buttons / keys / placing a chamber). 6 one-shot players; per-sound minimum interval and max copies (dig 0.4 s, fight 0.45 s, alarm 6 s, warning 4 s).
  Master volume default 60 %, M mutes, `[` `]` change it. Headless runs do not create players (dummy driver); `--nosound` disables, `--forcesound` forces it on.
* **Icons** on the tool / option buttons, the stats lines and the event log (`log_event(msg, icon)` stores an `@icon` prefix; old saves just show no icon).
* **Chamber art** drawn in `Overlay._draw_rooms` at 62 % opacity, scaled to cover the room without distortion (portrait rooms show the centre slice),
  with a dark backing behind the storage / waste fill so the heaps stay readable. Planned rooms keep the dashed outline; the placement ghost previews the art.
* **Sprites**: `Ant._draw` and `Threat._draw` draw the `*_body` sprite (worker / soldier 0.5x, queen 0.45x, spider / rival 0.5x), mirrored when facing left;
  the task colour is a light tint plus a dot on the abdomen, the task marker and selection ring are unchanged.
* **Sky**: `SoilGrid` blits `sky_surface.png` (1280x144 = rows 0-8 exactly; tiled / scaled automatically if the size ever differs) instead of the flat gradient;
  the sun is still drawn by code.

## Developer tests
```
# N simulated seconds without rendering, scripted "player" actions, invariants checked every 2 s, prints a report
# (exit code 1 on problems).  ALWAYS wrap in `timeout`: a script parse error leaves headless Godot hanging.
godot --headless --path . -- --selftest=1800 --seed=1
#   options: --threats=0|1|2  --threatat=T [--threatkind=0|1]  --soldiermode=0|1|2 (auto/off/max)
#            --foods=N (first N piles only; note piles 4-5 are protein)  --nofood  --dt=0.0333
#            --savetest=T (save at T, keep running 40 s, load, compare)  --events  --dbgwaste
# screenshots (needs a display, e.g. xvfb-run):
xvfb-run -a godot --path . --rendering-driver opengl3 -- --shot=out.png --ffwd=420 --seed=21 --nohelp --phero=1
#   extra: --climate=1  --threats=N  --tool=N
# audio manager checks (forces the manager on under the dummy audio driver):
godot --headless --path . -- --audiotest --forcesound
# simulated mouse/keyboard UI test with screenshots (48 assertions, incl. audio / mute / volume):
xvfb-run -a godot --path . --rendering-driver opengl3 -- --shot=out --ffwd=60 --uitest --seed=11 --threats=0
```

## Resumen en español
Hormiguero en corte lateral. Tú diseñas dónde excavar (*Dig*) y qué cámaras construir (*Nursery*, *Storage*, *Waste*);
la colonia se organiza sola. Novedades de la v4: gráficos (hormigas, cielo, cámaras, iconos) y sonido (ambiente, efectos, tecla **M** para silenciar, **[ ]** volumen). Novedades de la v3: la reina pone los huevos en su cámara y las nodrizas los llevan a la
guardería (o a la mejor por clima); hay dos tipos de comida (azúcar para las obreras, proteína para huevos y larvas);
las limpiadoras llevan basura y cadáveres a la cámara de desechos; soldados que patrullan las entradas; arañas y
exploradoras rivales que matan hormigas en la superficie (feromona de alarma); microclima por profundidad (tecla **H**);
guardar/cargar con **F5/F9**; registro de eventos y ayuda con **F1**. La interfaz está en inglés.
