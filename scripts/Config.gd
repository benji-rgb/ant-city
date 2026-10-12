class_name Config
extends RefCounted
## Single place with every tuning knob of Ant City.
## All times are in "simulation seconds" (1x speed = 1 sim second per real second).

enum Food { SUGAR, PROTEIN }

## Runtime options (changed from the HUD, stored in save files)
static var threat_level := 1            # 0 = off, 1 = gentle, 2 = normal
const THREAT_NAMES := ["Off", "Gentle", "Normal"]

# ---------------------------------------------------------------- grid / world
const CELL := 16
const GRID_W := 80
const GRID_H := 45
const SURFACE_ROW := 8            # walkable row just above the ground (y 128..144)
const FIRST_SOIL_ROW := 9         # first diggable soil row (grass-covered)
const MIN_ROOM_ROW := 11          # chambers can't be placed above this row
const SCREEN := Vector2(1280, 720)
const DIG_MIN_X := 1
const DIG_MAX_X := GRID_W - 2
const DIG_MAX_Y := GRID_H - 2

# ---------------------------------------------------------------- simulation
const SIM_DT := 1.0 / 60.0        # fixed simulation step
const MAX_STEPS_PER_FRAME := 16   # safety cap when running 4x on a slow machine
const DAY_LENGTH := 60.0          # sim seconds per colony "day"
const MAX_WORKERS := 90

# ---------------------------------------------------------------- ants
const WORKER_SPEED := 56.0        # px / s
const QUEEN_SPEED := 22.0
const LIFESPAN_MEAN := 600.0
const LIFESPAN_VARIANCE := 150.0
const START_WORKERS := 10
const DIG_TIME := 3.0             # seconds to dig one soil cell
const TASK_EVAL_MIN := 3.0        # each worker re-evaluates its task every X..Y s
const TASK_EVAL_MAX := 6.0
const TASK_HYSTERESIS := 1.25     # score multiplier for the current task (avoids flip-flopping)
const SURFACE_DEATH_RATE := 0.00012  # ambient danger per second per ant on the surface (on top of real threats)
const CARRY_AMOUNT := 2.0         # food units a forager carries
const NURSE_FEED_COST := 0.5      # protein taken from storage for one larva feeding
const STARVE_TIME := 180.0        # seconds without sugar until a worker dies
const HUNGER_RECOVER := 0.02      # per second once food is available again

# polyethism preference curves: [age_fraction, preference] anchor points (linearly interpolated)
const PREF_NURSE := [[0.0, 1.0], [0.20, 1.0], [0.45, 0.30], [1.0, 0.05]]
const PREF_DIG := [[0.0, 0.30], [0.20, 0.40], [0.35, 0.90], [0.60, 0.90], [0.80, 0.30], [1.0, 0.20]]
const PREF_FORAGE := [[0.0, 0.05], [0.20, 0.10], [0.45, 0.40], [0.70, 1.00], [1.0, 1.00]]
const FORAGER_SHARE_BASE := 0.15  # minimum desired share of foragers
const FORAGER_SHARE_HUNGRY := 0.55  # extra share when food is short
const FOOD_COMFORT_MIN := 12.0

# ---------------------------------------------------------------- colony / food
const START_SUGAR := 26.0
const START_PROTEIN := 12.0
const SUGAR_RATE_WORKER := 0.016  # sugar / s per worker (their fuel)
const SUGAR_RATE_QUEEN := 0.030
const SUGAR_RATE_SOLDIER := 0.028
const STORAGE_PER_CELL := 5.0     # food capacity per storage cell (sugar + protein share it)
const TYPE_CAP_FRAC := 0.7        # one food type may fill at most this share of the storage
const BROOD_PER_CELL := 1         # brood capacity per nursery cell
const WASTE_PER_CELL := 6.0       # refuse units per waste-chamber cell
const EGG_INTERVAL := 15.0
const EGG_PROTEIN_COST := 0.5     # a worker egg costs protein ...
const SOLDIER_EGG_PROTEIN_COST := 1.0  # ... a soldier egg costs more
const LAY_PROTEIN_MIN := 3.0      # queen only lays if protein stock >= this (and sugar > 0)
const LAY_COMFORT := 12.0         # below this protein stock the laying rate drops (down to 25%)
const FOOD_COMFORT_TYPE := 0.30   # comfortable stock of ONE type, as share of capacity (min 12)
const FOOD_TYPE_WEIGHT := [0.78, 0.22]   # how much of the colony's appetite each type represents


# brood
const EGG_TIME := 20.0
const LARVA_TIME := 55.0          # of "well fed" progress
const PUPA_TIME := 35.0
const FEED_GAIN := 0.6            # fed level gained per feeding
const FEED_THRESHOLD := 0.5       # larvae below this ask for food
const LARVA_FED_DECAY := 40.0     # seconds for a full larva to become hungry-empty
const LARVA_STARVE_DEATH := 50.0  # seconds at fed == 0 before the larva dies

# food sources
const FOOD_LAYOUT := [0, 0, 0, 1, 1]   # food type of each pile slot (0 sugar, 1 protein)
const FOOD_AMOUNT_MIN := 30.0
const FOOD_AMOUNT_MAX := 50.0
const FOOD_RESPAWN := 25.0
const FOOD_MIN_SPACING := 10      # cells
const FOOD_MIN_FROM_ENTRY := 6

# ---------------------------------------------------------------- pheromones
const PHERO_STEP := 0.2           # update interval
const PHERO_EVAP := 0.04          # per second (exponential)
const PHERO_DIFFUSE := 0.10       # share exchanged with neighbours per update
const PHERO_MAX := 5.0
const PHERO_DEPOSIT := 0.5        # per cell passed by a loaded forager, scaled by source richness
const PHERO_EPS := 0.03           # weight floor (lets ants find new sources)
const PHERO_FOLLOW_MIN := 0.02    # below this a cell is not "a trail"
const PHERO_RANDOM_PICK := 0.10   # chance to ignore the trail (exploration)
const SURFACE_TURN_PROB := 0.06   # random walk: chance of turning around each step

# ---------------------------------------------------------------- colors
const COL_NURSE := Color(1.0, 0.55, 0.80)
const COL_DIG := Color(1.0, 0.70, 0.15)
const COL_FORAGE := Color(0.35, 0.95, 0.30)
const COL_IDLE := Color(0.80, 0.80, 0.85)
const COL_CLEAN := Color(0.62, 0.78, 0.35)
const COL_GUARD := Color(1.0, 0.25, 0.25)
const FOOD_COL := [Color(1.0, 0.82, 0.25), Color(0.93, 0.38, 0.40)]
const FOOD_NAMES := ["Sugar", "Protein"]

# ---------------------------------------------------------------- waste / hygiene
const REFUSE_BASE_INTERVAL := 40.0   # one refuse pellet per (this / (workers/10)) seconds
const CORPSE_UNITS := 2.0
const WASTE_DECAY := 0.04            # units / s a waste chamber composts away (per chamber)
const HYGIENE_BASE := 8.0            # tolerated unattended waste items = base + 0.25 * workers
const HYGIENE_PER_WORKER := 0.25
const HYGIENE_BAD := 0.6             # below this brood starts dying
const BROOD_DISEASE_RATE := 0.012    # per second at hygiene 0 (scaled by how far below HYGIENE_BAD)
const PREF_CLEAN := [[0.0, 0.10], [0.25, 0.45], [0.55, 0.85], [1.0, 0.60]]

# ---------------------------------------------------------------- soldiers
const SOLDIER_LIFESPAN := 900.0
const SOLDIER_HP := 6.0
const SOLDIER_DAMAGE := 1.2          # damage per second dealt to a threat
const SOLDIER_SPEED := 52.0
const SOLDIER_MAX := 12
const ALARM_ACTIVE := 0.25

# ---------------------------------------------------------------- threats
const THREAT_FIRST := [9999.0, 150.0, 100.0]          # seconds until the first threat, by level
const THREAT_INTERVAL := [[9999.0, 9999.0], [190.0, 300.0], [110.0, 190.0]]   # min/max between threats
const THREAT_LIFE := [0.0, 55.0, 80.0]
const FEAR_RADIUS := 5                # cells at which a surface worker notices a threat

# ---------------------------------------------------------------- climate
const TEMP_SURFACE_MEAN := 20.0
const TEMP_DEEP_GAIN := 7.0          # deeper soil is warmer on average ...
const TEMP_DEEP_SCALE := 9.0
const TEMP_AMP := 7.0                # ... and the day/night swing fades with depth
const TEMP_AMP_SCALE := 6.0
const TEMP_SEASON_AMP := 4.0
const SEASON_DAYS := 8.0
const HUMID_SURFACE := 0.30
const HUMID_GAIN := 0.60
const HUMID_SCALE := 10.0
const BROOD_TEMP_LO := 23.0          # brood develops fastest between these temperatures
const BROOD_TEMP_HI := 28.0
const BROOD_TEMP_SPAN := 8.0         # degrees outside the band until development stops (floor applies)
const BROOD_HUMID_OK := 0.60
const BROOD_RATE_FLOOR := 0.25
const BROOD_MOVE_MARGIN := 0.08      # nurses relocate brood only for a clearly better chamber
const BROOD_MOVE_COOLDOWN := 90.0
