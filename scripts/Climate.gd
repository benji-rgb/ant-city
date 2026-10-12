class_name Climate
extends RefCounted
## Depth based microclimate. Deeper soil is stabler, more humid and (on average) warmer.
## Rows are grid rows; row 9 is the top soil layer.

static func depth(row: int) -> float:
	return maxf(0.0, float(row - Config.FIRST_SOIL_ROW))

static func mean_temp(row: int) -> float:
	return Config.TEMP_SURFACE_MEAN + Config.TEMP_DEEP_GAIN * (1.0 - exp(-depth(row) / Config.TEMP_DEEP_SCALE))

static func temp(row: int, time: float) -> float:
	var d := depth(row)
	var damp := exp(-d / Config.TEMP_AMP_SCALE)
	var day := sin(TAU * time / Config.DAY_LENGTH - 1.2)     # coldest around the middle of the night
	var season := sin(TAU * time / (Config.DAY_LENGTH * Config.SEASON_DAYS))
	return mean_temp(row) + damp * (Config.TEMP_AMP * day + Config.TEMP_SEASON_AMP * season)

static func humidity(row: int) -> float:
	return Config.HUMID_SURFACE + Config.HUMID_GAIN * (1.0 - exp(-depth(row) / Config.HUMID_SCALE))

## 0..1 how comfortable the brood is at this temperature / humidity.
static func quality(t: float, h: float) -> float:
	var tq := 1.0
	if t < Config.BROOD_TEMP_LO:
		tq = 1.0 - (Config.BROOD_TEMP_LO - t) / Config.BROOD_TEMP_SPAN
	elif t > Config.BROOD_TEMP_HI:
		tq = 1.0 - (t - Config.BROOD_TEMP_HI) / Config.BROOD_TEMP_SPAN
	tq = clampf(tq, 0.0, 1.0)
	var hq := clampf(h / Config.BROOD_HUMID_OK, 0.0, 1.0)
	return tq * hq

## Development speed multiplier (1 = ideal).
static func rate(q: float) -> float:
	return Config.BROOD_RATE_FLOOR + (1.0 - Config.BROOD_RATE_FLOOR) * q

static func quality_at(row: int, time: float) -> float:
	return quality(temp(row, time), humidity(row))

## Time-independent comfort of a row (average of the day cycle, no season) used for planning.
static func mean_quality(row: int) -> float:
	var s := 0.0
	for i in 8:
		var tt := Config.DAY_LENGTH * float(i) / 8.0
		var d := depth(row)
		var t := mean_temp(row) + exp(-d / Config.TEMP_AMP_SCALE) * Config.TEMP_AMP * sin(TAU * tt / Config.DAY_LENGTH - 1.2)
		s += quality(t, humidity(row))
	return s / 8.0
