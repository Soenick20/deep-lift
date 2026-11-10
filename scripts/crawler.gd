# Crawler: sleeps in nests, wakes on noise, hunts by path, slowed by torchlight.
extends Node3D

const VK = preload("res://scripts/voxel_kit.gd")

enum { SLEEP, INVESTIGATE, CHASE, DEAD }

const RADIUS := 0.22
const SPEED := 2.7
const SIGHT := 8.0
const ATTACK_RANGE := 0.75
const ATTACK_COOLDOWN := 0.9
# Crawlers get 6% faster per floor, up to this. At the cap a crawler runs 3.9 m/s against the
# player's 4.2, so a crew can always just outrun one (uncapped, they overtook players at floor 10).
const MAX_DEPTH_SPEED := 1.45

var game
var state := SLEEP
var hp := 3.0
var target_pos := Vector3.ZERO
var path := PackedVector3Array()
var path_i := 0
var repath_t := 0.0
var attack_cd := 0.0
var idle_t := 0.0
var flash := 0.0
var knock := Vector3.ZERO
var anim_t := 0.0

var body: MeshInstance3D
var legs_a: MeshInstance3D
var legs_b: MeshInstance3D
var zzz: Label3D

var kind := "crawler"
var speed_mul := 1.0
var radius := RADIUS
var damage := 1
var attack_range := ATTACK_RANGE
var hit_radius := 0.42          # how close a bullet must pass to hit; bigger bodies get more
var summon_t := 5.0
var max_hp := 3.0
static var _meshes: Dictionary


func setup(g, pos: Vector3, awake: bool, k: String = "crawler") -> void:
	game = g
	position = pos
	kind = k
	if not _meshes.has(kind):
		match kind:
			"critter":
				_meshes[kind] = VK.crawler_parts(0.045, Color("5b4a2c"), Color("8a7440"), Color("ff8a3d"))
			"brute":
				_meshes[kind] = VK.crawler_parts(0.1, Color("4a1d1d"), Color("9a3428"), Color("ffcc33"))
			"boss":
				_meshes[kind] = VK.crawler_parts(0.14, Color("2a1438"), Color("7a2a9a"), Color("ff5cf0"))
			_:
				_meshes[kind] = VK.crawler_parts()
	var m: Dictionary = _meshes[kind]
	if kind == "critter":
		hp = 1.0
		speed_mul = 0.85
	elif kind == "brute":
		hp = 16.0 + 3.0 * game.depth
		speed_mul = 0.72
		radius = 0.34
		hit_radius = 0.6     # the Brute's body is about 1.1 m x 1.3 m
		damage = 2
		attack_range = 1.15
	elif kind == "boss":
		hp = 45.0 + 6.0 * game.depth
		speed_mul = 0.62
		radius = 0.42
		hit_radius = 0.85    # the Hollow Mother's body is about 1.5 m x 1.8 m
		damage = 2
		attack_range = 1.45
	else:
		hp = 3.0 + 0.35 * maxf(game.depth - 1, 0)
	max_hp = hp
	body = MeshInstance3D.new()
	body.mesh = m.body
	add_child(body)
	legs_a = MeshInstance3D.new()
	legs_a.mesh = m.legs_a
	add_child(legs_a)
	legs_b = MeshInstance3D.new()
	legs_b.mesh = m.legs_b
	add_child(legs_b)
	zzz = Label3D.new()
	zzz.text = "z z"
	zzz.font_size = 36
	zzz.pixel_size = 0.006
	zzz.modulate = Color(0.75, 0.9, 1.0, 0.8)
	zzz.outline_size = 8
	zzz.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	zzz.position = Vector3(0, 0.75, 0)
	add_child(zzz)
	rotation.y = randf() * TAU
	anim_t = randf() * 10.0
	if awake:
		state = CHASE
	zzz.visible = state == SLEEP


func is_alive() -> bool:
	return state != DEAD


func hear(p: Vector3) -> void:
	if state == SLEEP or state == INVESTIGATE:
		state = INVESTIGATE
		target_pos = p
		repath_t = 0.0
		idle_t = 0.0
		zzz.visible = false


func hit(dmg: float, dir: Vector3) -> void:
	if state == DEAD:
		return
	hp -= dmg
	flash = 0.12
	knock = dir * (3.5 if not is_heavy() else 0.5)
	if state != CHASE:
		state = CHASE
		zzz.visible = false
	if hp <= 0.0:
		state = DEAD
		game.on_crawler_killed(self)
		game.debris(global_position + Vector3(0, 0.25, 0), Color("6a3f80") if kind == "crawler" else Color("8a7440"), 14)
		game.debris(global_position + Vector3(0, 0.25, 0), Color("c6ff3d"), 4)
		queue_free()


func update(delta: float) -> void:
	if state == DEAD:
		return
	anim_t += delta
	attack_cd = maxf(0.0, attack_cd - delta)
	flash = maxf(0.0, flash - delta)
	if is_heavy():
		body.scale = Vector3.ONE * (1.0 + flash * 0.6)
	else:
		body.visible = not (flash > 0.0 and int(flash * 40.0) % 2 == 0)
	if knock.length() > 0.05:
		game.move_entity(self, knock * delta, radius, false)
		knock = knock.lerp(Vector3.ZERO, clampf(delta * 10.0, 0, 1))

	match state:
		SLEEP:
			body.position.y = sin(anim_t * 2.0) * 0.01
			zzz.position.y = (1.4 if is_heavy() else 0.75) + fmod(anim_t * 0.3, 0.3)
			var near = game.nearest_player(global_position, false)
			if near and near.global_position.distance_to(global_position) < (4.5 if is_heavy() else 2.2):
				state = CHASE
				zzz.visible = false
		INVESTIGATE:
			var p = _see_player()
			if p:
				state = CHASE
			else:
				_follow_to(target_pos, delta, 0.75)
				if global_position.distance_to(target_pos) < 0.8:
					idle_t += delta
					if idle_t > 5.0:
						state = SLEEP
						zzz.visible = true
		CHASE:
			var p = game.nearest_player(global_position, false)
			if p == null:
				# everyone is down: drift toward the lift
				_follow_to(game.lift_pos, delta, 0.6)
				return
			var d: float = p.global_position.distance_to(global_position)
			if kind == "boss":
				summon_t -= delta
				if summon_t <= 0.0:
					summon_t = 7.0
					for i in 2:
						var off := Vector3(randf_range(-1.2, 1.2), 0, randf_range(-1.2, 1.2))
						if game.level.can_occupy(global_position + off, 0.22):
							game._spawn_crawler(global_position + off, true)
					game.show_message("The Hollow Mother calls her brood!", 1.5)
			if d < attack_range:
				_face(p.global_position - global_position, delta)
				if attack_cd <= 0.0:
					attack_cd = ATTACK_COOLDOWN * (1.4 if is_heavy() else 1.0)
					p.hurt(damage)
					body.position.z = 0.12
			else:
				_follow_to(p.global_position, delta, 1.0)
	body.position.z = lerpf(body.position.z, 0.0, clampf(delta * 8.0, 0, 1))


func _see_player():
	for p in game.players:
		if p.downed:
			continue
		var d: float = p.global_position.distance_to(global_position)
		if d < SIGHT and game.level.line_of_sight(global_position + Vector3(0, 0.3, 0), p.global_position + Vector3(0, 0.3, 0)):
			return p
	return null


func _follow_to(goal: Vector3, delta: float, speed_mul: float) -> void:
	repath_t -= delta
	var lv = game.level
	var direct: bool = global_position.distance_to(goal) < 3.0 and lv.line_of_sight(global_position, goal)
	var next := goal
	if not direct:
		if repath_t <= 0.0:
			repath_t = 0.45 + randf() * 0.2
			path = lv.path_world(global_position, goal)
			path_i = 1
		if path.size() > path_i:
			next = path[path_i]
			if Vector2(next.x, next.z).distance_to(Vector2(global_position.x, global_position.z)) < 0.3:
				path_i += 1
		else:
			return
	var to := next - global_position
	to.y = 0
	if to.length() < 0.05:
		return
	var spd: float = run_speed() * speed_mul
	if game.in_torchlight(global_position):
		spd *= 0.55
	game.move_entity(self, to.normalized() * spd * delta, radius, false)
	_face(to, delta)
	var step := sin(anim_t * 18.0) * 0.03
	legs_a.position.y = maxf(step, 0.0)
	legs_b.position.y = maxf(-step, 0.0)


# Full chase speed on this floor, before torchlight slows it.
func run_speed() -> float:
	return SPEED * speed_mul * minf(1.0 + 0.06 * game.depth, MAX_DEPTH_SPEED)


func _face(dir: Vector3, delta: float) -> void:
	if dir.length() > 0.01:
		rotation.y = lerp_angle(rotation.y, atan2(dir.x, dir.z), clampf(delta * 10.0, 0, 1))


func is_heavy() -> bool:
	return kind == "brute" or kind == "boss"
