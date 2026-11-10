extends Node3D

const VK = preload("res://scripts/voxel_kit.gd")
const Level = preload("res://scripts/level.gd")

const SPEED := 4.2
const CARRY_SPEED_MUL := 0.5
const RADIUS := 0.26
const SHOOT_COOLDOWN := 0.22
const REVIVE_TIME := 1.8
const MAX_HP := 5

var game
var input
var index := 0
var color := Color.WHITE

var hp := MAX_HP
var torches := 5
var ore := 0
var carrying := false
var downed := false
var revive_progress := 0.0

var facing := Vector3(0, 0, 1)
var aim := Vector3(0, 0, 1)
var shoot_cd := 0.0
var invuln := 0.0
var hurt_flash := 0.0
var walk_t := 0.0
var moving := false

var cls := ""
var gun := "pistol"
var dig_mul := 1.0
var gear: MeshInstance3D

var dig_cell := Vector2i(-1, -1)
var dig_progress := 0.0

var model: Node3D
var parts := {}
var carry_anchor: Node3D
var lamp: OmniLight3D
var dig_marker: MeshInstance3D
var tag: Label3D


func setup(g, inp, i: int, col: Color) -> void:
	game = g
	input = inp
	index = i
	color = col
	model = Node3D.new()
	add_child(model)
	var p := VK.character_parts(col)
	for pname in p:
		var mi := MeshInstance3D.new()
		mi.mesh = p[pname].mesh
		mi.position = p[pname].pivot
		model.add_child(mi)
		parts[pname] = mi
	carry_anchor = Node3D.new()
	carry_anchor.position = Vector3(0, 1.12, 0.05)
	model.add_child(carry_anchor)
	lamp = OmniLight3D.new()
	lamp.position = Vector3(0, 2.1, 0.2)
	lamp.light_color = Color("ffe9c7")
	lamp.light_energy = 1.35
	lamp.omni_range = 5.8
	lamp.omni_attenuation = 1.0
	add_child(lamp)
	dig_marker = MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.52, 1.04, 0.52)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1, 0.85, 0.4, 0.18)
	bm.material = mat
	dig_marker.mesh = bm
	dig_marker.top_level = true
	dig_marker.visible = false
	add_child(dig_marker)
	tag = Label3D.new()
	tag.text = "P%d" % (i + 1)
	tag.modulate = col.lightened(0.35)
	tag.outline_modulate = Color(0, 0, 0, 0.9)
	tag.font_size = 40
	tag.outline_size = 10
	tag.pixel_size = 0.006
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.no_depth_test = true
	tag.position = Vector3(0, 1.75, 0)
	add_child(tag)


func level():
	return game.level


func update(delta: float) -> void:
	input.poll()
	shoot_cd = maxf(0.0, shoot_cd - delta)
	invuln = maxf(0.0, invuln - delta)
	hurt_flash = maxf(0.0, hurt_flash - delta)
	if downed:
		_update_downed(delta)
		return
	model.rotation.x = 0
	tag.text = "P%d" % (index + 1)

	# move
	var mv: Vector2 = input.move
	var speed := SPEED * (CARRY_SPEED_MUL if carrying else 1.0)
	var dv := Vector3(mv.x, 0, mv.y) * speed * delta
	moving = mv.length() > 0.05
	if moving:
		game.move_entity(self, dv, RADIUS, true)
		facing = Vector3(mv.x, 0, mv.y).normalized()

	# aim
	aim = facing
	if input.device == "kbm" and input.mouse_active:
		var to: Vector3 = input.mouse_world - global_position
		to.y = 0
		if to.length() > 0.2:
			aim = to.normalized()
	elif input.aim_stick != Vector2.ZERO:
		aim = Vector3(input.aim_stick.x, 0, input.aim_stick.y).normalized()
	else:
		aim = game.auto_aim(global_position, facing)
	model.rotation.y = lerp_angle(model.rotation.y, atan2(aim.x, aim.z), clampf(delta * 18.0, 0, 1))

	# shoot
	if input.shoot and not carrying and shoot_cd <= 0.0:
		var muzzle := global_position + Vector3(0, 0.62, 0) + aim * 0.45
		if gun == "shotgun":
			shoot_cd = 0.5
			for k in [-0.16, 0.0, 0.16]:
				game.spawn_bullet(muzzle, aim.rotated(Vector3.UP, k + randf_range(-0.03, 0.03)), self, 0.38)
		else:
			shoot_cd = SHOOT_COOLDOWN
			game.spawn_bullet(muzzle, aim, self)

	# dig
	_update_dig(delta)

	# interact / revive
	if input.interact_pressed:
		game.player_interact(self)
	_update_revive_others(delta)

	# torch
	if input.torch_pressed and not carrying:
		if torches <= 0 and cls == "Artificer" and ore >= 2:
			ore -= 2
			torches += 1
			game.show_message("P%d crafted a torch from 2 ore" % (index + 1), 1.2)
		if torches > 0 and game.place_torch(global_position + aim * 0.35, false, cls == "Artificer"):
			torches -= 1

	_animate(delta)


func _update_dig(delta: float) -> void:
	dig_marker.visible = false
	if not input.dig or carrying:
		dig_progress = 0.0
		return
	var lv = level()
	var target := Vector2i(-1, -1)
	for d in [0.4, 0.65, 0.9]:
		var c: Vector2i = lv.world_to_cell(global_position + aim * d)
		if lv.can_dig(c):
			target = c
			break
		if not lv.is_floor(c):
			break
	if target.x < 0:
		dig_progress = 0.0
		return
	if target != dig_cell:
		dig_cell = target
		dig_progress = 0.0
	var t: int = lv.cell_at(target)
	var need: float = Level.DIG_TIME.get(t, 1.0) / dig_mul
	dig_progress += delta
	dig_marker.visible = true
	var wp: Vector3 = lv.cell_to_world(target)
	dig_marker.global_position = wp + Vector3(0, 0.52, 0)
	var k := clampf(dig_progress / need, 0, 1)
	dig_marker.scale = Vector3.ONE * (1.0 + 0.06 * sin(dig_progress * 40.0))
	(dig_marker.mesh.material as StandardMaterial3D).albedo_color = Color(1, 0.85 - k * 0.5, 0.4 - k * 0.3, 0.15 + k * 0.3)
	# arms chop while digging
	parts.arm_r.rotation.x = -1.2 + sin(dig_progress * 22.0) * 0.8
	if dig_progress >= need:
		var was: int = lv.dig(target)
		dig_progress = 0.0
		game.emit_noise(wp, 5.0)
		var col := Color("5a4030")
		if was == Level.ORE:
			ore += 1 + (1 if randf() < 0.3 else 0)
			col = Color("6fe8ff")
		elif was == Level.HARD:
			col = Color("55585f")
		elif was == Level.TREE:
			col = Color("3f7d36")
			game.debris(wp + Vector3(0, 0.3, 0), Color("6b4423"), 6)
		elif was == Level.BOULDER:
			col = Color("7d7973")
		game.debris(wp + Vector3(0, 0.6, 0), col, 10)


func _update_revive_others(delta: float) -> void:
	var reviving := false
	if input.interact:
		for o in game.players:
			if o != self and o.downed and o.global_position.distance_to(global_position) < 1.3:
				o.revive_progress += delta
				reviving = true
				if o.revive_progress >= REVIVE_TIME:
					o.revive()
				break
	if not reviving:
		for o in game.players:
			if o.downed:
				o.revive_progress = maxf(0.0, o.revive_progress - delta * 0.5)


func _update_downed(delta: float) -> void:
	dig_marker.visible = false
	model.rotation.x = lerpf(model.rotation.x, -PI / 2.0, clampf(delta * 8.0, 0, 1))
	tag.text = "HELP! %d%%" % int(revive_progress / REVIVE_TIME * 100.0) if revive_progress > 0.0 else "HELP!"
	lamp.light_energy = 0.4 + 0.25 * sin(Time.get_ticks_msec() * 0.008)


func hurt(n: int) -> void:
	if downed or invuln > 0.0:
		return
	hp -= n
	invuln = 0.7
	hurt_flash = 0.25
	game.debris(global_position + Vector3(0, 0.7, 0), Color("cc3b30"), 6)
	if hp <= 0:
		hp = 0
		downed = true
		revive_progress = 0.0
		if carrying:
			game.drop_shard(self)


func revive() -> void:
	downed = false
	hp = 3
	revive_progress = 0.0
	invuln = 1.5
	lamp.light_energy = 1.1
	game.show_message("P%d is back up!" % (index + 1), 1.5)


func _animate(delta: float) -> void:
	if moving:
		walk_t += delta * (9.0 if not carrying else 6.0)
	else:
		walk_t = lerpf(walk_t, roundf(walk_t / PI) * PI, clampf(delta * 10.0, 0, 1))
	var sw := sin(walk_t) * 0.7
	parts.leg_l.rotation.x = sw
	parts.leg_r.rotation.x = -sw
	if carrying:
		parts.arm_l.rotation.x = PI
		parts.arm_r.rotation.x = PI
	else:
		parts.arm_l.rotation.x = -sw * 0.8
		if not (input.dig and dig_marker.visible):
			parts.arm_r.rotation.x = -1.4 if shoot_cd > 0.1 else sw * 0.8
	model.position.y = absf(sin(walk_t)) * 0.04 if moving else 0.0
	var flash := hurt_flash > 0.0 and int(hurt_flash * 30.0) % 2 == 0
	model.visible = not flash


const CLASS_INFO := {
	"Bodyguard": "Shotgun: wide, close-range blast. Protects the shard carrier.",
	"Architect": "Hand drill: digs and chops twice as fast.",
	"Artificer": "Field kit: +4 torches, brighter lanterns, crafts torches from 2 ore."}


func set_class(c: String) -> void:
	cls = c
	gun = "pistol"
	dig_mul = 1.0
	match c:
		"Bodyguard":
			gun = "shotgun"
		"Architect":
			dig_mul = 2.2
		"Artificer":
			torches += 4
	if gear:
		gear.queue_free()
	gear = MeshInstance3D.new()
	gear.mesh = VK.class_gear_mesh(c)
	model.add_child(gear)


func clear_class() -> void:
	cls = ""
	gun = "pistol"
	dig_mul = 1.0
	if gear:
		gear.queue_free()
		gear = null
