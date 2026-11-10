# The prologue: the first night on the surface, played as a tutorial.
# Camp and class tents -> trail and gate -> chop and dig -> dark woods, torches, critters
# -> temple and heartstone -> escort to the ancient tower -> it wakes -> first jump.
extends Node3D

const VK = preload("res://scripts/voxel_kit.gd")
const CrawlerScript = preload("res://scripts/crawler.gd")
const PlayerScript = preload("res://scripts/player.gd")

enum { MOVE, CLASS, CHOP, DARK, CRITTERS, TO_TEMPLE, SEARCH, CARRY, WAKE }

const CLASSES := ["Bodyguard", "Architect", "Artificer"]

var game
var lv
var step := MOVE
var moon: DirectionalLight3D
var rain: CPUParticles3D
var fire_light: OmniLight3D
var spire: MeshInstance3D
var spire_sink := -1.0
var lightning_t := 4.0
var bolt_t := -1.0
var dark_amount := 0.0
var starts := {}
var swarm_left := 0
var swarm_t := 0.0
var told_torch := false
var told_noise := false


func begin(g) -> void:
	game = g
	lv = g.level
	moon = DirectionalLight3D.new()
	moon.light_color = Color("b4c4e8")
	moon.light_energy = 0.6
	moon.rotation_degrees = Vector3(-58, -35, 0)
	add_child(moon)

	fire_light = OmniLight3D.new()
	fire_light.light_color = Color("ffa040")
	fire_light.light_energy = 2.4
	fire_light.omni_range = 9.0
	fire_light.omni_attenuation = 1.1
	fire_light.position = lv.surface.camp + Vector3(0, 0.8, 0)
	add_child(fire_light)

	rain = CPUParticles3D.new()
	rain.amount = 1100
	rain.lifetime = 0.7
	rain.preprocess = 1.0
	rain.local_coords = false
	rain.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	rain.emission_box_extents = Vector3(13, 0.2, 10)
	rain.direction = Vector3(0.15, -1, 0.05)
	rain.spread = 3.0
	rain.initial_velocity_min = 15.0
	rain.initial_velocity_max = 19.0
	rain.gravity = Vector3(0, -9.8, 0)
	var drop := BoxMesh.new()
	drop.size = Vector3(0.015, 0.38, 0.015)
	var dm := StandardMaterial3D.new()
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.albedo_color = Color(0.7, 0.8, 1.0, 0.4)
	drop.material = dm
	rain.mesh = drop
	add_child(rain)

	# the sleeping creature wears an old stone spire: it looks like a ruined tower
	spire = MeshInstance3D.new()
	spire.mesh = VK.spire_mesh()
	spire.position = Vector3(-0.125, 0, -2.5)
	game.lift_root.add_child(spire)
	game.heart_light.light_energy = 0.35

	for c in lv.nest_spots:
		game._spawn_crawler(lv.cell_to_world(c), false, "critter")
	for p in game.players:
		starts[p] = p.global_position
	step = MOVE


func cleanup() -> void:
	if is_instance_valid(spire):
		spire.queue_free()
	queue_free()


# ------------------------------------------------------------------ text
func objective() -> String:
	match step:
		MOVE:
			return "Tutorial 1/8 - Walk around the camp"
		CLASS:
			return "Tutorial 2/8 - Everyone: pick a role at a class tent"
		CHOP:
			return "Tutorial 3/8 - Chop the fallen trees, dig the boulders"
		DARK:
			return "Tutorial 4/8 - Light the way through the dark woods"
		CRITTERS:
			return "Tutorial 5/8 - Critters! Shoot them"
		TO_TEMPLE:
			return "Tutorial 6/8 - Follow the trail west to the old temple"
		SEARCH:
			return "Tutorial 6/8 - Search the ruins for the glowing stone"
		CARRY:
			if game.shard_carrier == null:
				return "Tutorial 7/8 - Pick the heartstone back up (Interact)"
			if game._flat_dist(game.shard_carrier.global_position, game.lift_pos) < 6.0:
				return "Tutorial 7/8 - Put the heartstone into the tower (Interact)"
			return "Tutorial 7/8 - Follow the pulse to the ancient tower. Protect the carrier!"
		WAKE:
			return "Tutorial 8/8 - The tower is waking. Hold on!  %d" % ceili(maxf(game.charge_left, 0.0))
	return ""


func hint() -> String:
	match step:
		MOVE:
			return "Move: WASD / left stick.   More players: press A on a controller, or Enter for a 2nd keyboard player."
		CLASS:
			return "Walk to a tent door and press Interact (E / A).  Bodyguard = shotgun.  Architect = fast drill.  Artificer = torches + crafting."
		CHOP:
			return "Hold Dig (RMB or F / left trigger) facing a tree or boulder. Architects dig twice as fast."
		DARK:
			return "Place a torch: Q / Y.  Shooting and digging are loud: noise wakes sleeping things."
		CRITTERS:
			return "Aim with the mouse or right stick. Shoot: LMB / right trigger. Critters are slower in torchlight."
		TO_TEMPLE, SEARCH:
			return "Stand next to the glowing stone and press Interact to pick it up."
		CARRY:
			return "The carrier is slow and cannot shoot. Interact drops it. If someone goes down, hold Interact next to them."
		WAKE:
			return "Stay on the platform and keep the critters off it."
	return ""


# ------------------------------------------------------------------ interaction hooks
func try_interact(p) -> bool:
	if step > CLASS and p.cls != "":
		return false
	for t in lv.surface.tents:
		if game._flat_dist(p.global_position, t.door) < 1.5:
			p.set_class(t.cls)
			game.show_message("P%d is the %s\n%s" % [p.index + 1, t.cls, PlayerScript.CLASS_INFO[t.cls]], 3.0)
			game.debris(p.global_position + Vector3(0, 1.0, 0), t.color.lightened(0.3), 10)
			return true
	return false


func on_pickup(_p) -> void:
	if step < CARRY:
		step = CARRY
		swarm_left = 5
		swarm_t = 4.0
		game.pulse_t = 0.3
		game.show_message("It's heavy: the carrier is slow and can't shoot.\nThe temple pulses... the arrows point to the ancient tower!", 4.5)


func on_feed() -> void:
	step = WAKE
	spire_sink = 0.0
	game.show_message("The tower shakes off its stone...\nit's ALIVE! Hold on!", 4.0)


func auto_class_for(i: int) -> String:
	return CLASSES[i % 3]


# ------------------------------------------------------------------ update
func update(delta: float) -> void:
	_weather(delta)
	_dark_zone(delta)
	fire_light.light_energy = 2.2 + sin(Time.get_ticks_msec() * 0.013) * 0.25 + sin(Time.get_ticks_msec() * 0.031) * 0.15
	if spire_sink >= 0.0 and is_instance_valid(spire):
		spire_sink += delta
		spire.position.y = -spire_sink * 1.9
		spire.rotation.y = sin(spire_sink * 30.0) * 0.02
		if randf() < 0.5:
			game.debris(game.lift_pos + Vector3(randf_range(-0.8, 0.6), 0.2, -2.5 + randf_range(-0.6, 0.6)), Color("6c6862"), 1)
		if spire_sink > 2.4:
			spire.visible = false

	var players: Array = game.players
	match step:
		MOVE:
			for p in players:
				if starts.has(p) and p.global_position.distance_to(starts[p]) > 2.5:
					step = CLASS
					game.show_message("Good. Each tent gives a role.\nWalk to a tent door and press Interact.", 3.5)
					break
		CLASS:
			var ready := players.size() > 0
			for p in players:
				if p.cls == "":
					ready = false
			if ready:
				lv.open_cells(lv.surface.gate_cells)
				for c in lv.surface.gate_cells:
					if randf() < 0.3:
						game.debris(lv.cell_to_world(c) + Vector3(0, 0.4, 0), Color("6b4423"), 3)
				step = CHOP
				game.show_message("The crew is ready. The gate is open!\nFollow the trail north into the woods.", 3.5)
		CHOP:
			for p in players:
				if p.global_position.z < lv.surface.chop_line_z:
					step = DARK
					game.show_message("It's dark under the canopy.\nPlace a torch to light the way.", 3.5)
					break
		DARK, CRITTERS, TO_TEMPLE:
			var awake := 0
			for c in game.crawlers:
				if is_instance_valid(c) and c.kind == "critter" and c.state != CrawlerScript.SLEEP:
					awake += 1
			if step == DARK and awake > 0:
				step = CRITTERS
				game.show_message("Critters! Noise woke them up.\nShoot them!", 2.5)
			elif step == CRITTERS and awake == 0:
				step = TO_TEMPLE
				game.show_message("Nice shooting.\nThe trail continues west to the old temple.", 3.0)
			elif step == DARK and not told_torch:
				for t in game.torches:
					if lv.surface.dark_rect.has_point(Vector2(t.pos.x, t.pos.z)):
						told_torch = true
						game.show_message("Torches stay lit. They show the way back,\nand critters hate the light.", 3.0)
						break
			for p in players:
				if game._flat_dist(p.global_position, lv.surface.temple) < 7.5:
					step = SEARCH
					game.show_message("The old temple.\nSomething is glowing on the altar...", 3.0)
					break
		CARRY:
			if game.shard_carrier != null:
				swarm_t -= delta
				if swarm_t <= 0.0 and swarm_left > 0:
					swarm_t = 3.5
					swarm_left -= 1
					game._spawn_swarm(1, 12, 40, "critter")


func _dark_zone(delta: float) -> void:
	var center := Vector3.ZERO
	var n := 0
	for p in game.players:
		center += p.global_position
		n += 1
	if n == 0:
		return
	center /= n
	var inside: bool = lv.surface.dark_rect.has_point(Vector2(center.x, center.z))
	dark_amount = move_toward(dark_amount, 1.0 if inside else 0.0, delta * 0.8)
	game.env.ambient_light_energy = lerpf(0.52, 0.24, dark_amount)


func _weather(delta: float) -> void:
	rain.global_position = game.cam_target + Vector3(0, 7.5, 0)
	var base := lerpf(0.42, 0.08, dark_amount)
	lightning_t -= delta
	if lightning_t <= 0.0:
		lightning_t = randf_range(7.0, 14.0)
		bolt_t = 0.0
	var bolt := 0.0
	if bolt_t >= 0.0:
		bolt_t += delta
		if bolt_t < 0.07 or (bolt_t > 0.16 and bolt_t < 0.26):
			bolt = 2.6 if bolt_t < 0.07 else 1.8
		if bolt_t > 0.4:
			bolt_t = -1.0
	moon.light_energy = base + bolt
	if not game.is_blinking():
		game.flash_rect.color = Color(0.8, 0.88, 1.0, 0.1 if bolt > 0.0 else 0.0)
