# Deep Lift - Phase 1 prototype.
# One floor loop: blink in, find the heartshard, carry it back, feed the lift, hold the platform, blink deeper.
extends Node3D

const VK = preload("res://scripts/voxel_kit.gd")
const LevelScript = preload("res://scripts/level.gd")
const PlayerScript = preload("res://scripts/player.gd")
const CrawlerScript = preload("res://scripts/crawler.gd")
const PlayerInput = preload("res://scripts/player_input.gd")
const PrologueScript = preload("res://scripts/prologue.gd")
const Loot = preload("res://scripts/loot.gd")
const RunMap = preload("res://scripts/run_map.gd")
const MapPanel = preload("res://scripts/map_panel.gd")

enum { EXPLORE, CHARGING, BLINK, GAMEOVER, CHOOSE }

const PLAYER_COLORS := [Color("3f9a4f"), Color("3a6fd0"), Color("d9822b"), Color("9a55d6")]
const CHARGE_TIME := 20.0
const LEASH := 13.0
const LIFT_RADIUS := 2.15
const TORCH_LIGHT_RADIUS := 4.0
const MAX_TORCHES := 40
# How much light the mines have with no lamp, torch or ore nearby. It was 0.8, brighter than the
# prologue's dark woods (0.24), so torches did little for seeing. Lower = darker.
const MINE_AMBIENT := 0.35
const CLASSES := ["Bodyguard", "Architect", "Artificer"]

var level
var players: Array = []
var crawlers: Array = []
var bullets: Array = []
var bits: Array = []
var rings: Array = []
var torches: Array = []   # [{node, pos}]
var arrows: Array = []

var state := EXPLORE
var depth := 1
var run_seed := 0
var threat := 0.0
var charge_left := 0.0
var swarm_t := 0.0
var pulse_t := 0.0
var blink_t := 0.0
var gameover_t := 0.0
var blink_done := false
var _last_ring_ms := 0

var lift_root: Node3D
var lift_pos := Vector3.ZERO
var heart_light: OmniLight3D
var heart_socket: Node3D
var shard: Node3D
var shard_light: OmniLight3D
var shard_carrier = null
var shard_fed := false
var reachable := {}

var camera: Camera3D
var cam_target := Vector3.ZERO
var cam_dist := 12.0
var last_mouse_move := -100.0

# HUD
var hud: CanvasLayer
var objective_label: Label
var message_label: Label
var message_t := 0.0
var depth_label: Label
var threat_bar: ProgressBar
var threat_label: Label
var player_labels: Array = []
var hint_label: Label
var flash_rect: ColorRect

var _bit_meshes := {}
var pickups: Array = []      # [{node, kind, data, pos, t}]
var crates: Array = []       # [{node, cell, pocket, label}]
var stations: Array = []     # [{node, kind, local, label}]
var stations_root: Node3D
var bank_ore := 0
var loot_rng := RandomNumberGenerator.new()
var stash_label: Label
var _banked_msg := 0
var run_map = RunMap.new()
var act := 1
var floor_type := "mine"
var map_panel: Control
var pads: Array = []          # [{node, label, opt, pos}]
var choose_opts: Array = []
var choose_hold := 0.0
var pending: Dictionary = {}
var shard_locked := false
var cage: Node3D
var boss_ref = null
var boss_box: VBoxContainer
var boss_label: Label
var boss_bar: ProgressBar
var env: Environment
var mode := "mine"
var prologue = null
var skip_tutorial := false
var tutorial_done := false       # set once the crew has reached the mines; later runs start there
var _joy_wait_release := {}      # joypad id -> true: must let go of A/Start before it can join again
var _skip_prev := false
var autotest := false
var shot_dir := ""


func _ready() -> void:
	randomize()
	for a in OS.get_cmdline_user_args():
		if a == "--autotest":
			autotest = true
		elif a.begins_with("--shot="):
			shot_dir = a.substr(7)
		elif a == "--skip-tutorial":
			skip_tutorial = true
	_setup_world()
	_setup_hud()
	level = LevelScript.new()
	add_child(level)
	_build_lift()
	_build_shard()
	for i in 4:
		var a := MeshInstance3D.new()
		a.mesh = VK.arrow_mesh()
		a.visible = false
		add_child(a)
		arrows.append(a)
	_add_player("kbm", -1)
	start_run()
	if autotest:
		_run_autotest()
	elif shot_dir != "":
		_run_screenshots()


# ------------------------------------------------------------------ setup
func _setup_world() -> void:
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("050507")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("6a7590")
	env.ambient_light_energy = MINE_AMBIENT
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	camera = Camera3D.new()
	camera.fov = 38.0
	camera.far = 200.0
	add_child(camera)
	camera.current = true


func _label(size: int, col: Color = Color.WHITE) -> Label:
	var l := Label.new()
	var ls := LabelSettings.new()
	ls.font_size = size
	ls.font_color = col
	ls.outline_size = 8
	ls.outline_color = Color(0, 0, 0, 0.9)
	l.label_settings = ls
	return l


func _setup_hud() -> void:
	hud = CanvasLayer.new()
	add_child(hud)
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(root)

	objective_label = _label(26, Color("e8f6ff"))
	objective_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	objective_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	objective_label.position = Vector2(-500, 18)
	objective_label.size = Vector2(1000, 40)
	root.add_child(objective_label)

	depth_label = _label(22, Color("7ef6ff"))
	depth_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	depth_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	depth_label.position = Vector2(-200, 54)
	depth_label.size = Vector2(400, 30)
	root.add_child(depth_label)

	message_label = _label(32, Color("fff3d6"))
	message_label.set_anchors_preset(Control.PRESET_CENTER)
	message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message_label.position = Vector2(-560, -255)
	message_label.size = Vector2(1120, 120)
	message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(message_label)

	var tbox := VBoxContainer.new()
	tbox.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	tbox.position = Vector2(-330, 18)
	tbox.size = Vector2(300, 60)
	root.add_child(tbox)
	threat_label = _label(20, Color("ffb3a6"))
	threat_label.text = "THREAT"
	tbox.add_child(threat_label)
	threat_bar = ProgressBar.new()
	threat_bar.custom_minimum_size = Vector2(300, 22)
	threat_bar.show_percentage = false
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.1, 0.1, 0.12, 0.8)
	bg.set_corner_radius_all(6)
	var fg := StyleBoxFlat.new()
	fg.bg_color = Color("d9483b")
	fg.set_corner_radius_all(6)
	threat_bar.add_theme_stylebox_override("background", bg)
	threat_bar.add_theme_stylebox_override("fill", fg)
	tbox.add_child(threat_bar)
	stash_label = _label(20, Color("7ef6ff"))
	stash_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	stash_label.position = Vector2(-330, 82)
	stash_label.size = Vector2(300, 30)
	root.add_child(stash_label)
	map_panel = MapPanel.new()
	map_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	map_panel.position = Vector2(-390, 120)
	map_panel.size = Vector2(370, 150)
	map_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_panel.run_map = run_map
	root.add_child(map_panel)
	boss_box = VBoxContainer.new()
	boss_box.set_anchors_preset(Control.PRESET_CENTER_TOP)
	boss_box.position = Vector2(-260, 84)
	boss_box.size = Vector2(520, 50)
	root.add_child(boss_box)
	boss_label = _label(20, Color("ffb3a6"))
	boss_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	boss_box.add_child(boss_label)
	boss_bar = ProgressBar.new()
	boss_bar.custom_minimum_size = Vector2(520, 16)
	boss_bar.show_percentage = false
	var bbg := StyleBoxFlat.new()
	bbg.bg_color = Color(0.1, 0.05, 0.08, 0.85)
	bbg.set_corner_radius_all(5)
	var bfg := StyleBoxFlat.new()
	bfg.bg_color = Color("c0392b")
	bfg.set_corner_radius_all(5)
	boss_bar.add_theme_stylebox_override("background", bbg)
	boss_bar.add_theme_stylebox_override("fill", bfg)
	boss_box.add_child(boss_bar)
	boss_box.visible = false

	var pbox := VBoxContainer.new()
	pbox.position = Vector2(20, 100)
	root.add_child(pbox)
	for i in 4:
		var l := RichTextLabel.new()
		l.bbcode_enabled = true
		l.fit_content = true
		l.scroll_active = false
		l.autowrap_mode = TextServer.AUTOWRAP_OFF
		l.custom_minimum_size = Vector2(900, 0)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.add_theme_font_size_override("normal_font_size", 19)
		l.add_theme_constant_override("outline_size", 7)
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		l.add_theme_color_override("default_color", PLAYER_COLORS[i].lightened(0.35))
		pbox.add_child(l)
		player_labels.append(l)

	hint_label = _label(17, Color("aab4c3"))
	hint_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_label.position = Vector2(-800, -64)
	hint_label.size = Vector2(1600, 50)
	root.add_child(hint_label)

	flash_rect = ColorRect.new()
	flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	flash_rect.color = Color(0.85, 1.0, 1.0, 0.0)
	flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(flash_rect)


func _build_lift() -> void:
	lift_root = Node3D.new()
	add_child(lift_root)
	var m := VK.lift_meshes()
	for k in ["platform", "head"]:
		var mi := MeshInstance3D.new()
		mi.mesh = m[k]
		lift_root.add_child(mi)
	heart_socket = Node3D.new()
	heart_socket.position = Vector3(0, 0.5, 0)
	lift_root.add_child(heart_socket)
	heart_light = OmniLight3D.new()
	heart_light.position = Vector3(0, 1.2, 0)
	heart_light.light_color = Color("7ef6ff")
	heart_light.omni_range = 4.0
	heart_light.light_energy = 0.7
	lift_root.add_child(heart_light)
	stations_root = Node3D.new()
	lift_root.add_child(stations_root)
	var defs := [
		["workbench", VK.workbench_mesh(), Vector3(-1.62, 0.25, 0.1), PI / 2.0],
		["medbay", VK.medbay_mesh(), Vector3(1.62, 0.25, 0.15), 0.0],
		["torches", VK.torch_rack_mesh(), Vector3(0.0, 0.25, 1.72), 0.0]]
	for dfn in defs:
		var mi := MeshInstance3D.new()
		mi.mesh = dfn[1]
		mi.position = dfn[2]
		mi.rotation.y = dfn[3]
		stations_root.add_child(mi)
		var lab := Label3D.new()
		lab.font_size = 34
		lab.outline_size = 9
		lab.pixel_size = 0.006
		lab.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lab.no_depth_test = true
		lab.position = dfn[2] + Vector3(0, 1.15, 0)
		lab.visible = false
		stations_root.add_child(lab)
		stations.append({"node": mi, "kind": dfn[0], "local": dfn[2], "label": lab})


func _build_shard() -> void:
	shard = Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = VK.shard_mesh()
	mi.name = "Crystal"
	shard.add_child(mi)
	shard_light = OmniLight3D.new()
	shard_light.light_color = Color("8ff2ff")
	shard_light.omni_range = 4.8
	shard_light.light_energy = 1.8
	shard_light.position = Vector3(0, 0.4, 0)
	shard.add_child(shard_light)
	add_child(shard)
	cage = Node3D.new()
	var bar_mesh := VK.box_mesh(Vector3(0.05, 1.1, 0.05), Color("ff6a3d"), true)
	for i in 6:
		var a := TAU * i / 6.0
		var b := MeshInstance3D.new()
		b.mesh = bar_mesh
		b.position = Vector3(cos(a) * 0.38, 0.55, sin(a) * 0.38)
		cage.add_child(b)
	var edge_x := VK.box_mesh(Vector3(0.8, 0.04, 0.04), Color("ff6a3d"), true)
	var edge_z := VK.box_mesh(Vector3(0.04, 0.04, 0.8), Color("ff6a3d"), true)
	for sgn in [-1.0, 1.0]:
		var ex := MeshInstance3D.new()
		ex.mesh = edge_x
		ex.position = Vector3(0, 1.1, sgn * 0.38)
		cage.add_child(ex)
		var ez := MeshInstance3D.new()
		ez.mesh = edge_z
		ez.position = Vector3(sgn * 0.38, 1.1, 0)
		cage.add_child(ez)
	cage.visible = false
	add_child(cage)


func _add_player(dev: String, joy: int):
	var p = PlayerScript.new()
	# take the lowest free player number, so a slot freed by someone leaving is reused
	var taken: Array = players.map(func(o): return o.index)
	var i := 0
	while i in taken:
		i += 1
	add_child(p)
	p.setup(self, PlayerInput.make(dev, joy), i, PLAYER_COLORS[i])
	var base := lift_pos
	if players.size() > 0:
		base = players[0].global_position
	p.position = base + Vector3((i % 2) * 0.9 - 0.45, 0, (i / 2) * 0.9 - 0.45)
	p.position.y = ground_y(p.position)
	players.append(p)
	players.sort_custom(func(a, b): return a.index < b.index)
	_refresh_player_labels()
	if mode == "mine" or (prologue and prologue.step > PrologueScript.CLASS):
		p.set_class(CLASSES[i % 3])
	return p


# A player drops out: they hand over what they carry and their slot is free again.
func _remove_player(p, why: String) -> void:
	if p.carrying:
		drop_shard(p)
	if p.ore > 0:
		drop_ore(p.global_position, p.ore)
	if p.input.device == "joy":
		_joy_wait_release[p.input.joy_id] = true
	players.erase(p)
	p.queue_free()
	_refresh_player_labels()
	show_message("P%d %s." % [p.index + 1, why], 1.5)


func _refresh_player_labels() -> void:
	for i in players.size():
		player_labels[i].add_theme_color_override("default_color", PLAYER_COLORS[players[i].index].lightened(0.35))


# ------------------------------------------------------------------ run / floor flow
func start_run() -> void:
	depth = 1
	run_seed = randi()
	bank_ore = 0
	loot_rng.seed = run_seed + 17
	var roles: Array = []
	for p in players:
		roles.append(p.cls)
		p.hp = PlayerScript.MAX_HP
		p.torches = 5
		p.ore = 0
		p.downed = false
		p.clear_class()
	act = 1
	run_map = RunMap.new()
	map_panel.run_map = run_map
	if skip_tutorial or tutorial_done:
		# once the crew has seen the tutorial, a new run starts in the mines with the same roles
		for i in players.size():
			if roles[i] != "":
				players[i].set_class(roles[i])
		run_map.generate(loot_rng)
		start_floor(1)
		show_message("The old lift wakes in the dark.\nFind the heartshard and bring it home.", 4.0)
	else:
		start_prologue()


func _clear_floor_objects() -> void:
	for c in crawlers:
		if is_instance_valid(c):
			c.queue_free()
	crawlers.clear()
	for b in bullets:
		b.node.queue_free()
	bullets.clear()
	for t in torches:
		t.node.queue_free()
	torches.clear()
	for pk in pickups:
		pk.node.queue_free()
	pickups.clear()
	for cr in crates:
		cr.node.queue_free()
	crates.clear()
	_clear_pads()
	shard_locked = false
	cage.visible = false
	boss_ref = null
	if shard.get_parent() != self:
		shard.reparent(self)
	shard_fed = false
	shard_carrier = null
	shard.rotation = Vector3.ZERO


func start_prologue() -> void:
	mode = "surface"
	depth = 0
	_clear_floor_objects()
	if prologue:
		prologue.cleanup()
	level.generate_surface(run_seed)
	stations_root.visible = false
	lift_pos = level.cell_to_world(level.lift_cell)
	lift_root.position = lift_pos
	shard.position = level.surface.altar
	env.background_color = Color("0b1122")
	env.ambient_light_color = Color("7486b0")
	env.ambient_light_energy = 0.52
	var camp: Vector3 = level.surface.camp
	for i in players.size():
		var p = players[i]
		p.carrying = false
		p.downed = false
		p.hp = PlayerScript.MAX_HP
		var a := TAU * i / maxf(players.size(), 1) - PI / 2.0 + 0.5
		p.position = camp + Vector3(cos(a), 0, sin(a)) * 2.3
	reachable = level.reachable_cells_from(level.lift_cell)
	prologue = PrologueScript.new()
	add_child(prologue)
	prologue.begin(self)
	threat = 0.0
	pulse_t = 999.0
	state = EXPLORE
	cam_target = camp
	show_message("The first night. A storm rolls over the camp.\nSomewhere in these woods, something old is sleeping.", 5.0)


func is_blinking() -> bool:
	return state == BLINK


func start_floor(d: int, ftype: String = "mine") -> void:
	depth = d
	floor_type = ftype
	if run_map.layers.is_empty():
		run_map.generate(loot_rng)
	mode = "mine"
	tutorial_done = true
	if prologue:
		prologue.cleanup()
		prologue = null
	env.background_color = Color("050507")
	env.ambient_light_color = Color("6a7590")
	env.ambient_light_energy = MINE_AMBIENT
	_clear_floor_objects()
	for i in players.size():
		if players[i].cls == "":
			players[i].set_class(CLASSES[i % 3])
	var t_gen := Time.get_ticks_msec()
	level.generate(run_seed + d * 7919, d, ftype)
	print("depth %d generated in %d ms" % [d, Time.get_ticks_msec() - t_gen])
	lift_pos = level.cell_to_world(level.lift_cell)
	lift_root.position = lift_pos
	heart_light.light_energy = 0.7
	# lift torches
	for o in [Vector3(1.55, 0, 1.55), Vector3(-1.55, 0, 1.55), Vector3(1.55, 0, -1.55), Vector3(-1.55, 0, -1.55)]:
		place_torch(lift_pos + o, true)
	# shard
	shard_fed = false
	shard_carrier = null
	if shard.get_parent() != self:
		shard.reparent(self)
	shard.position = level.cell_to_world(level.shard_cell) + Vector3(0, 0.15, 0)
	shard.rotation = Vector3.ZERO
	shard.scale = Vector3.ONE
	# monsters
	for c in level.nest_spots:
		_spawn_crawler(level.cell_to_world(c), false)
	# loot crates and the lift's stations
	stations_root.visible = true
	for sp in level.crate_spots:
		_spawn_crate(sp.cell, sp.pocket)
	if ftype == "miniboss" or ftype == "boss":
		boss_ref = _spawn_crawler(level.cell_to_world(level.boss_spot), false, "brute" if ftype == "miniboss" else "boss")
		shard_locked = true
		cage.visible = true
		cage.global_position = Vector3(shard.global_position.x, 0, shard.global_position.z)
	# players onto the platform
	for i in players.size():
		var p = players[i]
		p.carrying = false
		p.downed = false
		p.hp = mini(p.hp + 2, PlayerScript.MAX_HP) if p.hp > 0 else 3
		p.torches = maxi(p.torches, mini(p.torches + 2, 8))   # top up to 8, never take torches away
		var a := TAU * i / maxf(players.size(), 1) + 0.6
		p.position = lift_pos + Vector3(cos(a), 0, sin(a)) * 0.9
		p.position.y = ground_y(p.position)
	reachable = level.reachable_cells_from(level.lift_cell)
	threat = 0.0
	pulse_t = 1.0
	state = EXPLORE
	cam_target = lift_pos


func _spawn_crawler(pos: Vector3, awake: bool, kind: String = "crawler"):
	var c = CrawlerScript.new()
	add_child(c)
	c.setup(self, pos, awake, kind)
	crawlers.append(c)
	return c


func _spawn_swarm(n: int, min_cells: int, max_cells: int, kind: String = "") -> void:
	if kind == "":
		kind = "critter" if mode == "surface" else "crawler"
	var band: Array = []
	for k in reachable:
		var dist: int = reachable[k]
		if dist >= min_cells and dist <= max_cells:
			band.append(k)
	if band.is_empty():
		for k in reachable:
			if reachable[k] >= 10:
				band.append(k)
	if band.is_empty():
		return
	for i in n:
		var c: Vector2i = band[randi() % band.size()]
		var wp: Vector3 = level.cell_to_world(c)
		if in_torchlight(wp):
			continue
		_spawn_crawler(wp, true, kind)


# ------------------------------------------------------------------ main loop
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		last_mouse_move = Time.get_ticks_msec() / 1000.0


func _process(delta: float) -> void:
	delta = minf(delta, 0.05)
	_check_joins()
	_check_leaves(delta)
	_update_mouse()
	var skip_now := Input.is_physical_key_pressed(KEY_TAB)
	for id in Input.get_connected_joypads():
		skip_now = skip_now or Input.is_joy_button_pressed(id, JOY_BUTTON_BACK)
	if skip_now and not _skip_prev and mode == "surface" and state == EXPLORE:
		start_floor(1)
		show_message("Tutorial skipped.\nThe old lift wakes in the dark. Find the heartshard.", 3.5)
	_skip_prev = skip_now
	if prologue:
		prologue.update(delta)
	for p in players:
		p.update(delta)
	for c in crawlers:
		if is_instance_valid(c):
			c.update(delta)
	crawlers = crawlers.filter(func(c): return is_instance_valid(c) and c.is_alive())
	_update_bullets(delta)
	_update_bits(delta)
	_update_rings(delta)
	_update_shard(delta)
	_update_loot(delta)
	_update_state(delta)
	_update_pulse(delta)
	_update_camera(delta)
	_update_hud(delta)


func _update_state(delta: float) -> void:
	match state:
		EXPLORE:
			if mode == "mine":
				threat += delta * (0.45 + 0.06 * depth) * (1.35 if floor_type == "vault" else 1.0)
			if threat >= 100.0:
				threat = 30.0
				_spawn_swarm(3 + depth / 2, 20, 60)
				show_message("The dark stirs... something is coming.", 2.5)
		CHARGING:
			charge_left -= delta
			swarm_t -= delta
			heart_light.light_energy = 2.5 + sin(Time.get_ticks_msec() * 0.01) * 0.8
			if swarm_t <= 0.0:
				swarm_t = maxf(0.8, 2.0 - depth * 0.08)
				_spawn_swarm(1 + (1 if randf() < 0.12 * depth else 0), 22, 50)
			if charge_left <= 0.0:
				_after_charge()
		CHOOSE:
			_update_choose(delta)
		BLINK:
			blink_t += delta
			flash_rect.color.a = clampf(1.0 - absf(blink_t - 0.45) / 0.45, 0, 1) if blink_t < 0.9 else maxf(0.0, 1.0 - (blink_t - 0.9) * 1.5)
			if blink_t >= 0.45 and not blink_done:
				blink_done = true
				var from_surface := mode == "surface"
				if pending.has("opt"):
					run_map.advance(pending.opt)
					start_floor(depth + 1, run_map.current_type())
				else:
					if not from_surface:
						act += 1
					run_map.generate(loot_rng)
					start_floor(depth + 1, "mine")
				state = BLINK
				var info: Dictionary = RunMap.INFO[floor_type]
				if from_surface:
					show_message("BLINK!\nThe creature dives into the deep. Depth 1: the mines.", 4.0)
				elif not pending.has("opt"):
					show_message("BLINK!  The creature dives deeper.\nDEPTH %d begins." % act, 3.5)
				else:
					show_message("BLINK!  %s\n%s" % [info.name, info.desc], 3.0)
				pending = {}
			if blink_t >= 1.6:
				flash_rect.color.a = 0.0
				state = EXPLORE
		GAMEOVER:
			gameover_t += delta
			if gameover_t > 1.0:
				for p in players:
					if p.input.interact_pressed:
						start_run()
						return
	if state != GAMEOVER and state != BLINK and players.size() > 0:
		var all_down := true
		for p in players:
			if not p.downed:
				all_down = false
		if all_down:
			state = GAMEOVER
			gameover_t = 0.0
			show_message("The dark took the crew at depth %d.\nPress interact to dive again." % depth, 999.0)


func feed(p) -> void:
	p.carrying = false
	shard_carrier = null
	shard_fed = true
	shard.reparent(heart_socket)
	shard.position = Vector3.ZERO
	shard.rotation = Vector3.ZERO
	state = CHARGING
	charge_left = CHARGE_TIME
	swarm_t = 2.0
	emit_noise(lift_pos, 30.0)
	show_message("The lift drinks the heartshard...\nHOLD THE PLATFORM!", 3.0)
	if prologue:
		charge_left = 12.0
		swarm_t = 1.5
		prologue.on_feed()


func pick_up(p) -> void:
	if shard_locked:
		show_message("The %s guards the heartshard. Defeat it first!" % ("Brute" if floor_type == "miniboss" else "Hollow Mother"), 2.0)
		return
	shard_carrier = p
	p.carrying = true
	shard.reparent(p.carry_anchor)
	shard.position = Vector3(0, 0.05, 0)
	shard.rotation = Vector3.ZERO
	emit_noise(p.global_position, 7.0)
	show_message("P%d has the heartshard!\nIt is heavy: protect them on the way back." % (p.index + 1), 3.0)
	if prologue:
		prologue.on_pickup(p)


func drop_shard(p) -> void:
	p.carrying = false
	shard_carrier = null
	shard.reparent(self)
	shard.global_position = Vector3(p.global_position.x, 0.15, p.global_position.z)
	shard.rotation = Vector3.ZERO


func player_interact(p) -> void:
	if state == GAMEOVER or state == BLINK or state == CHOOSE:
		return
	if prologue and prologue.try_interact(p):
		return
	if p.carrying:
		if state == EXPLORE and _flat_dist(p.global_position, lift_pos) < LIFT_RADIUS + 0.4:
			feed(p)
		else:
			drop_shard(p)
		return
	if not shard_fed and shard_carrier == null and _flat_dist(p.global_position, shard.global_position) < 1.3:
		pick_up(p)
		return
	if _try_loot_interact(p):
		return
	for o in players:
		if o != p and o.downed and o.global_position.distance_to(p.global_position) < 1.3:
			return  # reviving is handled by holding interact
	if state == EXPLORE and _flat_dist(p.global_position, lift_pos) < LIFT_RADIUS:
		show_message("The tower hums. It wants the heartstone." if prologue else "The lift is hungry. Bring it the heartshard.", 2.0)


# ------------------------------------------------------------------ world helpers
func _flat_dist(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


func ground_y(p: Vector3) -> float:
	return 0.25 if _flat_dist(p, lift_pos) < LIFT_RADIUS else 0.0


func move_entity(e, dv: Vector3, r: float, is_player: bool) -> void:
	var pos: Vector3 = e.position
	for axis in [0, 2]:
		var np := pos
		np[axis] += dv[axis]
		if not level.can_occupy(np, r):
			continue
		if is_player and _breaks_leash(e, pos, np):
			continue
		pos = np
	pos.y = ground_y(pos)
	e.position = pos


func _breaks_leash(e, old: Vector3, np: Vector3) -> bool:
	for o in players:
		if o == e or o.downed:
			continue
		var dn := _flat_dist(np, o.global_position)
		if dn > LEASH and dn > _flat_dist(old, o.global_position):
			return true
	return false


func nearest_player(pos: Vector3, include_downed: bool):
	var best = null
	var bd := 1e9
	for p in players:
		if p.downed and not include_downed:
			continue
		var d := pos.distance_to(p.global_position)
		if d < bd:
			bd = d
			best = p
	return best


func auto_aim(pos: Vector3, facing: Vector3) -> Vector3:
	var best := facing
	var best_d := 9.0
	for c in crawlers:
		if not is_instance_valid(c) or c.state == CrawlerScript.SLEEP:
			continue
		var to: Vector3 = c.global_position - pos
		to.y = 0
		var d := to.length()
		if d < best_d and to.normalized().dot(facing) > 0.8 and level.line_of_sight(pos, c.global_position):
			best_d = d
			best = to.normalized()
	return best


func in_torchlight(p: Vector3) -> bool:
	for t in torches:
		if _flat_dist(p, t.pos) < TORCH_LIGHT_RADIUS:
			return true
	return false


func place_torch(p: Vector3, is_lift: bool = false, bright: bool = false) -> bool:
	if torches.size() >= MAX_TORCHES and not is_lift:
		show_message("Too many torches on this floor.", 1.2)
		return false
	if not is_lift and not level.is_floor(level.world_to_cell(p)):
		return false
	var n := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = _torch_mesh()
	n.add_child(mi)
	var l := OmniLight3D.new()
	l.light_color = Color("ff9a3c")
	l.light_energy = 2.2 if bright else 1.8
	l.omni_range = 8.5 if bright else 7.0
	l.omni_attenuation = 1.1
	l.position = Vector3(0, 0.6, 0)
	n.add_child(l)
	add_child(n)
	n.position = Vector3(p.x, ground_y(p), p.z)
	torches.append({"node": n, "pos": n.position})
	return true


var _torch_mesh_cache: ArrayMesh
func _torch_mesh() -> ArrayMesh:
	if _torch_mesh_cache == null:
		_torch_mesh_cache = VK.torch_mesh()
	return _torch_mesh_cache


# threat_add: how much this noise adds to the threat meter; left out, it follows the radius.
func emit_noise(pos: Vector3, radius: float, threat_add: float = -1.0) -> void:
	for c in crawlers:
		if is_instance_valid(c) and c.is_alive() and c.global_position.distance_to(pos) < radius:
			c.hear(pos)
	if state == EXPLORE and mode == "mine":
		threat = minf(100.0, threat + (threat_add if threat_add >= 0.0 else radius * Loot.THREAT_PER_NOISE))
	var now := Time.get_ticks_msec()
	if radius >= 5.0 and now - _last_ring_ms > 350:
		_last_ring_ms = now
		_spawn_ring(pos, radius)


func spawn_bullet(origin: Vector3, dir: Vector3, owner, life: float = 0.75, w: Dictionary = {}, noisy: bool = true) -> void:
	var mi := MeshInstance3D.new()
	var col := Color("ffe08a")
	if w.get("rarity", 0) == 1:
		col = Color("8cc8ff")
	elif w.get("rarity", 0) == 2:
		col = Color("d9a8ff")
	mi.mesh = _bit_mesh(col, true, 0.11 if w.get("type", "") == "Rifle" else 0.09)
	add_child(mi)
	mi.global_position = origin
	bullets.append({"node": mi, "dir": dir, "life": life, "dmg": w.get("dmg", 1.0), "speed": w.get("speed", 20.0), "pierce": w.get("pierce", 0), "hit": []})
	if noisy:
		emit_noise(owner.global_position, w.get("noise", 9.0), Loot.threat_per_shot(w))


func _update_bullets(delta: float) -> void:
	var keep: Array = []
	for b in bullets:
		var hit := false
		var steps := 4
		for s in steps:
			var np: Vector3 = b.node.global_position + b.dir * b.speed * delta / steps
			if level.is_solid_world(np):
				debris(np - b.dir * 0.1, Color("ffcf6a"), 3)
				hit = true
				break
			for c in crawlers:
				if is_instance_valid(c) and c.is_alive() and not (c in b.hit) and _flat_dist(np, c.global_position) < c.hit_radius:
					c.hit(b.dmg, b.dir)
					if b.pierce > 0:
						b.pierce -= 1
						b.hit.append(c)
					else:
						hit = true
					break
			if hit:
				break
			b.node.global_position = np
		b.life -= delta
		if hit or b.life <= 0.0:
			b.node.queue_free()
		else:
			keep.append(b)
	bullets = keep


func _bit_mesh(col: Color, glow: bool, size: float) -> BoxMesh:
	var key := "%s-%s-%s" % [col.to_html(), glow, size]
	if not _bit_meshes.has(key):
		_bit_meshes[key] = VK.box_mesh(Vector3.ONE * size, col, glow)
	return _bit_meshes[key]


func debris(pos: Vector3, col: Color, n: int) -> void:
	for i in n:
		var mi := MeshInstance3D.new()
		mi.mesh = _bit_mesh(col, col.v > 0.8, 0.07)
		add_child(mi)
		mi.global_position = pos + Vector3(randf_range(-0.15, 0.15), randf_range(-0.1, 0.15), randf_range(-0.15, 0.15))
		bits.append({"node": mi, "vel": Vector3(randf_range(-2, 2), randf_range(1.5, 4), randf_range(-2, 2)), "life": randf_range(0.5, 0.9)})


func _update_bits(delta: float) -> void:
	var keep: Array = []
	for b in bits:
		b.vel.y -= 12.0 * delta
		var p: Vector3 = b.node.global_position + b.vel * delta
		if p.y < 0.035:
			p.y = 0.035
			b.vel *= Vector3(0.6, -0.3, 0.6)
		b.node.global_position = p
		b.life -= delta
		b.node.scale = Vector3.ONE * clampf(b.life * 2.0, 0.0, 1.0)
		if b.life <= 0.0:
			b.node.queue_free()
		else:
			keep.append(b)
	bits = keep


func _spawn_ring(pos: Vector3, radius: float) -> void:
	var mi := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.96
	tm.outer_radius = 1.0
	tm.rings = 48
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.75, 0.5, 0.1)
	tm.material = mat
	mi.mesh = tm
	add_child(mi)
	mi.global_position = Vector3(pos.x, 0.06, pos.z)
	mi.scale = Vector3(0.3, 0.05, 0.3)
	rings.append({"node": mi, "t": 0.0, "r": radius, "mat": mat})


func _update_rings(delta: float) -> void:
	var keep: Array = []
	for r in rings:
		r.t += delta
		var k: float = r.t / 0.45
		var rad: float = lerpf(0.3, r.r, sqrt(k))
		r.node.scale = Vector3(rad, 0.05, rad)
		r.mat.albedo_color.a = 0.1 * (1.0 - k)
		if k >= 1.0:
			r.node.queue_free()
		else:
			keep.append(r)
	rings = keep


func _update_shard(delta: float) -> void:
	var crystal: Node3D = shard.get_node("Crystal")
	crystal.rotation.y += delta * 1.2
	crystal.position.y = 0.0 if (shard_carrier != null or shard_fed) else 0.12 + sin(Time.get_ticks_msec() * 0.003) * 0.08
	shard_light.light_energy = 1.8 + sin(Time.get_ticks_msec() * 0.004) * 0.4


# The lift pulses: an arrow by each player points roughly at the shard, or home when carrying.
func _update_pulse(delta: float) -> void:
	pulse_t -= delta
	if mode == "surface" and shard_carrier == null:
		pulse_t = maxf(pulse_t, 0.3)
	if pulse_t <= 0.0 and state == EXPLORE:
		pulse_t = 3.5
		var target := lift_pos if (shard_carrier != null) else shard.global_position
		for i in players.size():
			var p = players[i]
			var a = arrows[i]
			if p.downed:
				continue
			var to: Vector3 = target - p.global_position
			to.y = 0
			if to.length() < 2.5:
				continue
			var ang := atan2(to.x, to.z)
			if shard_carrier == null:
				ang += randf_range(-0.35, 0.35)   # rough, never exact
			a.set_meta("t", 1.8)
			a.set_meta("ang", ang)
			a.visible = true
	for i in arrows.size():
		var a = arrows[i]
		if not a.visible:
			continue
		var t: float = a.get_meta("t", 0.0) - delta
		a.set_meta("t", t)
		if t <= 0.0 or i >= players.size():
			a.visible = false
			continue
		var p = players[i]
		var ang: float = a.get_meta("ang", 0.0)
		var dir := Vector3(sin(ang), 0, cos(ang))
		a.global_position = p.global_position + dir * (1.3 + (1.8 - t) * 0.4) + Vector3(0, 1.15, 0)
		a.rotation.y = ang + PI  # the arrow model points along -z
		var s := clampf(t / 0.4, 0.0, 1.0)
		a.scale = Vector3.ONE * s


# ------------------------------------------------------------------ joining, mouse, camera
func _check_joins() -> void:
	if players.size() >= 4 or state == GAMEOVER:
		return
	var used_kb2 := false
	var used_joys := []
	for p in players:
		if p.input.device == "kb2":
			used_kb2 = true
		elif p.input.device == "joy":
			used_joys.append(p.input.joy_id)
	if not used_kb2 and PlayerInput.kb2_join_pressed() and not autotest and shot_dir == "":
		var p = _add_player("kb2", -1)
		show_message("P%d joined (2nd keyboard)! Hold Backspace to leave." % (p.index + 1), 2.0)
		return
	for id in Input.get_connected_joypads():
		if id in used_joys:
			continue
		if _joy_wait_release.has(id):
			# this pad just left: it must let go of A/Start before it can join again
			if not PlayerInput.joy_join_pressed(id):
				_joy_wait_release.erase(id)
			continue
		if PlayerInput.joy_join_pressed(id):
			var p = _add_player("joy", id)
			show_message("P%d joined (controller)! Hold Start to leave." % (p.index + 1), 2.0)
			return


# Players 2-4 can drop out by holding their leave button for a second, and a controller that
# disconnects takes its player with it. Otherwise an idle player holds the others on the leash,
# and blocks the class gate and the path vote.
func _check_leaves(delta: float) -> void:
	var connected := Input.get_connected_joypads()
	for p in players.duplicate():
		var inp = p.input
		if inp.scripted or inp.device == "kbm":
			continue
		if inp.device == "joy" and not (inp.joy_id in connected):
			_remove_player(p, "left (controller disconnected)")
			continue
		if not inp.leave_held:
			p.leave_armed = true
			p.leave_t = 0.0
		elif p.leave_armed:
			p.leave_t += delta
			if p.leave_t >= 1.0:
				_remove_player(p, "left the crew")


func _update_mouse() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	for p in players:
		if p.input.device != "kbm" or p.input.scripted:
			continue
		var mp := get_viewport().get_mouse_position()
		var from := camera.project_ray_origin(mp)
		var dir := camera.project_ray_normal(mp)
		if absf(dir.y) > 0.001:
			var t := (0.6 - from.y) / dir.y
			p.input.mouse_world = from + dir * t
		p.input.mouse_active = (now - last_mouse_move) < 3.0 or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)


func _update_camera(delta: float) -> void:
	if players.is_empty():
		return
	var sum := Vector3.ZERO
	var n := 0
	for p in players:
		if not p.downed:
			sum += p.global_position
			n += 1
	if n == 0:
		for p in players:
			sum += p.global_position
		n = players.size()
	var center := sum / n
	var spread := 0.0
	for p in players:
		spread = maxf(spread, _flat_dist(p.global_position, center))
	var want_dist := clampf(11.0 + spread * 1.5, 11.0, 26.0)
	var k := clampf(delta * 4.0, 0.0, 1.0)
	cam_target = cam_target.lerp(center, k)
	cam_dist = lerpf(cam_dist, want_dist, k)
	var pitch := deg_to_rad(63.0)
	camera.position = cam_target + Vector3(0, sin(pitch), cos(pitch)) * cam_dist
	camera.look_at(cam_target + Vector3(0, 0.4, 0), Vector3.UP)


# ------------------------------------------------------------------ HUD
func show_message(text: String, seconds: float) -> void:
	message_label.text = text
	message_t = seconds


func _update_hud(delta: float) -> void:
	message_t -= delta
	message_label.modulate.a = clampf(message_t / 0.5, 0.0, 1.0)
	if mode == "surface":
		depth_label.text = "PROLOGUE  -  THE FIRST NIGHT"
	else:
		depth_label.text = "DEPTH %d  -  FLOOR %d/%d  -  %s" % [act, run_map.floor_number(), run_map.floor_count(), RunMap.INFO[floor_type].name]
	map_panel.visible = mode == "mine" and not run_map.layers.is_empty()
	map_panel.title = "DEPTH %d MAP" % act
	map_panel.choices = choose_opts if state == CHOOSE else []
	map_panel.queue_redraw()
	var show_boss: bool = boss_ref != null and is_instance_valid(boss_ref) and boss_ref.is_alive()
	boss_box.visible = show_boss
	if show_boss:
		boss_label.text = "THE BRUTE" if boss_ref.kind == "brute" else "THE HOLLOW MOTHER"
		boss_bar.value = boss_ref.hp / boss_ref.max_hp * 100.0
	threat_bar.get_parent().visible = mode == "mine" or state == CHARGING
	match state:
		EXPLORE:
			if prologue:
				objective_label.text = prologue.objective()
			elif shard_locked:
				objective_label.text = "Defeat the %s guarding the heartshard" % ("Brute" if floor_type == "miniboss" else "Hollow Mother")
			elif shard_carrier != null:
				objective_label.text = "Carry the heartshard back to the lift"
			else:
				objective_label.text = "Find the heartshard (follow the pulse, dig through hard rock)"
			threat_label.text = "THREAT"
			threat_bar.value = threat
		CHARGING:
			objective_label.text = prologue.objective() if prologue else "HOLD THE PLATFORM  -  blink in %d" % ceili(charge_left)
			threat_label.text = "TOWER WAKING" if prologue else "LIFT CHARGING"
			threat_bar.value = (1.0 - charge_left / (12.0 if prologue else CHARGE_TIME)) * 100.0
		BLINK:
			objective_label.text = ""
		CHOOSE:
			objective_label.text = "Choose the next jump: everyone stand on the same pad"
			threat_label.text = "CHOOSE A PATH"
			threat_bar.value = choose_hold / 1.2 * 100.0
		GAMEOVER:
			objective_label.text = "Run over"
	stash_label.visible = mode == "mine"
	stash_label.text = "LIFT STASH  %d ore" % bank_ore
	for i in 4:
		var l: RichTextLabel = player_labels[i]
		if i < players.size():
			var p = players[i]
			var bar := "#".repeat(p.hp) + "-".repeat(PlayerScript.MAX_HP - p.hp)
			var status := "  DOWN" if p.downed else ("  [SHARD]" if p.carrying else "")
			var role: String = p.cls if p.cls != "" else "no role yet"
			var w: Dictionary = p.weapon
			var gun_txt := "[color=#%s]%s[/color]" % [Loot.color_of(w).to_html(false), Loot.name_of(w)]
			var spare := ("  +%d" % p.pack.size()) if p.pack.size() > 0 else ""
			l.text = "P%d %s  HP [%s]  %s%s  Torches %d  Ore %d%s" % [p.index + 1, role, bar, gun_txt, spare, p.torches, p.ore, status]
		else:
			l.text = ""
	var joinable := players.size() < 4
	if state == CHOOSE:
		var parts: Array = []
		for pd in pads:
			parts.append("%s: %s" % [pd.name, pd.desc])
		hint_label.text = "     ".join(parts) + "\nStand together on one pad for a moment to jump there."
	elif prologue:
		hint_label.text = prologue.hint() + "\nTab / Back: skip the tutorial"
	else:
		hint_label.text = "P1: WASD move, mouse aim, LMB shoot, RMB dig, E interact, Q torch, R swap gun   |   Controller: sticks, RT shoot, LT dig, A interact, Y torch, B swap"
		if joinable:
			hint_label.text += "\nMore players: press A on a controller, or Enter for a 2nd keyboard player ( arrows move  . shoot  , dig  / interact  M torch  N swap )"


# ------------------------------------------------------------------ autotest (headless)
func _fail(msg: String) -> void:
	print("AUTOTEST FAIL: ", msg)
	get_tree().quit(1)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _dig_route_to_shard() -> void:
	# BFS through floor and hard rock; dig every hard cell on the route
	var start: Vector2i = level.lift_cell
	var goal: Vector2i = level.shard_cell
	var prev := {start: start}
	var q: Array[Vector2i] = [start]
	var h := 0
	while h < q.size():
		var c := q[h]
		h += 1
		if c == goal:
			break
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nb: Vector2i = c + d
			var t: int = level.cell_at(nb)
			if (t == LevelScript.FLOOR or t == LevelScript.HARD) and not prev.has(nb):
				prev[nb] = c
				q.append(nb)
	var c: Vector2i = goal
	while prev.has(c) and c != start:
		if level.cell_at(c) == LevelScript.HARD:
			level.dig(c)
			# widen so a player fits
			for d in [Vector2i(1, 0), Vector2i(0, 1)]:
				if level.cell_at(c + d) == LevelScript.HARD:
					level.dig(c + d)
		c = prev[c]


func _dig_cells_on_route(a: Vector2i, b: Vector2i) -> void:
	var route: Array = level._bfs_path(a, b, [LevelScript.FLOOR, LevelScript.TREE, LevelScript.BOULDER])
	for c in route:
		for d in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-1, 0)]:
			var t: int = level.cell_at(c + d)
			if t == LevelScript.TREE or t == LevelScript.BOULDER:
				level.dig(c + d)


# A hard-rock cell on the outside of the shard room's ring, with open floor in front of it and
# diggable rock on both sides. Returns [rock cell, floor cell], or [] if this floor has none.
func _find_hard_face() -> Array:
	var sc: Vector2i = level.shard_cell
	var sr: float = level.shard_room.r
	for y in range(sc.y - int(sr) - 5, sc.y + int(sr) + 6):
		for x in range(sc.x - int(sr) - 5, sc.x + int(sr) + 6):
			var c := Vector2i(x, y)
			if level.cell_at(c) != LevelScript.HARD:
				continue
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = c - d
				var side := Vector2i(d.y, d.x)
				if not level.is_floor(n) or Vector2(n).distance_to(Vector2(sc)) <= sr + 2.6:
					continue
				if level.can_dig(c + side) and level.can_dig(c - side):
					return [c, n]
	return []


func _run_autotest() -> void:
	await _frames(3)
	var p1 = players[0]
	p1.input.scripted = true
	var p2 = _add_player("kb2", -1)
	p2.input.scripted = true

	# ---------------- prologue
	if mode != "surface" or prologue == null:
		return _fail("game should start in the prologue")
	if not level.surface.route_ok:
		return _fail("prologue route is broken")
	var camp: Vector3 = level.surface.camp + Vector3(0, 0, -1.5)
	if level.path_world(camp, level.surface.temple).size() > 0:
		return _fail("the camp gate should block the trail")
	print("prologue ok: tents=%d critters=%d trees=%d" % [level.surface.tents.size(), crawlers.size(), level.tree_nodes.size()])
	p1.position += Vector3(3, 0, 0)
	await _frames(3)
	if prologue.step != PrologueScript.CLASS:
		return _fail("move step did not complete")
	for i in 2:
		players[i].position = level.surface.tents[i].door
		player_interact(players[i])
	# swapping tents must not stack bonuses
	var base_torches: int = p2.torches
	p2.set_class("Artificer")
	p2.set_class("Artificer")
	if p2.torches != base_torches + 4:
		return _fail("picking Artificer twice gave %d torches, expected %d" % [p2.torches, base_torches + 4])
	p2.set_class("Bodyguard")
	p2.set_class("Architect")
	if p2.torches != base_torches or p2.weapon.type != "Pistol":
		return _fail("switching roles kept the old role's gear (%d torches, %s)" % [p2.torches, p2.weapon.type])
	await _frames(3)
	if p1.cls != "Bodyguard" or p2.cls != "Architect" or p1.gun != "shotgun" or p2.dig_mul < 2.0:
		return _fail("classes not applied (%s, %s)" % [p1.cls, p2.cls])
	if prologue.step != PrologueScript.CHOP:
		return _fail("gate did not open after classes")
	print("classes + gate ok")
	var cc: Vector2i = level.world_to_cell(camp)
	_dig_cells_on_route(cc, Vector2i(22, 17))
	if level.path_world(camp, level.surface.temple).size() == 0:
		return _fail("no path after chopping")
	p1.position = Vector3(p1.position.x, 0, level.surface.chop_line_z - 1.0)
	await _frames(3)
	if prologue.step != PrologueScript.DARK:
		return _fail("chop step did not complete")
	var critter = null
	for c in crawlers:
		if c.kind == "critter":
			critter = c
			break
	if critter == null:
		return _fail("no critters in the dark woods")
	emit_noise(critter.global_position, 3.0)
	await _frames(3)
	if prologue.step != PrologueScript.CRITTERS:
		return _fail("waking critters did not start the critter step")
	for c in crawlers:
		if is_instance_valid(c) and c.kind == "critter":
			c.hit(5, Vector3.FORWARD)
	await _frames(3)
	if prologue.step != PrologueScript.TO_TEMPLE:
		return _fail("critter step did not complete (step %d)" % prologue.step)
	print("chop, dark woods, critters ok")
	p1.position = level.surface.temple + Vector3(0, 0, 2.0)
	p2.position = level.surface.temple + Vector3(0.6, 0, 2.0)
	await _frames(3)
	if prologue.step != PrologueScript.SEARCH:
		return _fail("temple step did not complete")
	p1.position = shard.global_position + Vector3(0, 0, 0.9)
	p1.position.y = 0
	player_interact(p1)
	if not p1.carrying or prologue.step != PrologueScript.CARRY:
		return _fail("heartstone pick up failed")
	if level.path_world(p1.global_position, lift_pos).size() == 0:
		return _fail("no path from temple to tower")
	p1.position = lift_pos + Vector3(0.6, 0.25, 0.4)
	player_interact(p1)
	if state != CHARGING or prologue.step != PrologueScript.WAKE:
		return _fail("feeding the tower failed")
	print("heartstone + tower ok")
	charge_left = 0.4
	var tw := Time.get_ticks_msec()
	while mode != "mine" and Time.get_ticks_msec() - tw < 5000:
		await get_tree().process_frame
	await get_tree().create_timer(2.2).timeout
	if mode != "mine" or depth != 1 or state != EXPLORE or prologue != null:
		return _fail("first jump into the mines failed")
	if level.ore_lights.size() < 5:
		return _fail("expected glowing ore lights, got %d" % level.ore_lights.size())
	print("first jump ok: depth 1, ore lights=%d" % level.ore_lights.size())

	# ---------------- loot
	if crates.size() < 3:
		return _fail("expected loot crates, got %d" % crates.size())
	var cr = null
	for c in crates:
		if not c.pocket:
			cr = c
			break
	var n_crates := crates.size()
	p1.position = cr.node.position + Vector3(0.5, 0, 0)
	player_interact(p1)
	if crates.size() != n_crates - 1 or pickups.size() == 0:
		return _fail("opening a crate gave nothing")
	for pk in pickups:
		pk.node.queue_free()
	pickups.clear()
	var first_type: String = p1.weapon.type
	_spawn_pickup("gun", p1.position + Vector3(0.3, 0, 0), Loot.make("Rifle", 1, loot_rng))
	player_interact(p1)
	if p1.weapon.type != "Rifle" or p1.weapon.rarity != 1 or p1.pack.size() != 1:
		return _fail("gun pick up failed (%s, pack %d)" % [p1.weapon.type, p1.pack.size()])
	p1.input.swap = true
	await _frames(2)
	p1.input.swap = false
	await _frames(2)
	if p1.weapon.type != first_type or p1.pack[0].type != "Rifle":
		return _fail("swap failed")
	p1.input.swap = true
	await _frames(2)
	p1.input.swap = false
	await _frames(2)
	p1.ore = 20
	p1.position = lift_pos + Vector3(0.3, 0.25, 0.3)
	await _frames(3)
	if bank_ore != 20 or p1.ore != 0:
		return _fail("ore was not stored on the lift (bank %d)" % bank_ore)
	var wb = stations.filter(func(st): return st.kind == "workbench")[0]
	p1.position = _station_world(wb)
	player_interact(p1)
	if p1.weapon.rarity != 2 or bank_ore != 20 - Loot.UPGRADE_COST[1]:
		return _fail("workbench upgrade failed (rarity %d, bank %d)" % [p1.weapon.rarity, bank_ore])
	var mb = stations.filter(func(st): return st.kind == "medbay")[0]
	p1.hp = 2
	p1.position = _station_world(mb)
	player_interact(p1)
	if p1.hp != PlayerScript.MAX_HP:
		return _fail("med bay heal failed")
	# a medkit stays on the floor at full health, and is used once someone is hurt
	_spawn_pickup("medkit", p1.position, 2)
	await _frames(3)
	if pickups.size() != 1:
		return _fail("a medkit was used up at full health")
	p1.hp = 2
	await _frames(3)
	if p1.hp != 4 or pickups.size() != 0:
		return _fail("a hurt player did not pick up the medkit (hp %d)" % p1.hp)
	var kc = _spawn_crawler(p1.global_position + Vector3(0, 0, -6.0), false)
	kc.hit(999.0, Vector3.FORWARD)
	print("loot ok: Epic %s, bank %d, pickups after kill %d" % [p1.weapon.type, bank_ore, pickups.size()])
	for pk in pickups:
		pk.node.queue_free()
	pickups.clear()

	# ---------------- mines
	if not level.is_floor(level.lift_cell):
		return _fail("lift cell is not floor")
	if level.path_world(lift_pos, shard.global_position).size() > 0:
		return _fail("shard room should be sealed by hard rock")
	if level.nest_spots.size() < 3 or crawlers.size() < 3:
		return _fail("expected sleeping crawlers, got %d" % crawlers.size())
	print("floor ok: crawlers=%d rooms=%d" % [crawlers.size(), level.rooms.size()])

	# balance guards
	if Loot.make("Rifle", 0).dmg * 0.9 < crawlers[0].max_hp:
		return _fail("even a low-roll Common Rifle should kill a floor-1 crawler in one shot")
	var smg: Dictionary = Loot.make("SMG", 0)
	var pistol: Dictionary = Loot.make("Pistol", 0)
	if Loot.threat_per_shot(smg) / smg.cd > 1.5 * Loot.threat_per_shot(pistol) / pistol.cd:
		return _fail("holding the SMG trigger adds far more threat per second than the pistol")
	var real_depth := depth
	depth = 40
	var top_speed: float = crawlers[0].run_speed()
	depth = real_depth
	if top_speed >= PlayerScript.SPEED:
		return _fail("deep crawlers outrun the players (%.2f m/s)" % top_speed)
	print("balance ok: crawler top speed %.2f m/s" % top_speed)
	_dig_route_to_shard()
	if level.path_world(lift_pos, shard.global_position).size() == 0:
		return _fail("no path after digging")
	print("dig ok: path length %d" % level.path_world(lift_pos, shard.global_position).size())

	# combat: an awake crawler in front of P1 dies to bullets
	var c = _spawn_crawler(p1.global_position + Vector3(0, 0, -2.2), false)
	c.state = CrawlerScript.CHASE
	var killed := false
	for i in 120:
		if not is_instance_valid(c) or not c.is_alive():
			killed = true
			break
		if i % 6 == 0:
			var to: Vector3 = (c.global_position - p1.global_position)
			to.y = 0
			spawn_bullet(p1.global_position + Vector3(0, 0.6, 0), to.normalized(), p1)
		await get_tree().process_frame
	if not killed:
		return _fail("crawler did not die")
	print("combat ok")

	# digging hard rock by hand opens a hole two cells wide, so a player fits through.
	# (This runs after the route above is dug, on a different part of the ring.)
	var face: Array = _find_hard_face()
	if face.is_empty():
		print("hard rock dig: skipped (no suitable rock face on this floor)")
	else:
		var hc: Vector2i = face[0]
		var hn: Vector2i = face[1]
		var hside := Vector2i(hc.y - hn.y, hc.x - hn.x)
		var back: Vector3 = p1.position
		p1.position = level.cell_to_world(hn)
		p1.facing = Vector3(hc.x - hn.x, 0, hc.y - hn.y)
		p1.input.mouse_active = false
		p1.input.dig = true
		var td := Time.get_ticks_msec()
		while level.cell_at(hc) == LevelScript.HARD and Time.get_ticks_msec() - td < 4000:
			await get_tree().process_frame
		p1.input.dig = false
		if level.cell_at(hc) != LevelScript.FLOOR:
			return _fail("holding dig did not break the hard rock")
		if level.cell_at(hc + hside) != LevelScript.FLOOR and level.cell_at(hc - hside) != LevelScript.FLOOR:
			return _fail("a hole dug in hard rock is one cell wide: a player can't fit through")
		# the noise woke things up: clear them so the next steps start calm
		for k in crawlers:
			if is_instance_valid(k) and k.is_alive() and k.state != CrawlerScript.SLEEP:
				k.hit(999.0, Vector3.FORWARD)
		p1.position = back
		await _frames(2)
		print("hard rock dig ok")

	# noise wakes sleepers
	var sleeper = null
	for k in crawlers:
		if k.state == CrawlerScript.SLEEP:
			sleeper = k
			break
	if sleeper:
		emit_noise(sleeper.global_position + Vector3(1, 0, 0), 4.0)
		if sleeper.state != CrawlerScript.INVESTIGATE:
			return _fail("noise did not wake crawler")
	print("noise ok")

	# carry the shard home
	p1.position = shard.global_position + Vector3(0.3, 0, 0)
	p1.position.y = 0
	player_interact(p1)
	if not p1.carrying:
		return _fail("pick up failed")
	p1.position = lift_pos + Vector3(0.5, 0.25, 0)
	player_interact(p1)
	if state != CHARGING:
		return _fail("feeding did not start charging")
	print("feed ok")
	charge_left = 0.5
	var t0 := Time.get_ticks_msec()
	while state == CHARGING and Time.get_ticks_msec() - t0 < 5000:
		await get_tree().process_frame
	var want: Array = []
	if state == CHOOSE:
		if pads.size() != run_map.options().size() or pads.size() < 2:
			return _fail("expected one pad per path, got %d pads" % pads.size())
		want = pads[pads.size() - 1].opt
		for p in players:
			p.position = pads[pads.size() - 1].node.global_position
	while depth < 2 and Time.get_ticks_msec() - t0 < 9000:
		await get_tree().process_frame
	await get_tree().create_timer(2.2).timeout
	if not want.is_empty():
		if run_map.cur_layer != want[0] or run_map.cur_index != want[1]:
			return _fail("the vote did not pick the chosen path")
		print("vote ok: picked %s" % RunMap.INFO[run_map.type_of(want)].name)
	if depth != 2 or state != EXPLORE:
		return _fail("blink to depth 2 failed (depth=%d state=%d)" % [depth, state])
	print("blink ok: floor 2 (%s), crawlers=%d" % [floor_type, crawlers.size()])

	# mini-boss floor: the shard is caged until the Brute dies
	p1.torches = 11
	start_floor(depth + 1, "miniboss")
	await _frames(3)
	if p1.torches < 11:
		return _fail("starting a floor took torches away (%d left)" % p1.torches)
	if boss_ref == null or boss_ref.kind != "brute" or not shard_locked:
		return _fail("mini-boss floor has no Brute or the shard is not caged")
	p1.position = shard.global_position + Vector3(0.4, 0, 0)
	p1.position.y = 0
	player_interact(p1)
	if p1.carrying:
		return _fail("picked up a caged shard")
	var n_pick := pickups.size()
	boss_ref.hit(9999.0, Vector3.FORWARD)
	await _frames(3)
	if shard_locked or pickups.size() < n_pick + 2:
		return _fail("killing the Brute did not free the shard or drop loot")
	player_interact(p1)
	if not p1.carrying:
		return _fail("could not pick up the freed shard")
	print("mini-boss ok")

	# vault floor: locked caches around the shard
	start_floor(depth + 1, "vault")
	await _frames(3)
	var near_caches := 0
	for vc in crates:
		if vc.pocket and vc.node.global_position.distance_to(shard.global_position) < 5.0:
			near_caches += 1
	if near_caches < 3:
		return _fail("vault should have 3 caches by the shard, found %d" % near_caches)
	print("vault ok")

	# boss floor finished: the next blink starts a new depth with a new map
	run_map.cur_layer = run_map.layers.size() - 1
	run_map.cur_index = 0
	start_floor(depth + 1, "boss")
	await _frames(3)
	if boss_ref == null or boss_ref.kind != "boss":
		return _fail("boss floor has no boss")
	# a shot along the boss's flank (0.6 m off centre) must hit: its body is about 1.5 m wide
	var boss_hp: float = boss_ref.hp
	spawn_bullet(boss_ref.global_position + Vector3(0.6, 0.6, -2.0), Vector3(0, 0, 1), p1, 0.75, {}, false)
	var tf := Time.get_ticks_msec()
	while boss_ref.hp >= boss_hp and Time.get_ticks_msec() - tf < 1500:
		await get_tree().process_frame
	if boss_ref.hp >= boss_hp:
		return _fail("a shot at the boss's flank passed straight through it")
	boss_ref.hit(99999.0, Vector3.FORWARD)
	await _frames(3)
	for p in players:
		p.downed = false
	p1.position = shard.global_position + Vector3(0.4, 0, 0)
	p1.position.y = 0
	player_interact(p1)
	p1.position = lift_pos + Vector3(0.5, 0.25, 0.4)
	player_interact(p1)
	if state != CHARGING:
		return _fail("could not feed after the boss")
	var act_before := act
	charge_left = 0.2
	var tb := Time.get_ticks_msec()
	while (act == act_before or state != EXPLORE) and Time.get_ticks_msec() - tb < 6000:
		await get_tree().process_frame
	if act != act_before + 1 or run_map.cur_layer != 0 or floor_type != "mine":
		return _fail("beating the boss did not start the next depth")
	print("boss ok: depth %d begins" % act)

	# revive, with two bystanders: people standing around must not slow it down
	var p3 = _add_player("kb2", -1)
	p3.input.scripted = true
	var p4 = _add_player("kb2", -1)
	p4.input.scripted = true
	p2.hurt(10)
	await _frames(2)
	if not p2.downed:
		return _fail("p2 should be downed")
	p1.position = p2.position + Vector3(0.4, 0, 0)
	p1.input.interact = true
	var t1 := Time.get_ticks_msec()
	while p2.downed and Time.get_ticks_msec() - t1 < 4000:
		await get_tree().process_frame
	p1.input.interact = false
	if p2.downed:
		return _fail("revive failed")
	print("revive ok")

	# leaving frees the slot, and the next player to join takes it
	_remove_player(p3, "left the crew")
	if players.size() != 3 or p3 in players:
		return _fail("leaving did not remove the player")
	await _frames(2)
	var p5 = _add_player("kb2", -1)
	p5.input.scripted = true
	if p5.index != 2 or players[2] != p5 or p4.index != 3:
		return _fail("a new player did not take the free slot (got P%d)" % (p5.index + 1))
	print("leave + rejoin ok")

	# game over and restart
	for p in players:
		p.invuln = 0.0
		p.hurt(10)
	await _frames(3)
	if state != GAMEOVER:
		return _fail("expected game over")
	gameover_t = 2.0
	p1.input.interact = true
	await _frames(3)
	p1.input.interact = false
	if mode != "mine" or state != EXPLORE or depth != 1 or act != 1:
		return _fail("restart should go straight back to the mines (mode %s, floor %d)" % [mode, depth])
	if p1.cls != "Bodyguard" or p2.cls != "Architect":
		return _fail("restart lost the crew's roles (%s, %s)" % [p1.cls, p2.cls])
	print("game over + restart ok")
	print("AUTOTEST PASS")
	get_tree().quit(0)


# ------------------------------------------------------------------ screenshots (needs a display)
func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(shot_dir.path_join(name))
	print("saved ", name)


func _script_players(n: int) -> void:
	while players.size() < n:
		var p = _add_player("kb2", -1)
		p.input.device = "script"
	for p in players:
		p.input.scripted = true
		p.input.move = Vector2.ZERO


func _center_cam() -> void:
	var c := Vector3.ZERO
	for p in players:
		c += p.position
	cam_target = c / players.size()


func _run_screenshots() -> void:
	DirAccess.make_dir_recursive_absolute(shot_dir)
	await _frames(5)
	_script_players(3)
	var sf: Dictionary = level.surface
	# 1: the camp in the storm
	var camp: Vector3 = sf.camp
	for i in players.size():
		var a := TAU * i / 3.0 - 1.2
		players[i].position = camp + Vector3(cos(a), 0, sin(a)) * 2.2
		players[i].facing = (camp - players[i].position).normalized()
	_center_cam()
	show_message("The first night. A storm rolls over the camp.\nSomewhere in these woods, something old is sleeping.", 99.0)
	await _frames(45)
	await _shot("01-camp-in-the-storm.png")

	# 2: picking roles at the class tents
	message_t = 0.0
	for i in 3:
		var door: Vector3 = sf.tents[i].door
		players[i].position = door + Vector3(0, 0, -0.5)
		players[i].facing = Vector3(0, 0, 1)
		player_interact(players[i])
	prologue.step = PrologueScript.CLASS
	_center_cam()
	cam_target += Vector3(0, 0, 0.8)
	show_message("P1 is the Bodyguard\n" + PlayerScript.CLASS_INFO["Bodyguard"], 99.0)
	await _frames(40)
	await _shot("02-class-tents.png")

	# 3: the gate opens, chop the fallen trees
	message_t = 0.0
	await _frames(3)
	var tree_c: Vector2i = level.tree_nodes.keys()[0]
	for k in level.tree_nodes.keys():
		if level.cell_to_world(k).z > sf.chop_line_z and absf(level.cell_to_world(k).x - camp.x) < 1.0:
			tree_c = k
	var tw: Vector3 = level.cell_to_world(tree_c)
	players[1].position = tw + Vector3(0, 0, 0.85)
	players[1].facing = Vector3(0, 0, -1)
	players[1].input.dig = true
	players[0].position = tw + Vector3(-1.0, 0, 1.8)
	players[2].position = tw + Vector3(1.1, 0, 1.6)
	players[0].facing = Vector3(0, 0, -1)
	players[2].facing = Vector3(-0.3, 0, -1).normalized()
	place_torch(tw + Vector3(1.6, 0, 2.6))
	_center_cam()
	await _frames(30)
	await _shot("03-chop-the-trail.png")
	players[1].input.dig = false

	# 4: the dark woods: torches and critters
	_dig_cells_on_route(level.world_to_cell(camp + Vector3(0, 0, -1.5)), Vector2i(22, 17))
	prologue.step = PrologueScript.DARK
	var route: Array = level._bfs_path(level.world_to_cell(camp + Vector3(0, 0, -1.5)), Vector2i(22, 17), [LevelScript.FLOOR])
	var spot: Vector3 = level.cell_to_world(route[int(route.size() * 0.62)])
	var ahead: Vector3 = level.cell_to_world(route[int(route.size() * 0.62) - 9])
	for i in 3:
		players[i].position = spot + Vector3(i * 0.7 - 0.7, 0, 0.4 * (i % 2))
	place_torch(spot + Vector3(-1.2, 0, 1.4))
	place_torch(level.cell_to_world(route[int(route.size() * 0.62) + 10]))
	for i in 3:
		_spawn_crawler(ahead + Vector3(randf_range(-0.8, 0.8), 0, randf_range(-0.8, 0.8)), true, "critter")
	var to_c := (ahead - spot)
	to_c.y = 0
	players[0].facing = to_c.normalized()
	players[0].input.shoot = true
	players[2].facing = to_c.normalized()
	players[2].input.shoot = true
	prologue.dark_amount = 1.0
	_center_cam()
	await _frames(26)
	await _shot("04-dark-woods.png")
	players[0].input.shoot = false
	players[2].input.shoot = false

	# 5: the temple and the heartstone
	for c in crawlers:
		if is_instance_valid(c):
			c.queue_free()
	crawlers.clear()
	prologue.step = PrologueScript.SEARCH
	prologue.dark_amount = 0.0
	var altar: Vector3 = sf.altar
	players[0].position = Vector3(altar.x - 0.9, 0, altar.z + 1.0)
	players[1].position = Vector3(altar.x + 0.9, 0, altar.z + 1.1)
	players[2].position = Vector3(altar.x, 0, altar.z + 2.0)
	for p in players:
		p.facing = Vector3(altar.x - p.position.x, 0, altar.z - p.position.z).normalized()
	_center_cam()
	show_message("The old temple.\nSomething is glowing on the altar...", 99.0)
	await _frames(40)
	await _shot("05-temple-heartstone.png")

	# 6: escort to the tower, arrows pointing the way
	message_t = 0.0
	players[0].position = Vector3(altar.x, 0, altar.z + 0.9)
	player_interact(players[0])
	var path: PackedVector3Array = level.path_world(players[0].position, lift_pos)
	var mid: Vector3 = path[int(path.size() * 0.55)]
	players[0].position = mid
	players[1].position = path[int(path.size() * 0.55) - 3] + Vector3(0.3, 0, 0.3)
	players[2].position = path[int(path.size() * 0.55) + 3]
	var g = _spawn_crawler(path[int(path.size() * 0.55) - 9], true, "critter")
	var g2 = _spawn_crawler(path[int(path.size() * 0.55) - 10] + Vector3(0.5, 0, 0), true, "critter")
	players[1].facing = (g.position - players[1].position).normalized()
	players[1].input.shoot = true
	pulse_t = 0.0
	_center_cam()
	await _frames(30)
	await _shot("06-escort-to-the-tower.png")
	players[1].input.shoot = false

	# 7: the tower wakes
	for c in crawlers:
		if is_instance_valid(c):
			c.queue_free()
	crawlers.clear()
	for i in 3:
		var a := TAU * i / 3.0 + 0.9
		players[i].position = lift_pos + Vector3(cos(a), 0, sin(a)) * 1.3
		players[i].position.y = 0.25
		players[i].facing = Vector3(cos(a), 0, sin(a))
	players[0].position = lift_pos + Vector3(0.5, 0.25, 0.6)
	player_interact(players[0])
	for i in 5:
		var a := randf() * PI + 0.2
		var pos := lift_pos + Vector3(cos(a), 0, sin(a)) * randf_range(3.2, 5.0)
		if level.can_occupy(pos, 0.25):
			_spawn_crawler(pos, true, "critter")
	for p in players:
		p.input.shoot = true
	_center_cam()
	await get_tree().create_timer(1.1).timeout
	await _shot("07-the-tower-wakes.png")
	for p in players:
		p.input.shoot = false

	# 8: depth 1, the mines: brighter, with glowing ore
	charge_left = 0.1
	while mode != "mine":
		await get_tree().process_frame
	await get_tree().create_timer(1.8).timeout
	message_t = 0.0
	var best: Vector3 = lift_pos
	var bd := 1e9
	for e in level.ore_lights:
		var lp: Vector3 = e.light.position
		var d := lp.distance_to(lift_pos)
		if d > 8.0 and d < bd:
			var c: Vector2i = level.world_to_cell(lp)
			for o in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1), Vector2i(1, 1), Vector2i(-1, -1)]:
				if level.is_floor(c + o) and level.can_occupy(level.cell_to_world(c + o), 0.26):
					bd = d
					best = level.cell_to_world(c + o)
					break
	for i in 3:
		var p = players[i]
		for t in 30:
			var cand: Vector3 = best + Vector3(randf_range(-1.2, 1.2), 0, randf_range(-1.2, 1.2))
			if level.can_occupy(cand, 0.26):
				p.position = cand
				break
	players[1].input.dig = true
	players[1].facing = (Vector3(best.x, 0, best.z) - players[1].position).normalized()
	place_torch(best + Vector3(0.0, 0, 0.0))
	_center_cam()
	await _frames(40)
	await _shot("08-mines-depth-1.png")
	players[1].input.dig = false

	# 9: loot: a crate cracked open, guns of each rarity with their beams
	var cr = null
	for c in crates:
		if not c.pocket:
			cr = c
			break
	if cr:
		var cpos: Vector3 = cr.node.position
		for c in crawlers:
			if is_instance_valid(c) and c.global_position.distance_to(cpos) < 7.0:
				c.queue_free()
		crawlers = crawlers.filter(func(c): return is_instance_valid(c) and c.global_position.distance_to(cpos) >= 7.0)
		players[0].position = cpos + Vector3(-0.9, 0, 0.7)
		players[1].position = cpos + Vector3(0.9, 0, 0.8)
		players[2].position = cpos + Vector3(0.1, 0, 1.4)
		for p in players:
			if not level.can_occupy(p.position, 0.2):
				p.position = cpos + Vector3(randf_range(-0.4, 0.4), 0, 1.0)
		players[0].take_weapon(Loot.make("SMG", 1, loot_rng))
		players[2].take_weapon(Loot.make("Rifle", 2, loot_rng))
		_open_crate(cr)
		_spawn_pickup("gun", cpos + Vector3(-0.4, 0, -0.3), Loot.make("Pistol", 0, loot_rng))
		_spawn_pickup("gun", cpos + Vector3(0.0, 0, -0.55), Loot.make("Shotgun", 1, loot_rng))
		_spawn_pickup("gun", cpos + Vector3(0.45, 0, -0.25), Loot.make("Rifle", 2, loot_rng))
		_spawn_pickup("ore", cpos + Vector3(-0.6, 0, 0.2), 4)
		place_torch(cpos + Vector3(-1.4, 0, 1.6))
		for p in players:
			p.facing = (cpos - p.position).normalized()
		_center_cam()
		message_t = 0.0
		await _frames(30)
		await _shot("09-loot-cache.png")
		for pk in pickups:
			pk.node.queue_free()
		pickups.clear()

	# 10: back on the lift: stash, workbench, med bay, torch rack
	bank_ore = 14
	for i in 3:
		players[i].ore = 0
	players[0].position = _station_world(stations[0]) + Vector3(0.35, 0, 0)
	players[1].position = _station_world(stations[1]) + Vector3(-0.35, 0, 0)
	players[2].position = lift_pos + Vector3(0.2, 0.25, 0.9)
	players[0].facing = Vector3(-1, 0, 0)
	players[1].facing = Vector3(1, 0, 0)
	players[2].facing = Vector3(0, 0, 1)
	_center_cam()
	cam_target = lift_pos + Vector3(0, 0, 0.3)
	show_message("P1 upgraded to Epic SMG!", 99.0)
	players[0].equip(Loot.make("SMG", 2, loot_rng))
	await _frames(30)
	await _shot("10-lift-stations.png")
	message_t = 0.0

	# 11: choosing the next jump on the lift's pads, with the depth map
	var first: Array = run_map.layers[1]
	var demo_types := ["mine", "vault", "miniboss"]
	for i in first.size():
		first[i].type = demo_types[i % 3]
	_start_choose(run_map.options())
	await _frames(2)
	players[0].position = pads[0].node.global_position + Vector3(0.1, 0, 0.05)
	players[1].position = pads[0].node.global_position + Vector3(-0.15, 0, -0.1)
	players[2].position = pads[pads.size() - 1].node.global_position + Vector3(0.0, 0, 0.1)
	for p in players:
		p.facing = Vector3(0, 0, 1)
	_center_cam()
	cam_target = lift_pos + Vector3(0, 0, -0.2)
	show_message("The lift senses %d heartshards.\nEveryone: stand on the same pad to pick the next jump." % pads.size(), 99.0)
	await _frames(30)
	await _shot("11-choose-next-jump.png")
	_clear_pads()
	state = EXPLORE
	message_t = 0.0

	# 12: a mini-boss floor: the Brute guards the caged heartshard
	start_floor(depth + 1, "miniboss")
	await _frames(5)
	var bpos: Vector3 = boss_ref.global_position
	var sp: Vector3 = shard.global_position
	var away := (bpos - sp)
	away.y = 0
	away = away.normalized() if away.length() > 0.1 else Vector3(0, 0, 1)
	var used: Array = []
	for i in 3:
		var placed := false
		for tries in 60:
			var ang := atan2(away.z, away.x) + (i - 1) * 0.55 + randf_range(-0.25, 0.25)
			var cand: Vector3 = bpos + Vector3(cos(ang), 0, sin(ang)) * randf_range(2.0, 3.0)
			var clash := false
			for u in used:
				if u.distance_to(cand) < 0.7:
					clash = true
			if level.can_occupy(cand, 0.26) and not clash:
				players[i].position = cand
				used.append(cand)
				placed = true
				break
		if not placed:
			players[i].position = bpos + away * 2.2 + Vector3(i * 0.6 - 0.6, 0, 0)
		players[i].facing = (bpos - players[i].position).normalized()
	players[1].input.shoot = true
	players[0].equip(Loot.make("Shotgun", 1, loot_rng))
	players[2].equip(Loot.make("Rifle", 2, loot_rng))
	boss_ref.state = CrawlerScript.CHASE
	boss_ref.zzz.visible = false
	boss_ref.hp = boss_ref.max_hp * 0.8
	place_torch(sp + Vector3(1.0, 0, 1.0))
	_center_cam()
	cam_target = (bpos + players[1].position) * 0.5
	message_t = 0.0
	await _frames(14)
	await _shot("12-mini-boss.png")
	for p in players:
		p.input.shoot = false

	# 9: the team leaving the lift into the caves, a little further out
	for i in 3:
		players[i].position = lift_pos + Vector3(-0.8 + i * 0.8, 0.25, -0.4)
	_center_cam()
	cam_target += Vector3(0, 0, -2.5)
	place_torch(lift_pos + Vector3(0, 0, -5.0))
	await _frames(10)
	cam_dist = 17.0
	set_process(false)
	camera.position = cam_target + Vector3(0, sin(deg_to_rad(63.0)), cos(deg_to_rad(63.0))) * 17.0
	camera.look_at(cam_target, Vector3.UP)
	await _frames(20)
	await _shot("13-cave-overview.png")
	get_tree().quit(0)


# ================================================================== loot
var _pickup_meshes := {}


func _spawn_crate(cell: Vector2i, pocket: bool) -> void:
	var n := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = VK.loot_crate_mesh(pocket)
	n.add_child(mi)
	add_child(n)
	n.position = level.cell_to_world(cell)
	n.rotation.y = loot_rng.randf() * TAU
	var lab := Label3D.new()
	lab.text = "OPEN"
	lab.font_size = 30
	lab.outline_size = 8
	lab.pixel_size = 0.006
	lab.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lab.no_depth_test = true
	lab.modulate = Color("ffd166") if not pocket else Color("d9a8ff")
	lab.position = Vector3(0, 0.75, 0)
	lab.visible = false
	n.add_child(lab)
	crates.append({"node": n, "cell": cell, "pocket": pocket, "label": lab})


func _open_crate(cr: Dictionary) -> void:
	var pos: Vector3 = cr.node.global_position
	crates.erase(cr)
	cr.node.queue_free()
	debris(pos + Vector3(0, 0.3, 0), Color("8a5a33") if not cr.pocket else Color("4b3f5c"), 12)
	emit_noise(pos, 4.0)
	var r := loot_rng.randf()
	var drops: Array = []
	if cr.pocket:
		drops.append(["gun", Loot.roll_weapon(loot_rng, depth, 25.0)])
		drops.append(["ore", loot_rng.randi_range(3, 6)])
	elif r < 0.5:
		drops.append(["gun", Loot.roll_weapon(loot_rng, depth)])
	elif r < 0.8:
		drops.append(["ore", loot_rng.randi_range(3, 6)])
	else:
		drops.append(["torches", 2] if loot_rng.randf() < 0.5 else ["medkit", 2])
	for i in drops.size():
		var a := TAU * i / drops.size() + loot_rng.randf()
		_spawn_pickup(drops[i][0], pos + Vector3(cos(a), 0, sin(a)) * 0.35, drops[i][1])
	show_message("Supply crate!" if not cr.pocket else "A rare cache!", 1.2)


func _pickup_mesh(kind: String, data) -> Mesh:
	var key: String = kind
	if kind == "gun":
		key = "gun-%s-%d" % [data.type, data.rarity]
	if not _pickup_meshes.has(key):
		match kind:
			"gun":
				_pickup_meshes[key] = VK.gun_mesh(data.type, Loot.color_of(data), 1.0 / 11.0)
			"ore":
				_pickup_meshes[key] = VK.ore_chunk_mesh()
			"medkit":
				_pickup_meshes[key] = VK.medkit_mesh()
			"torches":
				_pickup_meshes[key] = VK.torch_mesh()
	return _pickup_meshes[key]


func _spawn_pickup(kind: String, pos: Vector3, data) -> void:
	var n := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = _pickup_mesh(kind, data)
	mi.name = "Mesh"
	n.add_child(mi)
	if kind == "gun":
		mi.rotation.z = PI / 2.0
		var col := Loot.color_of(data)
		var beam := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.12, 3.0, 0.12)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(col.r, col.g, col.b, 0.5)
		bm.material = mat
		beam.mesh = bm
		beam.position = Vector3(0, 1.5, 0)
		n.add_child(beam)
		var l := OmniLight3D.new()
		l.light_color = col
		l.light_energy = 0.9 + data.rarity * 0.3
		l.omni_range = 2.2
		l.position = Vector3(0, 0.6, 0)
		n.add_child(l)
		var lab := Label3D.new()
		lab.text = Loot.name_of(data)
		lab.font_size = 30
		lab.outline_size = 8
		lab.pixel_size = 0.006
		lab.modulate = col
		lab.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lab.no_depth_test = true
		lab.position = Vector3(0, 0.8 + data.rarity * 0.24, 0)
		n.add_child(lab)
	add_child(n)
	n.position = Vector3(pos.x, ground_y(pos), pos.z)
	pickups.append({"node": n, "kind": kind, "data": data, "t": loot_rng.randf() * 6.0})


func drop_ore(pos: Vector3, n: int) -> void:
	_spawn_pickup("ore", pos + Vector3(0.2, 0, 0.1), n)


func on_crawler_killed(c) -> void:
	if mode == "mine" and c.is_heavy():
		var big: bool = c.kind == "boss"
		_spawn_pickup("gun", c.global_position + Vector3(0.3, 0, 0), Loot.roll_weapon(loot_rng, depth, 60.0 if big else 40.0))
		_spawn_pickup("ore", c.global_position + Vector3(-0.3, 0, 0.2), loot_rng.randi_range(8, 12) if big else loot_rng.randi_range(5, 8))
		if big:
			_spawn_pickup("gun", c.global_position + Vector3(0, 0, -0.4), Loot.roll_weapon(loot_rng, depth, 60.0))
		debris(c.global_position + Vector3(0, 0.5, 0), Color("ffcc33"), 20)
		if c == boss_ref:
			shard_locked = false
			cage.visible = false
			show_message("%s is down!\nThe heartshard is free." % ("The Brute" if not big else "The Hollow Mother"), 3.0)
		return
	if mode != "mine" or c.kind != "crawler":
		return
	var r := loot_rng.randf()
	if r < 0.06 + 0.01 * depth:
		_spawn_pickup("gun", c.global_position, Loot.roll_weapon(loot_rng, depth, 10.0))
	elif r < 0.45:
		_spawn_pickup("ore", c.global_position, loot_rng.randi_range(1, 2))


func _station_world(st: Dictionary) -> Vector3:
	return lift_root.global_transform * st.local


func _station_text(st: Dictionary, p) -> String:
	match st.kind:
		"workbench":
			if p == null or p.weapon.rarity >= 2:
				return "WORKBENCH\nYour gun is already Epic" if p else "WORKBENCH"
			return "WORKBENCH\nUpgrade to %s: %d ore" % [Loot.RARITY_NAMES[p.weapon.rarity + 1], Loot.UPGRADE_COST[p.weapon.rarity]]
		"medbay":
			return "MED BAY\nHeal fully: 3 ore"
		"torches":
			return "TORCH RACK\n2 torches: 2 ore"
	return ""


func _use_station(st: Dictionary, p) -> void:
	match st.kind:
		"workbench":
			var w: Dictionary = p.weapon
			if w.rarity >= 2:
				show_message("That %s is already Epic." % w.type, 1.5)
				return
			var cost: int = Loot.UPGRADE_COST[w.rarity]
			if bank_ore < cost:
				show_message("Need %d ore in the lift stash (have %d).\nStep onto the lift to store the ore you carry." % [cost, bank_ore], 2.5)
				return
			bank_ore -= cost
			p.equip(Loot.make(w.type, w.rarity + 1, loot_rng))
			debris(_station_world(st) + Vector3(0, 0.8, 0), Loot.color_of(p.weapon), 14)
			show_message("P%d upgraded to %s!" % [p.index + 1, Loot.name_of(p.weapon)], 2.0)
		"medbay":
			if p.hp >= PlayerScript.MAX_HP:
				show_message("Already at full health.", 1.2)
				return
			if bank_ore < 3:
				show_message("Need 3 ore in the lift stash.", 1.5)
				return
			bank_ore -= 3
			p.hp = PlayerScript.MAX_HP
			debris(p.global_position + Vector3(0, 1.0, 0), Color("6dffa8"), 10)
			show_message("P%d is patched up." % (p.index + 1), 1.2)
		"torches":
			if bank_ore < 2:
				show_message("Need 2 ore in the lift stash.", 1.5)
				return
			if p.torches >= 12:
				show_message("Can't carry more torches.", 1.2)
				return
			bank_ore -= 2
			p.torches = mini(p.torches + 2, 12)
			show_message("P%d took 2 torches." % (p.index + 1), 1.0)


# Interact with the nearest gun on the floor, crate or lift station. Returns true if something was used.
func _try_loot_interact(p) -> bool:
	var best = null
	var best_kind := ""
	var bd := 1.15
	for pk in pickups:
		if pk.kind == "gun":
			var d := _flat_dist(p.global_position, pk.node.global_position)
			if d < bd:
				bd = d
				best = pk
				best_kind = "gun"
	for cr in crates:
		if not cr.node.visible:
			continue
		var d := _flat_dist(p.global_position, cr.node.global_position)
		if d < bd:
			bd = d
			best = cr
			best_kind = "crate"
	if mode == "mine":
		for st in stations:
			var d := _flat_dist(p.global_position, _station_world(st))
			if d < bd:
				bd = d
				best = st
				best_kind = "station"
	match best_kind:
		"gun":
			pickups.erase(best)
			best.node.queue_free()
			var dropped: Dictionary = p.take_weapon(best.data)
			if not dropped.is_empty():
				_spawn_pickup("gun", p.global_position + Vector3(0.35, 0, 0.2), dropped)
			show_message("P%d picked up %s" % [p.index + 1, Loot.name_of(p.weapon)], 1.5)
			return true
		"crate":
			_open_crate(best)
			return true
		"station":
			_use_station(best, p)
			return true
	return false


func _update_loot(delta: float) -> void:
	# pickups bob and spin; ore, torches and medkits are collected by walking over them
	var keep: Array = []
	for pk in pickups:
		pk.t += delta
		var m: Node3D = pk.node.get_node("Mesh")
		m.position.y = 0.25 + sin(pk.t * 3.0) * 0.06
		m.rotation.y += delta * 1.5
		var taken := false
		if pk.kind != "gun":
			for p in players:
				if p.downed or _flat_dist(p.global_position, pk.node.global_position) > 0.7:
					continue
				# leave it on the floor for someone who can use it
				if pk.kind == "medkit" and p.hp >= PlayerScript.MAX_HP:
					continue
				if pk.kind == "torches" and p.torches >= 12:
					continue
				match pk.kind:
					"ore":
						p.ore += int(pk.data)
					"torches":
						p.torches = mini(p.torches + int(pk.data), 12)
					"medkit":
						p.hp = mini(p.hp + int(pk.data), PlayerScript.MAX_HP)
				debris(pk.node.global_position + Vector3(0, 0.3, 0), Color("7ef6ff") if pk.kind == "ore" else Color("ffd166"), 5)
				taken = true
				break
		if taken:
			pk.node.queue_free()
		else:
			keep.append(pk)
	pickups = keep
	# crates inside undiscovered pockets stay hidden; show prompts near players
	for cr in crates:
		cr.node.visible = not level.covered.has(cr.cell)
		var near := false
		for p in players:
			if not p.downed and _flat_dist(p.global_position, cr.node.global_position) < 1.6:
				near = true
		cr.label.visible = near and cr.node.visible
	# lift stations: prompts, and carried ore is stored when you step on the lift
	if mode != "mine":
		return
	for st in stations:
		var nearest = null
		var nd := 2.0
		for p in players:
			var d := _flat_dist(p.global_position, _station_world(st))
			if not p.downed and d < nd:
				nd = d
				nearest = p
		st.label.visible = nearest != null
		if nearest:
			st.label.text = _station_text(st, nearest)
			st.label.modulate = Color("e8f6ff")
	if state == GAMEOVER:
		return
	var stored := 0
	for p in players:
		if not p.downed and p.ore > 0 and _flat_dist(p.global_position, lift_pos) < LIFT_RADIUS:
			stored += p.ore
			bank_ore += p.ore
			p.ore = 0
	if stored > 0:
		debris(lift_pos + Vector3(0, 0.8, 0), Color("7ef6ff"), 6)
		show_message("+%d ore stored in the lift" % stored, 1.5)



# ================================================================== the branching map
func _after_charge() -> void:
	pending = {}
	if mode == "mine" and not run_map.at_boss():
		var opts: Array = run_map.options()
		if opts.size() > 1:
			_start_choose(opts)
			return
		if opts.size() == 1:
			pending = {"opt": opts[0]}
	state = BLINK
	blink_t = 0.0
	blink_done = false


func _start_choose(opts: Array) -> void:
	state = CHOOSE
	choose_opts = opts
	choose_hold = 0.0
	# the lift's pulse shatters what is left of the swarm and lifts everyone back up
	for c in crawlers:
		if is_instance_valid(c) and c.is_alive():
			debris(c.global_position + Vector3(0, 0.3, 0), Color("7ef6ff"), 6)
			c.queue_free()
	crawlers.clear()
	for p in players:
		if p.downed:
			p.revive()
	_clear_pads()
	var n := opts.size()
	for i in n:
		var t: String = run_map.type_of(opts[i])
		var info: Dictionary = RunMap.INFO[t]
		var col: Color = info.color
		var local := Vector3((i - (n - 1) / 2.0) * 1.1, 0.27, -0.75)
		var node := Node3D.new()
		var disc := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.42
		cm.bottom_radius = 0.42
		cm.height = 0.03
		cm.radial_segments = 24
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(col.r, col.g, col.b, 0.55)
		cm.material = mat
		disc.mesh = cm
		node.add_child(disc)
		var beam := MeshInstance3D.new()
		beam.mesh = VK.box_mesh(Vector3(0.06, 1.6, 0.06), col, true)
		beam.position = Vector3(0, 0.8, 0)
		node.add_child(beam)
		var lab := Label3D.new()
		lab.font_size = 34
		lab.outline_size = 10
		lab.pixel_size = 0.006
		lab.modulate = col.lightened(0.2)
		lab.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lab.no_depth_test = true
		lab.position = Vector3(0, 1.75 + (i % 2) * 0.45, 0)
		node.add_child(lab)
		var light := OmniLight3D.new()
		light.light_color = col
		light.light_energy = 1.0
		light.omni_range = 2.0
		light.position = Vector3(0, 0.5, 0)
		node.add_child(light)
		lift_root.add_child(node)
		node.position = local
		pads.append({"node": node, "label": lab, "opt": opts[i], "mat": mat, "col": col, "name": "%d  %s" % [i + 1, info.name], "desc": info.desc})
	show_message("The lift senses %d heartshards.\nEveryone: stand on the same pad to pick the next jump." % n, 4.0)


func _clear_pads() -> void:
	for pd in pads:
		pd.node.queue_free()
	pads.clear()
	choose_opts = []


func _update_choose(delta: float) -> void:
	var alive: Array = players.filter(func(p): return not p.downed)
	var chosen := -1
	for i in pads.size():
		var pd: Dictionary = pads[i]
		var wp: Vector3 = pd.node.global_position
		var votes := 0
		for p in alive:
			if _flat_dist(p.global_position, wp) < 0.5:
				votes += 1
		if votes == alive.size() and votes > 0:
			chosen = i
		pd.label.text = "%s\n%d/%d" % [pd.name, votes, alive.size()]
		var pulse := 0.55 + (0.3 * sin(Time.get_ticks_msec() * 0.012) if votes > 0 else 0.0)
		pd.mat.albedo_color = Color(pd.col.r, pd.col.g, pd.col.b, pulse)
	if chosen < 0:
		choose_hold = 0.0
		return
	choose_hold += delta
	if choose_hold >= 1.2:
		pending = {"opt": pads[chosen].opt}
		_clear_pads()
		state = BLINK
		blink_t = 0.0
		blink_done = false
		var keep := pending
		pending = keep
