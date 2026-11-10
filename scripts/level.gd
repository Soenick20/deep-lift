# One mine floor: a grid of cells, generated per jump, rendered as chunked voxel meshes.
# Cells are 0.5 m; walls are 1 m tall and drawn from 0.25 m sub-voxels.
extends Node3D

const VK = preload("res://scripts/voxel_kit.gd")

const CELL := 0.5
const W := 84
const H := 84
const CHUNK := 12
const WALL_H := 1.0
const SUB := 0.25

enum { FLOOR, DIRT, ORE, HARD, BEDROCK, TREE, BOULDER, THICKET, RUIN, PROP, BARRIER }

const DIG_TIME := {DIRT: 0.3, ORE: 0.55, HARD: 1.0, TREE: 0.75, BOULDER: 0.9}

var grid := PackedByteArray()
var rng := RandomNumberGenerator.new()
var astar := AStarGrid2D.new()
var chunk_nodes := {}
var rooms: Array = []
var lift_cell := Vector2i.ZERO
var shard_cell := Vector2i.ZERO
var shard_room: Dictionary = {}
var nest_spots: Array = []   # Vector2i cells for sleeping crawlers
var depth := 1
var mode := "mine"
var floor_style := PackedByteArray()   # 0 grass, 1 trail, 2 stone tiles, 3 mine, 4 camp ground
var decor: Node3D
var tree_nodes := {}                   # Vector2i -> Node3D (choppable trees)
var ore_lights: Array = []             # [{light, cells}]
var surface := {}                      # named places for the prologue

const DIRS4 := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]

# ---- cave rendering (mines): a 4x finer voxel grid over the gameplay cells
const F := 4                  # fine voxels per cell side
const FS := CELL / F          # 0.125 m
const FW := W * F
const CAVE_CHUNK := 8         # cells per cave chunk side
const HMAX := 1.35            # tallest rock voxel
const RISE := 1.2             # metres from the floor edge until the rock reaches HMAX
const VOID := 1.55            # rock further than this from open floor is left as darkness
const BIG := 9999.0
var open_f := PackedByteArray()      # 1 = open floor (visible)
var dwall := PackedFloat32Array()    # rock: distance to open floor (fine units)
var dfloor := PackedFloat32Array()   # floor: distance to rock (fine units)
var covered := {}                    # hidden pocket cells, drawn as rock until found
var cave_noise := FastNoiseLite.new()
var dirty_chunks := {}
var crystal_nodes := {}              # ore cell -> crystal decor
var last_uncovered := 0
var floor_type := "mine"
var boss_spot := Vector2i.ZERO
var crate_spots: Array = []         # [{cell, pocket}]


# ------------------------------------------------------------------ queries
func idx(c: Vector2i) -> int:
	return c.y * W + c.x


func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < W and c.y < H


func cell_at(c: Vector2i) -> int:
	if not in_bounds(c):
		return BEDROCK
	return grid[idx(c)]


func set_cell(c: Vector2i, t: int) -> void:
	if in_bounds(c):
		grid[idx(c)] = t


func is_floor(c: Vector2i) -> bool:
	return cell_at(c) == FLOOR


func world_to_cell(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / CELL), floori(p.z / CELL))


func cell_to_world(c: Vector2i) -> Vector3:
	return Vector3((c.x + 0.5) * CELL, 0.0, (c.y + 0.5) * CELL)


func is_solid_world(p: Vector3) -> bool:
	if mode == "mine":
		return not _open_fine_world(p.x, p.z)
	return not is_floor(world_to_cell(p))


func _open_fine_world(x: float, z: float) -> bool:
	var fx := floori(x / FS)
	var fz := floori(z / FS)
	if fx < 0 or fz < 0 or fx >= FW or fz >= FW:
		return false
	return open_f[fz * FW + fx] == 1


# A square of half-size r around p must be entirely open.
func can_occupy(p: Vector3, r: float) -> bool:
	if mode == "mine":
		for o in [Vector2(-r, -r), Vector2(r, -r), Vector2(-r, r), Vector2(r, r), Vector2(0, 0)]:
			if not _open_fine_world(p.x + o.x, p.z + o.y):
				return false
		return true
	for o in [Vector2(-r, -r), Vector2(r, -r), Vector2(-r, r), Vector2(r, r)]:
		if not is_floor(Vector2i(floori((p.x + o.x) / CELL), floori((p.z + o.y) / CELL))):
			return false
	return true


func line_of_sight(a: Vector3, b: Vector3) -> bool:
	var d := b - a
	d.y = 0
	var steps := int(d.length() / (CELL * 0.4)) + 1
	for i in steps + 1:
		var p := a + d * (float(i) / steps)
		if is_solid_world(p):
			return false
	return true


func path_world(from: Vector3, to: Vector3) -> PackedVector3Array:
	var out := PackedVector3Array()
	var a := world_to_cell(from)
	var b := world_to_cell(to)
	if not in_bounds(a) or not in_bounds(b) or astar.is_point_solid(a) or astar.is_point_solid(b):
		return out
	var ids := astar.get_id_path(a, b)
	for c in ids:
		out.append(cell_to_world(c))
	return out


func can_dig(c: Vector2i) -> bool:
	var t := cell_at(c)
	return t == DIRT or t == ORE or t == HARD or t == TREE or t == BOULDER


# Removes a wall cell. Returns the type that was there.
func dig(c: Vector2i) -> int:
	var t := cell_at(c)
	if not can_dig(c):
		return -1
	set_cell(c, FLOOR)
	astar.set_point_solid(c, false)
	if t == TREE and tree_nodes.has(c):
		tree_nodes[c].queue_free()
		tree_nodes.erase(c)
	if t == ORE:
		_update_ore_lights(c)
		if crystal_nodes.has(c):
			crystal_nodes[c].queue_free()
			crystal_nodes.erase(c)
	if mode == "mine":
		_cave_after_dig(c)
	else:
		_rebuild_chunks_near(c)
	return t


# Turns a set of cells into open floor (used to open the camp gate).
func open_cells(cells: Array) -> void:
	for c in cells:
		set_cell(c, FLOOR)
		astar.set_point_solid(c, false)
	for c in cells:
		_rebuild_chunks_near(c)


# ------------------------------------------------------------------ generation
func generate(seed_value: int, depth_value: int, ftype: String = "mine") -> void:
	depth = depth_value
	floor_type = ftype
	mode = "mine"
	rng.seed = seed_value
	_clear_decor()
	grid.resize(W * H)
	grid.fill(DIRT)
	floor_style.resize(W * H)
	floor_style.fill(3)
	for y in H:
		for x in W:
			if x < 2 or y < 2 or x >= W - 2 or y >= H - 2:
				grid[y * W + x] = BEDROCK
	rooms.clear()
	nest_spots.clear()

	# the lift lands near the south edge, so the camera looks into the mine
	lift_cell = Vector2i(rng.randi_range(18, W - 19), rng.randi_range(H - 17, H - 14))
	rooms.append({"c": lift_cell, "r": 9.0, "kind": "lift"})
	for i in 600:
		if rooms.size() >= (8 if ftype == "vault" else 12):
			break
		var r := rng.randf_range(4.0, 7.5)
		var c := Vector2i(rng.randi_range(5 + int(r), W - 6 - int(r)), rng.randi_range(5 + int(r), H - 6 - int(r)))
		var ok := true
		for o in rooms:
			if Vector2(c).distance_to(Vector2(o.c)) < r + o.r + 5.0:
				ok = false
				break
		if ok:
			rooms.append({"c": c, "r": r, "kind": "room"})

	# the shard waits in the room farthest from the lift
	var far_i := 1
	for i in range(1, rooms.size()):
		if Vector2(rooms[i].c).distance_to(Vector2(lift_cell)) > Vector2(rooms[far_i].c).distance_to(Vector2(lift_cell)):
			far_i = i
	rooms[far_i].kind = "shard"
	rooms[far_i].r = maxf(rooms[far_i].r, 6.8 if (ftype == "miniboss" or ftype == "boss") else 5.0)
	shard_room = rooms[far_i]
	shard_cell = shard_room.c

	for room in rooms:
		_carve_blob(room.c, room.r)

	# connect rooms: each joins the nearest already-connected room
	var connected: Array = [rooms[0]]
	var rest: Array = rooms.slice(1)
	rest.sort_custom(func(a, b): return Vector2(a.c).distance_to(Vector2(lift_cell)) < Vector2(b.c).distance_to(Vector2(lift_cell)))
	for room in rest:
		var best = connected[0]
		for o in connected:
			if Vector2(o.c).distance_to(Vector2(room.c)) < Vector2(best.c).distance_to(Vector2(room.c)):
				best = o
		_carve_tunnel(best.c, room.c, rng.randf_range(1.6, 2.3))
		connected.append(room)
	# a couple of loops so it is not a pure tree
	for i in 2:
		var a = rooms[rng.randi_range(0, rooms.size() - 1)]
		var b = rooms[rng.randi_range(0, rooms.size() - 1)]
		if a != b and a.kind != "shard" and b.kind != "shard":
			_carve_tunnel(a.c, b.c, 1.5)
	# dead-end side tunnels
	for i in 7:
		var start := _random_floor_cell()
		var ang := rng.randf() * TAU
		var steps_n := rng.randi_range(6, 14)
		var p := Vector2(start)
		for s in steps_n:
			ang += rng.randf_range(-0.4, 0.4)
			p += Vector2.from_angle(ang)
			_carve_disc(p, 1.3)
	# hidden pockets you only find by digging
	covered.clear()
	crate_spots.clear()
	for i in 4:
		var c := Vector2i(rng.randi_range(8, W - 9), rng.randi_range(8, H - 9))
		if cell_at(c) == DIRT and _far_from_floor(c, 4):
			var before := grid.duplicate()
			_carve_blob(c, rng.randf_range(2.0, 3.0))
			for y in range(c.y - 7, c.y + 8):
				for x in range(c.x - 7, c.x + 8):
					var q := Vector2i(x, y)
					if in_bounds(q) and before[idx(q)] != FLOOR and grid[idx(q)] == FLOOR:
						covered[q] = true
			for j in 6:
				_ore_vein(c + Vector2i(rng.randi_range(-3, 3), rng.randi_range(-3, 3)), 3)
			if covered.has(c):
				crate_spots.append({"cell": c, "pocket": true})

	_erode_caves()

	# seal the shard room behind a ring of hard rock
	var sc: Vector2i = shard_room.c
	var sr: float = shard_room.r
	for y in range(sc.y - int(sr) - 4, sc.y + int(sr) + 5):
		for x in range(sc.x - int(sr) - 4, sc.x + int(sr) + 5):
			var c := Vector2i(x, y)
			var d := Vector2(c).distance_to(Vector2(sc))
			if d >= sr + 0.2 and d <= sr + 2.6 and cell_at(c) != BEDROCK:
				set_cell(c, HARD)
	_carve_blob(sc, sr - 0.4)

	# ore veins along the tunnels
	for i in 34:
		var c := _random_wall_next_to_floor()
		_ore_vein(c, rng.randi_range(3, 7))

	# nests: a few rooms get sleeping crawlers, the shard room gets guards
	var candidates: Array = rooms.filter(func(r): return r.kind == "room")
	candidates.shuffle()
	var nest_count := mini(candidates.size(), 3 + depth / 2)
	for i in nest_count:
		var room = candidates[i]
		room.kind = "nest"
		for j in rng.randi_range(2, 3) + (1 if depth >= 3 else 0):
			nest_spots.append(_floor_near(room.c, room.r - 1.0))
	var guards := 0
	if ftype == "mine":
		guards = 2 + depth / 3
	elif ftype == "vault":
		guards = 4 + depth / 3
	for j in guards:
		nest_spots.append(_floor_near(sc, sr - 1.5))
	boss_spot = sc + Vector2i(0, 2)
	if ftype == "vault":
		for i in 3:
			var a := TAU * i / 3.0 + 0.5
			var vc := sc + Vector2i(roundi(cos(a) * (sr - 1.6)), roundi(sin(a) * (sr - 1.6)))
			if not is_floor(vc):
				vc = _floor_near(sc, sr - 1.5)
			crate_spots.append({"cell": vc, "pocket": true})

	# supply crates in ordinary rooms (never on the lift or in the shard room)
	var crate_rooms: Array = rooms.filter(func(r): return r.kind == "room" or r.kind == "nest")
	crate_rooms.shuffle()
	for i in mini(crate_rooms.size(), 3 + depth / 2):
		var cc := _floor_near(crate_rooms[i].c, crate_rooms[i].r - 1.5)
		if is_floor(cc):
			crate_spots.append({"cell": cc, "pocket": false})

	_build_astar()
	_build_fine_all()
	_build_all_chunks()
	_place_ore_lights()
	_place_cave_decor({})


func _carve_disc(p: Vector2, r: float) -> void:
	for y in range(int(p.y - r) - 1, int(p.y + r) + 2):
		for x in range(int(p.x - r) - 1, int(p.x + r) + 2):
			var c := Vector2i(x, y)
			if Vector2(x + 0.5, y + 0.5).distance_to(p + Vector2(0.5, 0.5)) <= r and cell_at(c) != BEDROCK:
				set_cell(c, FLOOR)


func _carve_blob(c: Vector2i, r: float) -> void:
	var phase := rng.randf() * TAU
	var wob := rng.randf_range(0.6, 1.4)
	for y in range(c.y - int(r) - 3, c.y + int(r) + 4):
		for x in range(c.x - int(r) - 3, c.x + int(r) + 4):
			var d := Vector2(x - c.x, y - c.y)
			var rr := r + sin(d.angle() * 3.0 + phase) * wob + sin(d.angle() * 5.0 + phase * 2.0) * 0.5
			if d.length() <= rr and cell_at(Vector2i(x, y)) != BEDROCK:
				set_cell(Vector2i(x, y), FLOOR)


func _carve_tunnel(a: Vector2i, b: Vector2i, width: float) -> void:
	var p := Vector2(a)
	var target := Vector2(b)
	var heading := (target - p).angle()
	for i in 600:
		if p.distance_to(target) < 1.5:
			break
		var want := (target - p).angle()
		heading = lerp_angle(heading, want, 0.25) + rng.randf_range(-0.35, 0.35)
		p += Vector2.from_angle(heading)
		_carve_disc(p, width)


func _ore_vein(c: Vector2i, n: int) -> void:
	var p := c
	for i in n:
		if cell_at(p) == DIRT:
			set_cell(p, ORE)
		p += [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)][rng.randi_range(0, 3)]


func _random_floor_cell() -> Vector2i:
	for i in 2000:
		var c := Vector2i(rng.randi_range(2, W - 3), rng.randi_range(2, H - 3))
		if is_floor(c):
			return c
	return lift_cell


func _random_wall_next_to_floor() -> Vector2i:
	for i in 2000:
		var c := Vector2i(rng.randi_range(2, W - 3), rng.randi_range(2, H - 3))
		if cell_at(c) != DIRT:
			continue
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			if is_floor(c + d):
				return c
	return Vector2i(3, 3)


func _far_from_floor(c: Vector2i, r: int) -> bool:
	for y in range(c.y - r, c.y + r + 1):
		for x in range(c.x - r, c.x + r + 1):
			if is_floor(Vector2i(x, y)):
				return false
	return true


func _floor_near(c: Vector2i, r: float) -> Vector2i:
	for i in 200:
		var o := Vector2.from_angle(rng.randf() * TAU) * rng.randf() * maxf(r, 1.0)
		var p := c + Vector2i(o.round())
		if is_floor(p):
			return p
	return c


func _build_astar() -> void:
	astar = AStarGrid2D.new()
	astar.region = Rect2i(0, 0, W, H)
	astar.cell_size = Vector2(1, 1)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.update()
	for y in H:
		for x in W:
			if grid[y * W + x] != FLOOR:
				astar.set_point_solid(Vector2i(x, y), true)


# Cells reachable from the lift by walking (used to place swarm spawns).
func reachable_cells_from(start: Vector2i) -> Dictionary:
	var dist := {start: 0}
	var queue: Array[Vector2i] = [start]
	var head := 0
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if is_floor(n) and not dist.has(n):
				dist[n] = dist[c] + 1
				queue.append(n)
	return dist


# ------------------------------------------------------------------ decor and lights
func _clear_decor() -> void:
	if decor:
		decor.queue_free()
	decor = Node3D.new()
	add_child(decor)
	tree_nodes.clear()
	ore_lights.clear()
	surface.clear()


func _place_ore_lights(only: Dictionary = {}) -> void:
	var cands: Array = []
	for y in H:
		for x in W:
			var c := Vector2i(x, y)
			if grid[idx(c)] != ORE:
				continue
			for d in DIRS4:
				if is_floor(c + d) and not covered.has(c + d) and (only.is_empty() or only.has(c + d)):
					cands.append([c, d])
					break
	cands.shuffle()
	var picked: Array = []
	for e in cands:
		if ore_lights.size() >= 40:
			break
		var c: Vector2i = e[0]
		var ok := true
		for q in picked:
			if Vector2(q).distance_to(Vector2(c)) < 6.0:
				ok = false
				break
		if not ok:
			continue
		picked.append(c)
		var cells: Array = []
		for yy in range(c.y - 2, c.y + 3):
			for xx in range(c.x - 2, c.x + 3):
				if cell_at(Vector2i(xx, yy)) == ORE:
					cells.append(Vector2i(xx, yy))
		var d: Vector2i = e[1]
		var l := OmniLight3D.new()
		l.position = cell_to_world(c) + Vector3(d.x, 0, d.y) * 0.45 + Vector3(0, 0.7, 0)
		l.light_color = Color("6fe8ff") if (c.x + c.y) % 2 == 0 else Color("b892ff")
		l.light_energy = 1.1
		l.omni_range = 3.8
		l.omni_attenuation = 1.2
		decor.add_child(l)
		ore_lights.append({"light": l, "cells": cells})


func _update_ore_lights(dug: Vector2i) -> void:
	var keep: Array = []
	for e in ore_lights:
		if dug in e.cells:
			var any := false
			for c in e.cells:
				if cell_at(c) == ORE:
					any = true
					break
			if not any:
				e.light.queue_free()
				continue
		keep.append(e)
	ore_lights = keep


func _add_decor_mesh(mesh: Mesh, pos: Vector3, rot_y: float = 0.0, scale_v: float = 1.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.rotation.y = rot_y
	mi.scale = Vector3.ONE * scale_v
	decor.add_child(mi)
	return mi


func _multimesh(mesh: Mesh, xforms: Array) -> void:
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	decor.add_child(mmi)


func _xform(pos: Vector3, rot_y: float, sc: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, rot_y).scaled(Vector3.ONE * sc), pos)


# ------------------------------------------------------------------ the surface (prologue)
func _carve_trail(a: Vector2i, b: Vector2i, width: float, out: Dictionary) -> void:
	var p := Vector2(a)
	var target := Vector2(b)
	var heading := (target - p).angle()
	for i in 400:
		if p.distance_to(target) < 1.0:
			break
		heading = lerp_angle(heading, (target - p).angle(), 0.35) + rng.randf_range(-0.2, 0.2)
		p += Vector2.from_angle(heading) * 0.8
		for y in range(int(p.y - width) - 1, int(p.y + width) + 2):
			for x in range(int(p.x - width) - 1, int(p.x + width) + 2):
				var c := Vector2i(x, y)
				if Vector2(x, y).distance_to(p) <= width and in_bounds(c) and cell_at(c) != BEDROCK:
					set_cell(c, FLOOR)
					out[c] = true


func _bfs_path(a: Vector2i, b: Vector2i, passable: Array) -> Array:
	var prev := {a: a}
	var q: Array[Vector2i] = [a]
	var h := 0
	while h < q.size():
		var c := q[h]
		h += 1
		if c == b:
			break
		for d in DIRS4:
			var n: Vector2i = c + d
			if not prev.has(n) and cell_at(n) in passable:
				prev[n] = c
				q.append(n)
	var out: Array = []
	if not prev.has(b):
		return out
	var c: Vector2i = b
	while c != a:
		out.append(c)
		c = prev[c]
	out.append(a)
	return out


func _set_prop_rect(x0: int, y0: int, x1: int, y1: int) -> void:
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			set_cell(Vector2i(x, y), PROP)


func _plant_tree(c: Vector2i, variant: int) -> void:
	set_cell(c, TREE)
	var n := _add_decor_mesh(VK.tree_mesh(variant, c.x * 31 + c.y), cell_to_world(c), rng.randf() * TAU, rng.randf_range(0.85, 1.15))
	tree_nodes[c] = n


func generate_surface(seed_value: int) -> void:
	mode = "surface"
	depth = 0
	rng.seed = seed_value
	_clear_decor()
	grid.resize(W * H)
	grid.fill(THICKET)
	floor_style.resize(W * H)
	floor_style.fill(0)
	rooms.clear()
	nest_spots.clear()

	var camp := Vector2i(42, 67)
	var dark_c := Vector2i(40, 35)
	var temple := Vector2i(22, 16)
	var tower := Vector2i(60, 22)
	_carve_blob(camp, 9.0)
	_carve_blob(dark_c, 7.5)
	_carve_blob(temple, 8.5)
	_carve_blob(tower, 9.0)
	var trail := {}
	_carve_trail(Vector2i(42, 59), Vector2i(41, 41), 2.1, trail)
	_carve_trail(Vector2i(37, 29), Vector2i(23, 25), 2.0, trail)
	_carve_trail(Vector2i(29, 16), Vector2i(53, 21), 2.1, trail)
	for c in trail:
		floor_style[idx(c)] = 1
	for y in range(camp.y - 6, camp.y + 6):
		for x in range(camp.x - 6, camp.x + 6):
			if Vector2(x, y).distance_to(Vector2(camp)) < 5.0:
				floor_style[idx(Vector2i(x, y))] = 4

	# temple ruins: a broken square of stone with a south door and an east door
	for y in range(10, 23):
		for x in range(16, 29):
			var c := Vector2i(x, y)
			var edge := x == 16 or x == 28 or y == 10 or y == 22
			if edge:
				var gap := (y == 22 and x >= 21 and x <= 23) or (x == 28 and y >= 15 and y <= 17)
				var corner := (x == 16 or x == 28) and (y == 10 or y == 22)
				if gap:
					set_cell(c, FLOOR)
				elif corner or rng.randf() > 0.14:
					set_cell(c, RUIN)
				else:
					set_cell(c, FLOOR)
			else:
				set_cell(c, FLOOR)
			if not edge:
				floor_style[idx(c)] = 2
	for c in [Vector2i(19, 13), Vector2i(25, 13), Vector2i(19, 19), Vector2i(25, 19)]:
		set_cell(c, RUIN)
	_set_prop_rect(21, 13, 23, 15)
	_add_decor_mesh(VK.altar_mesh(), cell_to_world(Vector2i(22, 14)))

	# camp: fire, tents, crates
	set_cell(camp, PROP)
	_add_decor_mesh(VK.campfire_mesh(), cell_to_world(camp))
	for i in 4:
		var a := i * TAU / 4.0 + 0.4
		_add_decor_mesh(VK.log_seat_mesh(), cell_to_world(camp) + Vector3(cos(a), 0, sin(a)) * 1.3, -a + PI / 2.0)
	var tents := [
		{"cls": "Bodyguard", "cell": Vector2i(35, 72), "color": Color("a8433a")},
		{"cls": "Architect", "cell": Vector2i(42, 73), "color": Color("c99a2e")},
		{"cls": "Artificer", "cell": Vector2i(49, 72), "color": Color("2f8a9a")}]
	surface.tents = []
	for t in tents:
		var c: Vector2i = t.cell
		_set_prop_rect(c.x - 2, c.y - 1, c.x + 2, c.y + 2)
		for x in range(c.x - 1, c.x + 2):
			set_cell(Vector2i(x, c.y - 2), FLOOR)
			set_cell(Vector2i(x, c.y - 3), FLOOR)
			floor_style[idx(Vector2i(x, c.y - 3))] = 4
		var tp := cell_to_world(c) + Vector3(0, 0, 0.25)
		_add_decor_mesh(VK.tent_mesh(t.color, t.cls), tp, PI)
		var lantern := OmniLight3D.new()
		lantern.light_color = Color("ffcc77")
		lantern.light_energy = 1.2
		lantern.omni_range = 4.5
		lantern.position = tp + Vector3(0, 1.2, -1.6)
		decor.add_child(lantern)
		var sign := Label3D.new()
		sign.text = t.cls.to_upper()
		sign.font_size = 44
		sign.outline_size = 10
		sign.pixel_size = 0.006
		sign.modulate = t.color.lightened(0.45)
		sign.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		sign.position = tp + Vector3(0, 2.25, 0)
		decor.add_child(sign)
		surface.tents.append({"cls": t.cls, "door": cell_to_world(Vector2i(c.x, c.y - 3)), "color": t.color})
	for c in [Vector2i(37, 61), Vector2i(38, 61), Vector2i(48, 61), Vector2i(33, 66), Vector2i(51, 66)]:
		set_cell(c, PROP)
		_add_decor_mesh(VK.crate_mesh(), cell_to_world(c), rng.randf() * 0.4)

	# the gate, the fallen trees and the boulders across the first trail
	var gate: Array = []
	for y in range(54, 56):
		for x in range(30, 55):
			var c := Vector2i(x, y)
			if is_floor(c):
				set_cell(c, BARRIER)
				gate.append(c)
	surface.gate_cells = gate
	for y in range(50, 52):
		for x in range(30, 55):
			if is_floor(Vector2i(x, y)):
				_plant_tree(Vector2i(x, y), 0 if (x + y) % 2 else 1)
	for y in range(46, 48):
		for x in range(30, 55):
			if is_floor(Vector2i(x, y)):
				set_cell(Vector2i(x, y), BOULDER)
	surface.chop_line_z = cell_to_world(Vector2i(0, 45)).z

	# protect the main route from decorative trees
	var pass_all := [FLOOR, BARRIER, TREE, BOULDER]
	var route: Array = _bfs_path(camp + Vector2i(0, -2), Vector2i(22, 17), pass_all)
	route.append_array(_bfs_path(Vector2i(22, 17), tower, pass_all))
	var protect := {}
	for c in route:
		for y in range(-2, 3):
			for x in range(-2, 3):
				protect[c + Vector2i(x, y)] = true
	surface.route_ok = route.size() > 0

	# trees inside the clearings
	for i in 140:
		var c := Vector2i(rng.randi_range(4, W - 5), rng.randi_range(4, H - 5))
		if not is_floor(c) or protect.has(c) or floor_style[idx(c)] != 0:
			continue
		if Vector2(c).distance_to(Vector2(camp)) < 7.0 or Vector2(c).distance_to(Vector2(tower)) < 6.5:
			continue
		var near_wall := false
		for d in DIRS4:
			if cell_at(c + d) == PROP or cell_at(c + d) == RUIN:
				near_wall = true
		if near_wall:
			continue
		var dark := c.y >= 24 and c.y <= 44 and c.x >= 28 and c.x <= 54
		_plant_tree(c, (2 if dark else rng.randi_range(0, 3)))

	# the dark woods and its sleeping critters
	surface.dark_rect = Rect2(cell_to_world(Vector2i(27, 23)).x, cell_to_world(Vector2i(27, 23)).z, 14.0, 11.0)
	for i in 6:
		var c := _floor_near(dark_c + Vector2i(0, -3), 4.5)
		if not protect.has(c) or i < 6:
			nest_spots.append(c)
	surface.camp = cell_to_world(camp)
	surface.altar = cell_to_world(Vector2i(22, 14)) + Vector3(0, 0.5, 0)
	surface.temple = cell_to_world(temple)
	lift_cell = tower + Vector2i(0, 1)
	shard_cell = Vector2i(22, 14)

	# forest canopy over the thicket, plus grass, flowers, rocks, mushrooms
	var fdist := {}
	var fq: Array[Vector2i] = []
	for y in H:
		for x in W:
			var c := Vector2i(x, y)
			if cell_at(c) != THICKET:
				fdist[c] = 0
				fq.append(c)
	var fh := 0
	while fh < fq.size():
		var c := fq[fh]
		fh += 1
		for d in DIRS4:
			var n: Vector2i = c + d
			if in_bounds(n) and not fdist.has(n):
				fdist[n] = fdist[c] + 1
				fq.append(n)
	var forest := [[], [], [], []]
	var bushes := [[], [], []]
	for y in range(0, H, 2):
		for x in range(0, W, 2):
			var c := Vector2i(x + rng.randi_range(0, 1), y + rng.randi_range(0, 1))
			if cell_at(c) != THICKET or fdist.get(c, 0) < 3:
				continue
			var v := rng.randi_range(0, 3)
			if c.y >= 22 and c.y <= 46 and c.x >= 26 and c.x <= 56:
				v = 2
			forest[v].append(_xform(cell_to_world(c) + Vector3(rng.randf_range(-0.2, 0.2), 0.5, rng.randf_range(-0.2, 0.2)), rng.randf() * TAU, rng.randf_range(0.85, 1.15)))
	for y in H:
		for x in W:
			var c := Vector2i(x, y)
			if cell_at(c) == THICKET and fdist.get(c, 0) >= 1 and fdist.get(c, 0) <= 2 and rng.randf() < 0.45:
				bushes[rng.randi_range(0, 2)].append(_xform(cell_to_world(c) + Vector3(rng.randf_range(-0.15, 0.15), 0.5, rng.randf_range(-0.15, 0.15)), rng.randf() * TAU, rng.randf_range(0.8, 1.2)))
	for v in 4:
		_multimesh(VK.tree_mesh(v, v * 13), forest[v])
	for v in 3:
		_multimesh(VK.bush_mesh(v * 7 + 1), bushes[v])
	var tufts := [[], [], [], []]
	for y in H:
		for x in W:
			var c := Vector2i(x, y)
			if not is_floor(c):
				continue
			var st := floor_style[idx(c)]
			var r := rng.randf()
			var pos := cell_to_world(c) + Vector3(rng.randf_range(-0.2, 0.2), 0, rng.randf_range(-0.2, 0.2))
			var dark := c.y >= 23 and c.y <= 45 and c.x >= 27 and c.x <= 55
			if st == 0 and r < 0.35:
				tufts[0].append(_xform(pos, rng.randf() * TAU, 1.0))
			elif st == 0 and r < 0.40 and not dark:
				tufts[1].append(_xform(pos, rng.randf() * TAU, 1.0))
			elif r < 0.43:
				tufts[2].append(_xform(pos, rng.randf() * TAU, rng.randf_range(0.8, 1.4)))
			elif dark and r < 0.5:
				tufts[3].append(_xform(pos, rng.randf() * TAU, 1.0))
	for k in 4:
		_multimesh(VK.tuft_mesh(k), tufts[k])
	for i in 10:
		var c := Vector2i(rng.randi_range(12, 34), rng.randi_range(6, 28))
		if is_floor(c) and floor_style[idx(c)] == 0 and not protect.has(c):
			set_cell(c, PROP)
			_add_decor_mesh(VK.ruin_pillar_mesh(i), cell_to_world(c), rng.randf() * TAU)

	_build_astar()
	_build_all_chunks()


# ------------------------------------------------------------------ meshing
func wall_height(t: int) -> float:
	match t:
		DIRT, ORE, HARD, BEDROCK:
			return WALL_H
		BOULDER:
			return 0.75
		THICKET:
			return 0.55
		RUIN:
			return 1.25
		BARRIER:
			return 0.5
	return 0.0


func _floor_color(c: Vector2i, h: int) -> Color:
	match floor_style[idx(c)]:
		0:
			var base := Color("3e6b34") if h % 5 else Color("4a7a3a")
			if h % 23 == 0:
				base = Color("5d8c42")
			return VK.jitter(base, 0.12, h)
		1:
			return VK.jitter(Color("6b5138") if h % 4 else Color("594330"), 0.1, h)
		2:
			return VK.jitter(Color("6e6a64") if h % 6 else Color("57524c"), 0.08, h)
		4:
			return VK.jitter(Color("6a5a40") if h % 3 else Color("526a3a"), 0.12, h)
	return VK.jitter(Color("2f2925"), 0.12, h)


func _wall_color(t: int, h: int, side: bool) -> Color:
	match t:
		DIRT:
			var base := Color("4a3426") if side else Color("33251c")
			if h % 11 == 0:
				base = Color("5a4030") if side else Color("3d2c20")
			return VK.jitter(base, 0.12, h)
		ORE:
			return VK.jitter(Color("3b2c25"), 0.1, h)
		HARD:
			return VK.jitter(Color("3d3f47") if side else Color("2b2d33"), 0.1, h)
		BEDROCK:
			return VK.jitter(Color("1a1a1e"), 0.08, h)
		BOULDER:
			return VK.jitter(Color("7d7973") if h % 4 else Color("66625b"), 0.1, h)
		THICKET:
			return VK.jitter(Color("2c4a28") if h % 3 else Color("37592f"), 0.14, h)
		RUIN:
			if not side and h % 3 == 0:
				return VK.jitter(Color("56704a"), 0.1, h)
			return VK.jitter(Color("7a766e") if h % 5 else Color("8b867c"), 0.07, h)
		BARRIER:
			return VK.jitter(Color("6b4423") if h % 6 else Color("c49a6c"), 0.08, h)
	return Color.MAGENTA


func _build_all_chunks() -> void:
	for k in chunk_nodes:
		chunk_nodes[k].queue_free()
	chunk_nodes.clear()
	dirty_chunks.clear()
	if mode == "mine":
		for cy in ceili(float(H) / CAVE_CHUNK):
			for cx in ceili(float(W) / CAVE_CHUNK):
				_build_cave_chunk(Vector2i(cx, cy))
		return
	for cy in ceili(float(H) / CHUNK):
		for cx in ceili(float(W) / CHUNK):
			_build_chunk(Vector2i(cx, cy))


func _rebuild_chunks_near(c: Vector2i) -> void:
	var seen := {}
	for d in [Vector2i(0, 0), Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n: Vector2i = c + d
		var k := Vector2i(floori(float(n.x) / CHUNK), floori(float(n.y) / CHUNK))
		if not seen.has(k):
			seen[k] = true
			_build_chunk(k)


func _build_chunk(k: Vector2i) -> void:
	if chunk_nodes.has(k):
		chunk_nodes[k].queue_free()
		chunk_nodes.erase(k)
	var solid := SurfaceTool.new()
	solid.begin(Mesh.PRIMITIVE_TRIANGLES)
	var glow := SurfaceTool.new()
	glow.begin(Mesh.PRIMITIVE_TRIANGLES)
	var has_glow := false
	var n_sub := int(CELL / SUB)
	for y in range(k.y * CHUNK, mini((k.y + 1) * CHUNK, H)):
		for x in range(k.x * CHUNK, mini((k.x + 1) * CHUNK, W)):
			var c := Vector2i(x, y)
			var t := cell_at(c)
			var x0 := x * CELL
			var z0 := y * CELL
			var hgt := wall_height(t)
			# top (floor or wall top)
			for sx in n_sub:
				for sz in n_sub:
					var h := VK.hash3(Vector3i(x * 2 + sx, 9, y * 2 + sz))
					var px := x0 + sx * SUB
					var pz := z0 + sz * SUB
					var col: Color
					var st := solid
					if hgt == 0.0:
						col = _floor_color(c, h)
					else:
						col = _wall_color(t, h, false)
						if t == ORE and h % 9 == 0:
							col = Color("3aa9bb") if h % 2 == 0 else Color("6e58b8")
							st = glow
							has_glow = true
					VK.quad(st, Vector3(px, hgt, pz), Vector3(px + SUB, hgt, pz), Vector3(px + SUB, hgt, pz + SUB), Vector3(px, hgt, pz + SUB), Vector3.UP, col)
			if hgt == 0.0:
				continue
			# sides, down to whatever is next door
			for d in DIRS4:
				var nh := wall_height(cell_at(c + d))
				if nh >= hgt:
					continue
				var nrm := Vector3(d.x, 0, d.y)
				var rows := ceili((hgt - nh) / SUB - 0.01)
				for si in n_sub:
					for sy in rows:
						var ya := nh + sy * SUB
						var yb := minf(ya + SUB, hgt)
						var h := VK.hash3(Vector3i(x * 7 + d.x * 3 + si, sy, y * 7 + d.y * 3))
						var col := _wall_color(t, h, true)
						col = col.darkened(0.25 * (1.0 - (ya + SUB * 0.5) / maxf(hgt, 0.01)))
						var st := solid
						if t == ORE and (h % 3 == 0 or h % 5 == 0):
							col = Color("4fc6d8") if h % 2 == 0 else Color("8a70d8")
							st = glow
							has_glow = true
						var p0: Vector3
						var p1: Vector3
						if d.x != 0:
							var fx := x0 + (CELL if d.x > 0 else 0.0)
							p0 = Vector3(fx, ya, z0 + si * SUB)
							p1 = Vector3(fx, ya, z0 + (si + 1) * SUB)
						else:
							var fz := z0 + (CELL if d.y > 0 else 0.0)
							p0 = Vector3(x0 + si * SUB, ya, fz)
							p1 = Vector3(x0 + (si + 1) * SUB, ya, fz)
						VK.quad(st, p0, p1, p1 + Vector3(0, yb - ya, 0), p0 + Vector3(0, yb - ya, 0), nrm, col)
	var mesh := ArrayMesh.new()
	solid.set_material(VK.mat_solid())
	solid.commit(mesh)
	if has_glow:
		glow.set_material(VK.mat_glow())
		glow.commit(mesh)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	add_child(mi)
	chunk_nodes[k] = mi


# ================================================================== caves (mines)
var ind := PackedByteArray()   # per cell: 1 = visible open floor


func _erode_caves() -> void:
	cave_noise.seed = rng.randi()
	cave_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	cave_noise.frequency = 0.07
	var en := FastNoiseLite.new()
	en.seed = rng.randi()
	en.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	en.frequency = 0.13
	var near_pocket := {}
	for c in covered:
		for y in range(-3, 4):
			for x in range(-3, 4):
				near_pocket[c + Vector2i(x, y)] = true
	# roughen tunnel walls into organic shapes
	for it in 2:
		var add: Array = []
		for y in range(3, H - 3):
			for x in range(3, W - 3):
				var c := Vector2i(x, y)
				if grid[idx(c)] != DIRT or near_pocket.has(c):
					continue
				var touch := false
				for d in DIRS4:
					if grid[idx(c + d)] == FLOOR and not covered.has(c + d):
						touch = true
						break
				if touch and en.get_noise_2d(x, y) > (0.1 if it == 0 else 0.3):
					add.append(c)
		for c in add:
			grid[idx(c)] = FLOOR
	# rock pillars standing inside the wider chambers
	var dist := {}
	var q: Array[Vector2i] = []
	for y in H:
		for x in W:
			var c := Vector2i(x, y)
			if grid[idx(c)] != FLOOR:
				dist[c] = 0
				q.append(c)
	var h := 0
	while h < q.size():
		var c := q[h]
		h += 1
		for d in DIRS4:
			var n: Vector2i = c + d
			if in_bounds(n) and not dist.has(n):
				dist[n] = dist[c] + 1
				q.append(n)
	for y in H:
		for x in W:
			var c := Vector2i(x, y)
			if dist.get(c, 0) >= 4 and en.get_noise_2d(x * 2.3 + 91.0, y * 2.3) < -0.42:
				if Vector2(c).distance_to(Vector2(lift_cell)) > 12.0 and Vector2(c).distance_to(Vector2(shard_cell)) > float(shard_room.get("r", 5.0)) + 3.0:
					grid[idx(c)] = DIRT


func _ind_cell(c: Vector2i) -> int:
	return 1 if grid[idx(c)] == FLOOR and not covered.has(c) else 0


func _fine_open_calc(fx: int, fz: int) -> int:
	var gx := (fx + 0.5) / F - 0.5
	var gz := (fz + 0.5) / F - 0.5
	var x0 := floori(gx)
	var z0 := floori(gz)
	var tx := gx - x0
	var tz := gz - z0
	tx = tx * tx * (3.0 - 2.0 * tx)
	tz = tz * tz * (3.0 - 2.0 * tz)
	if x0 < 0 or z0 < 0 or x0 >= W - 1 or z0 >= H - 1:
		return 0
	var i := z0 * W + x0
	var a := ind[i]
	var b := ind[i + 1]
	var c := ind[i + W]
	var d := ind[i + W + 1]
	if a + b + c + d == 0:
		return 0
	var v := lerpf(lerpf(a, b, tx), lerpf(c, d, tx), tz)
	return 1 if v > 0.5 + cave_noise.get_noise_2d(fx, fz) * 0.16 else 0


func _recompute_open(fx0: int, fz0: int, fx1: int, fz1: int) -> void:
	for fz in range(maxi(fz0, 0), mini(fz1, FW - 1) + 1):
		for fx in range(maxi(fx0, 0), mini(fx1, FW - 1) + 1):
			open_f[fz * FW + fx] = _fine_open_calc(fx, fz)


func _chamfer(which: int, x0: int, z0: int, x1: int, z1: int) -> void:
	var d: PackedFloat32Array = dwall if which == 0 else dfloor
	x0 = maxi(x0, 1)
	z0 = maxi(z0, 1)
	x1 = mini(x1, FW - 2)
	z1 = mini(z1, FW - 2)
	for z in range(z0, z1 + 1):
		var row := z * FW
		for x in range(x0, x1 + 1):
			var i := row + x
			var v := d[i]
			if v == 0.0:
				continue
			var w := d[i - 1] + 1.0
			if w < v:
				v = w
			w = d[i - FW] + 1.0
			if w < v:
				v = w
			w = d[i - FW - 1] + 1.4142
			if w < v:
				v = w
			w = d[i - FW + 1] + 1.4142
			if w < v:
				v = w
			d[i] = v
	for z in range(z1, z0 - 1, -1):
		var row := z * FW
		for x in range(x1, x0 - 1, -1):
			var i := row + x
			var v := d[i]
			if v == 0.0:
				continue
			var w := d[i + 1] + 1.0
			if w < v:
				v = w
			w = d[i + FW] + 1.0
			if w < v:
				v = w
			w = d[i + FW + 1] + 1.4142
			if w < v:
				v = w
			w = d[i + FW - 1] + 1.4142
			if w < v:
				v = w
			d[i] = v
	if which == 0:
		dwall = d
	else:
		dfloor = d


func _build_fine_all() -> void:
	ind.resize(W * H)
	for y in H:
		for x in W:
			ind[y * W + x] = _ind_cell(Vector2i(x, y))
	open_f.resize(FW * FW)
	_recompute_open(0, 0, FW - 1, FW - 1)
	dwall.resize(FW * FW)
	dfloor.resize(FW * FW)
	for i in FW * FW:
		var o := open_f[i] == 1
		dwall[i] = 0.0 if o else BIG
		dfloor[i] = BIG if o else 0.0
	_chamfer(0, 1, 1, FW - 2, FW - 2)
	_chamfer(1, 1, 1, FW - 2, FW - 2)


# After digging a cell: update the fine grid around it and queue the chunks to redraw.
func _cave_after_dig(c: Vector2i) -> void:
	var cells: Array = [c]
	for d in DIRS4:
		if covered.has(c + d):
			cells.append_array(_uncover(c + d))
	for q in cells:
		ind[idx(q)] = _ind_cell(q)
	var mn := Vector2i(W, H)
	var mx := Vector2i(-1, -1)
	for q in cells:
		mn = Vector2i(mini(mn.x, q.x), mini(mn.y, q.y))
		mx = Vector2i(maxi(mx.x, q.x), maxi(mx.y, q.y))
	var f0 := (mn - Vector2i(1, 1)) * F
	var f1 := (mx + Vector2i(2, 2)) * F
	_recompute_open(f0.x, f0.y, f1.x, f1.y)
	var m := int(VOID / FS) + 4
	for fz in range(maxi(f0.y, 0), mini(f1.y, FW - 1) + 1):
		for fx in range(maxi(f0.x, 0), mini(f1.x, FW - 1) + 1):
			if open_f[fz * FW + fx] == 1:
				dwall[fz * FW + fx] = 0.0
	_chamfer(0, f0.x - m, f0.y - m, f1.x + m, f1.y + m)
	var m2 := 8
	for fz in range(maxi(f0.y - m2, 1), mini(f1.y + m2, FW - 2) + 1):
		for fx in range(maxi(f0.x - m2, 1), mini(f1.x + m2, FW - 2) + 1):
			dfloor[fz * FW + fx] = BIG if open_f[fz * FW + fx] == 1 else 0.0
	_chamfer(1, f0.x - m2, f0.y - m2, f1.x + m2, f1.y + m2)
	var k0 := Vector2i(floori(float(mn.x - 4) / CAVE_CHUNK), floori(float(mn.y - 4) / CAVE_CHUNK))
	var k1 := Vector2i(floori(float(mx.x + 4) / CAVE_CHUNK), floori(float(mx.y + 4) / CAVE_CHUNK))
	for ky in range(maxi(k0.y, 0), k1.y + 1):
		for kx in range(maxi(k0.x, 0), k1.x + 1):
			dirty_chunks[Vector2i(kx, ky)] = true


func _uncover(start: Vector2i) -> Array:
	var out: Array = []
	var q: Array[Vector2i] = [start]
	covered.erase(start)
	while q.size() > 0:
		var c: Vector2i = q.pop_back()
		out.append(c)
		for d in DIRS4:
			if covered.has(c + d):
				covered.erase(c + d)
				q.append(c + d)
	last_uncovered += out.size()
	var only := {}
	for c in out:
		only[c] = true
	_place_ore_lights(only)
	_place_cave_decor(only)
	return out


func _process(_delta: float) -> void:
	if dirty_chunks.is_empty():
		return
	var n := 0
	for k in dirty_chunks.keys():
		dirty_chunks.erase(k)
		_build_cave_chunk(k)
		n += 1
		if n >= 4:
			break


func _cave_h(fx: int, fz: int) -> float:
	if fx < 0 or fz < 0 or fx >= FW or fz >= FW:
		return BIG
	var i := fz * FW + fx
	if open_f[i] == 1:
		return 0.0
	var d := dwall[i] * FS
	if d > VOID:
		return BIG
	var t := clampf((d - FS * 0.5) / RISE, 0.0, 1.0)
	var h := HMAX * sqrt(t) + cave_noise.get_noise_2d(fx * 3.1 + 500.0, fz * 3.1) * 0.16
	return clampf(snappedf(h, FS), FS, HMAX)


func _rock_color(t: int, d: float, h: float, hsh: int) -> Color:
	var base := Color("6b4a33")
	if depth >= 2:
		base = Color("5d4a3e")
	match t:
		HARD:
			base = Color("50586a")
		BEDROCK:
			base = Color("2b2b31")
	var lvl := int(roundf(h / FS))
	if lvl % 3 == 0:
		base = base.lightened(0.09)
	elif lvl % 4 == 1:
		base = base.darkened(0.1)
	if hsh % 17 == 0:
		base = base.lightened(0.18)
	var fade := clampf((d - 0.3) / (VOID - 0.3), 0.0, 1.0)
	base = base.darkened(fade * fade * 0.92)
	return VK.jitter(base, 0.07, hsh)


func _cave_floor_color(fx: int, fz: int, hsh: int) -> Color:
	var base := Color("3e332b") if hsh % 5 else Color("4a3d33")
	if hsh % 23 == 0:
		base = Color("5b5048")
	var wet := cave_noise.get_noise_2d(fx * 0.6 + 200.0, fz * 0.6)
	if wet > 0.42:
		base = Color("2c3540") if wet > 0.5 else Color("35383a")
	var df := dfloor[fz * FW + fx] * FS
	base = base.darkened((1.0 - clampf(df / 0.5, 0.0, 1.0)) * 0.5)
	return VK.jitter(base, 0.08, hsh)


func _build_cave_chunk(k: Vector2i) -> void:
	if chunk_nodes.has(k):
		chunk_nodes[k].queue_free()
		chunk_nodes.erase(k)
	var n := CAVE_CHUNK * F
	var bx := k.x * n
	var bz := k.y * n
	if bx >= FW or bz >= FW:
		return
	# heights with a one-column margin
	var hc := PackedFloat32Array()
	hc.resize((n + 2) * (n + 2))
	for z in n + 2:
		for x in n + 2:
			hc[z * (n + 2) + x] = _cave_h(bx + x - 1, bz + z - 1)
	var solid := SurfaceTool.new()
	solid.begin(Mesh.PRIMITIVE_TRIANGLES)
	var glow := SurfaceTool.new()
	glow.begin(Mesh.PRIMITIVE_TRIANGLES)
	var has_glow := false
	var dirs := [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for z in n:
		for x in n:
			var fx := bx + x
			var fz := bz + z
			if fx >= FW or fz >= FW:
				continue
			var h := hc[(z + 1) * (n + 2) + x + 1]
			if h >= BIG:
				continue
			var px := fx * FS
			var pz := fz * FS
			var hsh := VK.hash3(Vector3i(fx, 3, fz))
			if h == 0.0:
				VK.quad(solid, Vector3(px, 0, pz), Vector3(px + FS, 0, pz), Vector3(px + FS, 0, pz + FS), Vector3(px, 0, pz + FS), Vector3.UP, _cave_floor_color(fx, fz, hsh))
				continue
			var cell_t := cell_at(Vector2i(fx / F, fz / F))
			var d := dwall[fz * FW + fx] * FS
			var col := _rock_color(cell_t, d, h, hsh)
			var st := solid
			if cell_t == ORE and d < 0.75 and hsh % 3 == 0:
				col = Color("5fe0f2") if hsh % 2 == 0 else Color("a07cf0")
				st = glow
				has_glow = true
			VK.quad(st, Vector3(px, h, pz), Vector3(px + FS, h, pz), Vector3(px + FS, h, pz + FS), Vector3(px, h, pz + FS), Vector3.UP, col)
			for dd in dirs:
				var nh := hc[(z + 1 + dd.y) * (n + 2) + x + 1 + dd.x]
				if nh >= h:
					continue
				var nrm := Vector3(dd.x, 0, dd.y)
				var p0: Vector3
				var p1: Vector3
				if dd.x != 0:
					var sx := px + (FS if dd.x > 0 else 0.0)
					p0 = Vector3(sx, 0, pz)
					p1 = Vector3(sx, 0, pz + FS)
				else:
					var sz := pz + (FS if dd.y > 0 else 0.0)
					p0 = Vector3(px, 0, sz)
					p1 = Vector3(px + FS, 0, sz)
				var y := nh
				while y < h - 0.001:
					var y2 := minf(y + FS, h)
					var sh := VK.hash3(Vector3i(fx * 5 + dd.x, int(y * 8.0), fz * 5 + dd.y))
					var sc := _rock_color(cell_t, d, y2, sh).lightened(0.04)
					var sst := solid
					if cell_t == ORE and d < 0.75 and sh % 3 == 0:
						sc = Color("4fd2e6") if sh % 2 == 0 else Color("9070e0")
						sst = glow
						has_glow = true
					var up := Vector3(0, y, 0)
					var up2 := Vector3(0, y2, 0)
					VK.quad(sst, p0 + up, p1 + up, p1 + up2, p0 + up2, nrm, sc)
					y = y2
	var mesh := ArrayMesh.new()
	solid.set_material(VK.mat_solid())
	solid.commit(mesh)
	if has_glow:
		glow.set_material(VK.mat_glow())
		glow.commit(mesh)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	add_child(mi)
	chunk_nodes[k] = mi


# Stalagmites, pebbles, glowing mushrooms and crystal clusters on ore. only = limit to these cells.
func _place_cave_decor(only: Dictionary) -> void:
	var stal := [[], [], []]
	var peb: Array = []
	var mush: Array = []
	var lift_w := cell_to_world(lift_cell)
	for fz in range(1, FW - 1, 2):
		for fx in range(1, FW - 1, 2):
			var i := fz * FW + fx
			if open_f[i] != 1:
				continue
			var cell := Vector2i(fx / F, fz / F)
			if not only.is_empty() and not only.has(cell):
				continue
			var pos := Vector3((fx + 0.5) * FS, 0, (fz + 0.5) * FS)
			if Vector2(pos.x, pos.z).distance_to(Vector2(lift_w.x, lift_w.z)) < 2.8:
				continue
			var df := dfloor[i]
			var r := rng.randf()
			if df <= 2.0 and r < 0.02:
				stal[rng.randi_range(0, 2)].append(_xform(pos, rng.randf() * TAU, rng.randf_range(0.7, 1.3)))
			elif df <= 3.0 and r < 0.09:
				peb.append(_xform(pos, rng.randf() * TAU, rng.randf_range(0.6, 1.2)))
			elif r < 0.0035:
				mush.append(_xform(pos, rng.randf() * TAU, 1.0))
	for v in 3:
		_multimesh(VK.stalagmite_mesh(v), stal[v])
	_multimesh(VK.tuft_mesh(2), peb)
	_multimesh(VK.tuft_mesh(3), mush)
	for y in range(1, H - 1):
		for x in range(1, W - 1):
			var c := Vector2i(x, y)
			if grid[idx(c)] != ORE or crystal_nodes.has(c):
				continue
			for d in DIRS4:
				var nb: Vector2i = c + d
				if is_floor(nb) and not covered.has(nb) and (only.is_empty() or only.has(nb)):
					if rng.randf() < 0.55:
						var pos := cell_to_world(c) + Vector3(d.x, 0, d.y) * 0.32
						crystal_nodes[c] = _add_decor_mesh(VK.crystal_mesh(x * 7 + y), pos, rng.randf() * TAU, rng.randf_range(0.8, 1.2))
					break
