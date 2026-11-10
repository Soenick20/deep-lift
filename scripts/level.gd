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
	return not is_floor(world_to_cell(p))


# A square of half-size r around p must be entirely floor.
func can_occupy(p: Vector3, r: float) -> bool:
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
func generate(seed_value: int, depth_value: int) -> void:
	depth = depth_value
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
		if rooms.size() >= 12:
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
	rooms[far_i].r = maxf(rooms[far_i].r, 5.0)
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
	for i in 4:
		var c := Vector2i(rng.randi_range(8, W - 9), rng.randi_range(8, H - 9))
		if cell_at(c) == DIRT and _far_from_floor(c, 4):
			_carve_blob(c, rng.randf_range(2.0, 3.0))
			for j in 6:
				_ore_vein(c + Vector2i(rng.randi_range(-3, 3), rng.randi_range(-3, 3)), 3)

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
	for j in 2 + depth / 2:
		nest_spots.append(_floor_near(sc, sr - 1.5))

	_build_astar()
	_build_all_chunks()
	_place_ore_lights()


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


func _place_ore_lights() -> void:
	var cands: Array = []
	for y in H:
		for x in W:
			var c := Vector2i(x, y)
			if grid[idx(c)] != ORE:
				continue
			for d in DIRS4:
				if is_floor(c + d):
					cands.append([c, d])
					break
	cands.shuffle()
	var picked: Array = []
	for e in cands:
		if ore_lights.size() >= 34:
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
