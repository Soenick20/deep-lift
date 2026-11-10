# Weapons and loot tables. A weapon is a plain Dictionary so it is easy to store, drop and copy.
extends RefCounted

const RARITY_NAMES := ["Common", "Rare", "Epic"]
const RARITY_COLORS := [Color("d8dde3"), Color("4da3ff"), Color("c07bff")]
const RARITY_DAMAGE := [1.0, 1.35, 1.8]
const RARITY_RATE := [1.0, 0.88, 0.76]     # cooldown multiplier, lower is faster

# dmg per bullet, cooldown s, pellets, spread (radians, total), bullet life s, speed m/s, noise radius m, pierce
const TYPES := {
	"Pistol":  {"dmg": 1.0, "cd": 0.26, "pellets": 1, "spread": 0.04, "life": 0.75, "speed": 20.0, "noise": 8.0, "pierce": 0},
	"Shotgun": {"dmg": 0.8, "cd": 0.62, "pellets": 5, "spread": 0.42, "life": 0.36, "speed": 18.0, "noise": 11.0, "pierce": 0},
	"SMG":     {"dmg": 0.5, "cd": 0.085, "pellets": 1, "spread": 0.16, "life": 0.6, "speed": 22.0, "noise": 9.0, "pierce": 0},
	"Rifle":   {"dmg": 2.6, "cd": 0.75, "pellets": 1, "spread": 0.0, "life": 1.1, "speed": 30.0, "noise": 12.0, "pierce": 2}}

const UPGRADE_COST := [6, 12]   # Common -> Rare, Rare -> Epic, paid in banked ore


static func make(type: String, rarity: int, rng: RandomNumberGenerator = null) -> Dictionary:
	var base: Dictionary = TYPES[type]
	var r1 := 1.0
	var r2 := 1.0
	if rng:
		r1 = rng.randf_range(0.9, 1.12)
		r2 = rng.randf_range(0.92, 1.08)
	return {
		"type": type,
		"rarity": rarity,
		"dmg": base.dmg * RARITY_DAMAGE[rarity] * r1,
		"cd": base.cd * RARITY_RATE[rarity] * r2,
		"pellets": base.pellets,
		"spread": base.spread,
		"life": base.life,
		"speed": base.speed,
		"noise": base.noise,
		"pierce": base.pierce + (1 if rarity == 2 and type == "Rifle" else 0)}


static func name_of(w: Dictionary) -> String:
	return "%s %s" % [RARITY_NAMES[w.rarity], w.type]


static func color_of(w: Dictionary) -> Color:
	return RARITY_COLORS[w.rarity]


static func dps(w: Dictionary) -> float:
	return w.dmg * w.pellets / w.cd


# Rarity odds get better with depth; bonus shifts odds further (hidden pockets, tough monsters).
static func roll_rarity(rng: RandomNumberGenerator, depth: int, bonus: float = 0.0) -> int:
	var common := maxf(70.0 - depth * 8.0 - bonus, 10.0)
	var rare := 25.0 + depth * 5.0 + bonus * 0.6
	var epic := 5.0 + depth * 3.0 + bonus * 0.4
	var r := rng.randf() * (common + rare + epic)
	if r < common:
		return 0
	if r < common + rare:
		return 1
	return 2


static func roll_weapon(rng: RandomNumberGenerator, depth: int, bonus: float = 0.0) -> Dictionary:
	var types := TYPES.keys()
	return make(types[rng.randi() % types.size()], roll_rarity(rng, depth, bonus), rng)
