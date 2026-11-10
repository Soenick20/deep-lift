# Builds every model in the prototype from voxels, in code. No external assets.
extends RefCounted

# Godot treats clockwise triangles as front faces.
const CLOCKWISE_FRONT := true

static var _mat_solid: StandardMaterial3D
static var _mat_glow: StandardMaterial3D


static func mat_solid() -> StandardMaterial3D:
	if _mat_solid == null:
		_mat_solid = StandardMaterial3D.new()
		_mat_solid.vertex_color_use_as_albedo = true
		_mat_solid.vertex_color_is_srgb = true
		_mat_solid.roughness = 1.0
		_mat_solid.metallic_specular = 0.1
	return _mat_solid


static func mat_glow() -> StandardMaterial3D:
	if _mat_glow == null:
		_mat_glow = StandardMaterial3D.new()
		_mat_glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mat_glow.vertex_color_use_as_albedo = true
		_mat_glow.vertex_color_is_srgb = true
	return _mat_glow


# Adds one quad. Corner order does not matter for facing: it is fixed from the normal.
static func quad(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, n: Vector3, col: Color) -> void:
	var ccw := (p1 - p0).cross(p2 - p0).dot(n) > 0.0
	var tris: Array
	if ccw == CLOCKWISE_FRONT:
		tris = [p0, p2, p1, p0, p3, p2]
	else:
		tris = [p0, p1, p2, p0, p2, p3]
	for p in tris:
		st.set_color(col)
		st.set_normal(n)
		st.add_vertex(p)


const FACE_DIRS := [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 1, 0),
	Vector3i(0, -1, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
const FACE_SHADE := [0.82, 0.82, 1.0, 0.55, 0.9, 0.72]


static func _face(st: SurfaceTool, base: Vector3, d: Vector3i, s: float, col: Color) -> void:
	var n := Vector3(d)
	# the 4 corners of a unit cube face, then scaled
	var a: Vector3
	var b: Vector3
	var c: Vector3
	var e: Vector3
	if d.x != 0:
		var x := 1.0 if d.x > 0 else 0.0
		a = Vector3(x, 0, 0); b = Vector3(x, 1, 0); c = Vector3(x, 1, 1); e = Vector3(x, 0, 1)
	elif d.y != 0:
		var y := 1.0 if d.y > 0 else 0.0
		a = Vector3(0, y, 0); b = Vector3(1, y, 0); c = Vector3(1, y, 1); e = Vector3(0, y, 1)
	else:
		var z := 1.0 if d.z > 0 else 0.0
		a = Vector3(0, 0, z); b = Vector3(1, 0, z); c = Vector3(1, 1, z); e = Vector3(0, 1, z)
	quad(st, base + a * s, base + b * s, base + c * s, base + e * s, n, col)


# vox / glow: Dictionary Vector3i -> Color. offset is in voxel units and is subtracted.
static func build_mesh(vox: Dictionary, s: float, offset: Vector3 = Vector3.ZERO, glow: Dictionary = {}) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var sets := [[vox, mat_solid()], [glow, mat_glow()]]
	for si in 2:
		var pair: Array = sets[si]
		var dict: Dictionary = pair[0]
		if dict.is_empty():
			continue
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for k in dict:
			var p: Vector3i = k
			var col: Color = dict[k]
			var base := (Vector3(p) - offset) * s
			for i in 6:
				var d: Vector3i = FACE_DIRS[i]
				var nb := p + d
				if vox.has(nb) or glow.has(nb):
					continue
				var shade: float = 1.0 if si == 1 else FACE_SHADE[i]
				_face(st, base, d, s, Color(col.r * shade, col.g * shade, col.b * shade, col.a))
		st.set_material(pair[1])
		st.commit(mesh)
	return mesh


static func jitter(c: Color, amount: float, h: int) -> Color:
	var f := 1.0 + (float(posmod(h * 2654435761, 1000)) / 1000.0 - 0.5) * 2.0 * amount
	return Color(clampf(c.r * f, 0, 1), clampf(c.g * f, 0, 1), clampf(c.b * f, 0, 1), c.a)


static func hash3(p: Vector3i) -> int:
	return absi(p.x * 73856093 ^ p.y * 19349663 ^ p.z * 83492791)


# ---------------------------------------------------------------- characters
const SKIN := Color("f2c4a0")
const HAIR := Color("6b3d22")
const PANTS := Color("4b5585")
const BOOTS := Color("3d2b20")
const BELT := Color("5a3a22")
const BUCKLE := Color("f0c040")
const SCARF := Color("cc3b30")
const EYE := Color("1d2236")
const MOUTH := Color("8f3a33")
const BLUSH := Color("f29a8c")

# The same 16-voxel adventurer from the size demo, split into parts for animation.
# Returns {part_name: {"mesh": ArrayMesh, "pivot": Vector3 (metres, model space)}}
static func character_parts(tunic: Color, hair: Color = HAIR, s: float = 1.0 / 16.0) -> Dictionary:
	var tunic_dark := tunic.darkened(0.3)
	var v := {}
	# legs
	for lx0 in [1, 5]:
		for x in range(lx0, lx0 + 2):
			for z in range(2, 5):
				for y in range(0, 4):
					v[Vector3i(x, y, z)] = BOOTS if y < 2 else PANTS
			v[Vector3i(x, 0, 5)] = BOOTS
	# torso
	for x in range(1, 7):
		for y in range(4, 9):
			for z in range(1, 5):
				v[Vector3i(x, y, z)] = BELT if y == 5 else (tunic_dark if y == 4 else tunic)
	v[Vector3i(3, 5, 4)] = BUCKLE
	v[Vector3i(4, 5, 4)] = BUCKLE
	# scarf
	for x in range(1, 7):
		for z in range(0, 6):
			v[Vector3i(x, 8, z)] = SCARF
	v[Vector3i(2, 7, -1)] = SCARF
	v[Vector3i(3, 6, -1)] = SCARF
	v[Vector3i(3, 5, -1)] = SCARF.darkened(0.25)
	# arms
	for ax in [0, 7]:
		for y in range(4, 9):
			for z in range(2, 4):
				v[Vector3i(ax, y, z)] = SKIN if y == 4 else tunic
	# head with hair
	var head := {}
	for x in range(0, 8):
		for ly in range(0, 7):
			for z in range(0, 7):
				var corner := (x == 0 or x == 7) and (ly == 0 or ly == 6) and (z == 0 or z == 6)
				if corner:
					continue
				var is_hair := false
				if ly == 6:
					is_hair = true
				elif z <= 3 and ly >= 1:
					is_hair = true
				elif (x == 0 or x == 7) and z <= 4 and ly >= 2:
					is_hair = true
				elif z >= 5 and (ly >= 5 or (ly == 4 and x % 3 != 1)):
					is_hair = true
				head[Vector3i(x, ly + 9, z)] = hair if is_hair else SKIN
	var shell := {}
	for k in head:
		if head[k] != hair:
			continue
		for d in [Vector3i(0, 1, 0), Vector3i(0, 0, -1), Vector3i(1, 0, 0), Vector3i(-1, 0, 0)]:
			var nb: Vector3i = k + d
			if not head.has(nb) and nb.z < 6 and nb.y > 9:
				shell[nb] = hair
	head.merge(shell)
	# face, painted on the front-most voxel of each column
	var paint := func(x: int, y: int, c: Color) -> void:
		for z in range(8, -2, -1):
			if head.has(Vector3i(x, y, z)):
				head[Vector3i(x, y, z)] = c
				return
	for y in [11, 12]:
		paint.call(2, y, EYE)
		paint.call(5, y, EYE)
	paint.call(3, 10, MOUTH)
	paint.call(4, 10, MOUTH)
	paint.call(1, 10, BLUSH)
	paint.call(6, 10, BLUSH)
	v.merge(head)

	# split into parts
	var parts := {"body": {}, "leg_l": {}, "leg_r": {}, "arm_l": {}, "arm_r": {}}
	for k in v:
		var p: Vector3i = k
		var part := "body"
		if p.y <= 3:
			part = "leg_l" if p.x <= 2 else "leg_r"
		elif (p.x == 0 or p.x == 7) and p.y >= 4 and p.y <= 8 and p.z >= 2 and p.z <= 3:
			part = "arm_l" if p.x == 0 else "arm_r"
		parts[part][p] = jitter(v[k], 0.04, hash3(p))
	var center := Vector3(4.0, 0.0, 3.5)
	var pivots := {
		"body": Vector3(4.0, 0.0, 3.5),
		"leg_l": Vector3(2.0, 4.0, 3.5), "leg_r": Vector3(6.0, 4.0, 3.5),
		"arm_l": Vector3(0.5, 8.5, 3.0), "arm_r": Vector3(7.5, 8.5, 3.0)}
	var out := {}
	for pname in parts:
		var pv: Vector3 = pivots[pname]
		out[pname] = {"mesh": build_mesh(parts[pname], s, pv), "pivot": (pv - center) * s}
	return out


# ---------------------------------------------------------------- monsters
static func crawler_parts(s: float = 0.06, shell: Color = Color("3a2347"), stripe: Color = Color("6a3f80"), eye: Color = Color("c6ff3d")) -> Dictionary:
	var body := {}
	var glow := {}
	for x in range(0, 11):
		for y in range(1, 7):
			for z in range(0, 13):
				var q := Vector3((x + 0.5 - 5.5) / 5.4, (y + 0.5 - 2.4) / 3.3, (z + 0.5 - 6.5) / 6.6)
				if q.length_squared() > 1.0:
					continue
				var c := shell
				if y == 1:
					c = shell.darkened(0.35)
				elif (x == 5) and z < 10:
					c = stripe
				elif z >= 11:
					c = shell.darkened(0.4)
				body[Vector3i(x, y, z)] = jitter(c, 0.08, hash3(Vector3i(x, y, z)))
	# glowing eyes on the front
	for ex in [3, 7]:
		for z in range(14, -1, -1):
			if body.has(Vector3i(ex, 3, z)):
				body.erase(Vector3i(ex, 3, z))
				glow[Vector3i(ex, 3, z)] = eye
				glow[Vector3i(ex, 3, z + 1)] = eye
				break
	body[Vector3i(4, 1, 13)] = Color("d8cfb8")
	body[Vector3i(6, 1, 13)] = Color("d8cfb8")
	var legs_a := {}
	var legs_b := {}
	var i := 0
	for z in [3, 6, 9]:
		for side in [-1, 11]:
			var tgt := legs_a if (i % 2 == 0) else legs_b
			tgt[Vector3i(side, 1, z)] = Color("1d1024")
			tgt[Vector3i(side + (1 if side < 0 else -1) * -1, 0, z)] = Color("1d1024")
			i += 1
	var center := Vector3(5.5, 0.0, 6.5)
	return {
		"body": build_mesh(body, s, center, glow),
		"legs_a": build_mesh(legs_a, s, center),
		"legs_b": build_mesh(legs_b, s, center)}


# ---------------------------------------------------------------- props
static func shard_mesh(s: float = 0.07) -> ArrayMesh:
	var glow := {}
	var a := Color("7ef6ff")
	var b := Color("b08cff")
	for y in range(0, 8):
		for x in range(0, 2):
			for z in range(0, 2):
				if y == 7 and (x + z) != 1:
					continue
				glow[Vector3i(x, y, z)] = a if (y + x) % 3 != 0 else Color("c8fbff")
	for y in range(0, 5):
		glow[Vector3i(-1, y, 0)] = b
		glow[Vector3i(2, y, 1)] = b
	for y in range(0, 4):
		glow[Vector3i(-2 + (1 if y > 1 else 0), y + 1, 0)] = b.lightened(0.2)
		glow[Vector3i(3 - (1 if y > 1 else 0), y + 1, 1)] = a.darkened(0.15)
	return build_mesh({}, s, Vector3(1.0, 0.0, 1.0), glow)


static func torch_mesh(s: float = 0.06) -> ArrayMesh:
	var v := {}
	var glow := {}
	for y in range(0, 7):
		v[Vector3i(0, y, 0)] = Color("6b4423")
	for x in range(-1, 1):
		for z in range(-1, 1):
			glow[Vector3i(x + 1, 7, z + 1) - Vector3i(1, 0, 1)] = Color("ffb347")
	glow[Vector3i(0, 8, 0)] = Color("ffe08a")
	glow[Vector3i(-1, 8, -1)] = Color("ff8c2a")
	return build_mesh(v, s, Vector3(0.5, 0.0, 0.5), glow)


static func arrow_mesh(s: float = 0.13) -> ArrayMesh:
	var glow := {}
	var rows := [
		"....#....",
		"...###...",
		"..#####..",
		".###.###.",
		"###...###"]
	for r in rows.size():
		var line: String = rows[r]
		for x in line.length():
			if line[x] == "#":
				glow[Vector3i(x, 0, r)] = Color("7ef6ff")
	return build_mesh({}, s, Vector3(4.5, 0.0, 2.5), glow)


# The living lift: a stone disc on the creature's back, a head facing the camera, a heart socket.
static func lift_meshes(s: float = 0.25) -> Dictionary:
	var plat := {}
	var plat_glow := {}
	var R := 8.4
	for x in range(-9, 10):
		for z in range(-9, 10):
			var d := Vector2(x, z).length()
			if d > R:
				continue
			var p := Vector3i(x, 0, z)
			var c := Color("5d5a57")
			var h := hash3(p)
			if h % 7 == 0:
				c = Color("4b5a3b")
			elif h % 5 == 0:
				c = Color("6c6965")
			if absf(d - 6.6) < 0.5 and h % 3 != 0:
				plat_glow[p] = Color("2f8f9c")
			else:
				plat[p] = jitter(c, 0.07, h)
			if d > R - 1.2:
				plat[Vector3i(x, -1, z)] = Color("3f3c3a")
	# heart pedestal
	for x in range(-1, 1):
		for z in range(-1, 1):
			plat[Vector3i(x, 1, z)] = Color("4a4745")
	# the creature's head sits at the far (north) edge and looks back at its passengers
	var head := {}
	var head_glow := {}
	for x in range(-3, 3):
		for y in range(1, 5):
			for z in range(-12, -8):
				if (x == -3 or x == 2) and y == 4:
					continue
				var p := Vector3i(x, y, z)
				head[p] = jitter(Color("77726b") if y < 4 else Color("625d57"), 0.08, hash3(p))
	for ex in [-2, 1]:
		head.erase(Vector3i(ex, 2, -9))
		head_glow[Vector3i(ex, 2, -9)] = Color("7ef6ff")
		head_glow[Vector3i(ex, 2, -8)] = Color("7ef6ff")
		head[Vector3i(ex, 3, -8)] = Color("4f4b47")
	for hx in [-3, 2]:
		head[Vector3i(hx, 5, -11)] = Color("8a8378")
		head[Vector3i(hx, 6, -11)] = Color("a49c90")
		head[Vector3i(hx, 7, -12)] = Color("b8afa1")
	return {
		"platform": build_mesh(plat, s, Vector3(0.0, 0.0, 0.0), plat_glow),
		"head": build_mesh(head, s, Vector3(0.0, 0.0, 0.0), head_glow)}


static func box_mesh(size: Vector3, col: Color, glow: bool = false) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = col
	if glow:
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.material = mat
	return m


# ================================================================ surface / prologue models
static func _pix_icon(rows: Array, palette: Dictionary, z: int, x0: int, y_top: int, out_v: Dictionary, out_glow: Dictionary, glow_keys: String = "") -> void:
	for r in rows.size():
		var line: String = rows[r]
		for x in line.length():
			var ch := line[x]
			if palette.has(ch):
				var p := Vector3i(x0 + x, y_top - r, z)
				if glow_keys.contains(ch):
					out_glow[p] = palette[ch]
				else:
					out_v[p] = palette[ch]


# variant: 0 oak, 1 pine, 2 dark pine, 3 birch-ish
static func tree_mesh(variant: int, seed_value: int = 0, s: float = 0.125) -> ArrayMesh:
	var v := {}
	var trunk := Color("5b3a24") if variant != 3 else Color("cfc6b4")
	var th := 7 if variant == 0 else (4 if variant != 3 else 9)
	for y in th:
		for x in range(0, 2):
			for z in range(0, 2):
				var c := trunk
				if variant == 3 and (y + x) % 4 == 0:
					c = Color("3b3631")
				v[Vector3i(x, y, z)] = jitter(c, 0.08, hash3(Vector3i(x, y, z) + Vector3i(seed_value, 0, 0)))
	# roots
	v[Vector3i(-1, 0, 0)] = trunk.darkened(0.2)
	v[Vector3i(2, 0, 1)] = trunk.darkened(0.2)
	if variant == 0 or variant == 3:
		var leaf_a := Color("3f7d36") if variant == 0 else Color("7fa83a")
		var leaf_b := Color("2f6430") if variant == 0 else Color("5f8a2c")
		var cy := 11.0 if variant == 0 else 12.0
		for x in range(-6, 8):
			for y in range(6, 17):
				for z in range(-6, 8):
					var q := Vector3((x - 0.5) / 5.6, (y - cy) / 4.2, (z - 0.5) / 5.6)
					var h := hash3(Vector3i(x, y, z) + Vector3i(seed_value * 7, 0, 0))
					if q.length() > 1.0 + (float(h % 100) / 100.0 - 0.5) * 0.35:
						continue
					var c := leaf_a if (h % 3) else leaf_b
					if y > cy + 2:
						c = c.lightened(0.12)
					if h % 41 == 0 and variant == 0:
						c = Color("d9534f")
					v[Vector3i(x, y, z)] = jitter(c, 0.1, h)
	else:
		var leaf := Color("2c5e45") if variant == 1 else Color("1f4434")
		var tiers := [[4, 7, 5.5], [7, 10, 4.5], [10, 13, 3.4], [13, 15, 2.2], [15, 17, 1.2]]
		for t in tiers:
			for y in range(t[0], t[1]):
				var rr: float = t[2] * (1.0 - float(y - t[0]) / (t[1] - t[0]) * 0.45)
				for x in range(-6, 8):
					for z in range(-6, 8):
						if Vector2(x - 0.5, z - 0.5).length() <= rr:
							var h := hash3(Vector3i(x, y, z) + Vector3i(seed_value * 3, 0, 0))
							var c := leaf if h % 4 else leaf.lightened(0.15)
							if y == t[0] and h % 3 == 0:
								c = leaf.darkened(0.25)
							v[Vector3i(x, y, z)] = jitter(c, 0.08, h)
	return build_mesh(v, s, Vector3(1.0, 0.0, 1.0))


static func bush_mesh(seed_value: int, s: float = 0.1) -> ArrayMesh:
	var v := {}
	for x in range(-3, 4):
		for y in range(0, 4):
			for z in range(-3, 4):
				var h := hash3(Vector3i(x, y, z) + Vector3i(seed_value, 5, 0))
				if Vector3(x, y * 1.4, z).length() > 3.4 + (h % 10) * 0.05:
					continue
				var c := Color("355f2e") if h % 3 else Color("4a7a36")
				if h % 29 == 0:
					c = Color("e7c84a")
				v[Vector3i(x, y, z)] = jitter(c, 0.1, h)
	return build_mesh(v, s, Vector3(0.5, 0, 0.5))


static func tuft_mesh(kind: int, s: float = 0.06) -> ArrayMesh:
	var v := {}
	var glow := {}
	match kind:
		0:  # grass tuft
			for p in [Vector3i(0, 0, 0), Vector3i(0, 1, 0), Vector3i(1, 0, 1), Vector3i(1, 1, 1), Vector3i(1, 2, 1), Vector3i(-1, 0, 1), Vector3i(-1, 1, 1), Vector3i(0, 0, 2)]:
				v[p] = jitter(Color("4f8a3a"), 0.15, hash3(p))
		1:  # flower
			v[Vector3i(0, 0, 0)] = Color("3f7a32")
			v[Vector3i(0, 1, 0)] = Color("3f7a32")
			v[Vector3i(0, 2, 0)] = Color("f2d24b")
			for d in [Vector3i(1, 2, 0), Vector3i(-1, 2, 0), Vector3i(0, 2, 1), Vector3i(0, 2, -1)]:
				v[d] = Color("e86b8f")
		2:  # small rock
			for p in [Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(0, 1, 0), Vector3i(1, 1, 1), Vector3i(2, 0, 1)]:
				v[p] = jitter(Color("7a7670"), 0.12, hash3(p))
		3:  # glowing mushrooms
			for m in [[0, 0, 2], [2, 1, 3], [-1, 2, 1]]:
				for y in m[2]:
					v[Vector3i(m[0], y, m[1])] = Color("d8d2c0")
				for d in [Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(-1, 0, 0), Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
					glow[Vector3i(m[0], m[2], m[1]) + d] = Color("5ff2d4")
	return build_mesh(v, s, Vector3(0.5, 0, 0.5), glow)


const TENT_ICONS := {
	"Bodyguard": [".rrr.", "rwwwr", "rwrwr", "rwwwr", ".rrr.", "..r.."],
	"Architect": ["kkkkk", "..b..", "..b..", "..b..", "..b..", "..b.."],
	"Artificer": [".g.g.", "ggggg", ".gkg.", "ggggg", ".g.g.", "....."]}


static func tent_mesh(canvas: Color, cls: String, s: float = 0.125) -> ArrayMesh:
	# 20 wide (x), 16 deep (z), door on +z
	var v := {}
	var glow := {}
	for z in range(0, 16):
		for x in range(0, 20):
			var top := int(12.0 - absf(x - 9.5) * 1.15)
			for y in range(0, top + 1):
				var c := canvas
				if y >= top - 1:
					c = canvas.lightened(0.1)
				if y < 2:
					c = canvas.darkened(0.25)
				if (x + z) % 7 == 0 and y > 2:
					c = canvas.darkened(0.08)
				# door opening and inside shadow on the front
				if z >= 14 and x >= 7 and x <= 12 and y <= 7:
					c = Color("24170f") if z == 15 else Color("2e1f15")
				v[Vector3i(x, y, z)] = jitter(c, 0.05, hash3(Vector3i(x, y, z)))
	# door flaps pulled open
	for y in range(0, 8):
		v[Vector3i(6, y, 16)] = canvas.lightened(0.15)
		v[Vector3i(13, y, 16)] = canvas.lightened(0.15)
	# ridge pole and pegs
	for z in range(-1, 18):
		v[Vector3i(9, 13, z)] = Color("6b4423")
		v[Vector3i(10, 13, z)] = Color("6b4423")
	for p in [Vector3i(-1, 0, 1), Vector3i(20, 0, 1), Vector3i(-1, 0, 14), Vector3i(20, 0, 14)]:
		v[p] = Color("8a6a46")
	# banner pole in front with the class icon
	for y in range(0, 20):
		v[Vector3i(16, y, 18)] = Color("6b4423")
	var board := canvas.darkened(0.45)
	for x in range(10, 17):
		for y in range(12, 20):
			v[Vector3i(x, y, 18)] = board
	var pal := {"r": Color("e05a4f"), "w": Color("d9dde2"), "k": Color("a7aab0"), "b": Color("8a5a32"), "g": Color("f0c040")}
	_pix_icon(TENT_ICONS[cls], pal, 19, 11, 18, v, glow, "")
	_pix_icon(TENT_ICONS[cls], pal, 17, 11, 18, v, glow, "")
	# lantern by the door
	glow[Vector3i(14, 8, 17)] = Color("ffcc66")
	v[Vector3i(14, 9, 17)] = Color("3a3a3a")
	return build_mesh(v, s, Vector3(10.0, 0.0, 8.0), glow)


static func campfire_mesh(s: float = 0.1) -> ArrayMesh:
	var v := {}
	var glow := {}
	for a in 12:
		var ang := a * TAU / 12.0
		var p := Vector3i(int(round(cos(ang) * 4.5)), 0, int(round(sin(ang) * 4.5)))
		v[p] = jitter(Color("6f6b66"), 0.15, hash3(p))
		v[p + Vector3i(0, 1, 0)] = jitter(Color("85807a"), 0.15, hash3(p) + 3)
	for i in range(-3, 4):
		v[Vector3i(i, 0, 0)] = Color("5b3a24")
		v[Vector3i(0, 1, i)] = Color("4a2e1c")
	for y in range(1, 6):
		for x in range(-1, 2):
			for z in range(-1, 2):
				if y > 3 and (x != 0 or z != 0) and (x + z + y) % 2 == 0:
					continue
				if y == 5 and (x != 0 or z != 0):
					continue
				glow[Vector3i(x, y, z)] = Color("ffd166") if y < 3 else (Color("ff9a3c") if y < 5 else Color("ff5f2e"))
	return build_mesh(v, s, Vector3(0.5, 0, 0.5), glow)


static func log_seat_mesh(s: float = 0.1) -> ArrayMesh:
	var v := {}
	for x in range(0, 10):
		for y in range(0, 2):
			for z in range(0, 2):
				v[Vector3i(x, y, z)] = jitter(Color("6b4423") if x > 0 and x < 9 else Color("c49a6c"), 0.1, hash3(Vector3i(x, y, z)))
	return build_mesh(v, s, Vector3(5, 0, 1))


static func crate_mesh(s: float = 0.1) -> ArrayMesh:
	var v := {}
	for x in 5:
		for y in 5:
			for z in 5:
				var edge := int(x == 0 or x == 4) + int(y == 0 or y == 4) + int(z == 0 or z == 4) >= 2
				v[Vector3i(x, y, z)] = Color("5e3d22") if edge else jitter(Color("9a6b3e"), 0.08, hash3(Vector3i(x, y, z)))
	return build_mesh(v, s, Vector3(2.5, 0, 2.5))


static func altar_mesh(s: float = 0.125) -> ArrayMesh:
	var v := {}
	var glow := {}
	for x in range(-5, 5):
		for z in range(-4, 4):
			for y in range(0, 4):
				if y == 3 and (x == -5 or x == 4 or z == -4 or z == 3):
					continue
				var c := Color("6d6a64") if y < 3 else Color("807c75")
				var h := hash3(Vector3i(x, y, z))
				if h % 9 == 0:
					c = Color("56704a")
				v[Vector3i(x, y, z)] = jitter(c, 0.08, h)
	for x in range(-4, 4, 2):
		glow[Vector3i(x, 1, 4)] = Color("6fe8ff")
		v.erase(Vector3i(x, 1, 3))
	for z in range(-3, 3, 2):
		glow[Vector3i(-6, 1, z)] = Color("6fe8ff")
		glow[Vector3i(5, 1, z)] = Color("6fe8ff")
	return build_mesh(v, s, Vector3(-0.5, 0, -0.5), glow)


# The sleeping creature looks like an old tower: a spire on its head. It sinks when the creature wakes.
static func spire_mesh(s: float = 0.25) -> ArrayMesh:
	var v := {}
	var glow := {}
	for y in range(0, 17):
		var r := 2.6 - y * 0.06
		if y >= 15:
			r = 1.2
		for x in range(-3, 4):
			for z in range(-3, 4):
				if Vector2(x, z).length() > r:
					continue
				var p := Vector3i(x, y, z)
				var h := hash3(p)
				var c := Color("6c6862") if h % 3 else Color("5d5954")
				if h % 11 == 0:
					c = Color("4f6b45")
				if (y == 4 or y == 9 or y == 13) and Vector2(x, z).length() > r - 1.0 and h % 2 == 0:
					glow[p] = Color("2f8f9c")
				else:
					v[p] = jitter(c, 0.07, h)
	glow[Vector3i(0, 17, 0)] = Color("7ef6ff")
	return build_mesh(v, s, Vector3(0.5, 0, 0.5), glow)


static func ruin_pillar_mesh(seed_value: int, s: float = 0.125) -> ArrayMesh:
	var v := {}
	var hmax := 10 + seed_value % 7
	for y in hmax:
		for x in range(0, 4):
			for z in range(0, 4):
				if y == hmax - 1 and (x + z + seed_value) % 3 == 0:
					continue
				var h := hash3(Vector3i(x, y, z) + Vector3i(seed_value, 0, 0))
				var c := Color("7c786f") if h % 4 else Color("5f7a52")
				v[Vector3i(x, y, z)] = jitter(c, 0.08, h)
	return build_mesh(v, s, Vector3(2, 0, 2))


# Class gear worn on top of the 16-voxel character (same grid and centre as character_parts).
static func class_gear_mesh(cls: String, s: float = 1.0 / 16.0) -> ArrayMesh:
	var v := {}
	var glow := {}
	match cls:
		"Bodyguard":
			for x in range(-1, 9):
				for z in range(-1, 8):
					for y in range(15, 18):
						var q := Vector2((x - 3.5) / 5.0, (z - 3.0) / 4.6)
						if q.length() > 1.0 - (y - 15) * 0.18:
							continue
						v[Vector3i(x, y, z)] = jitter(Color("8d939b"), 0.06, hash3(Vector3i(x, y, z)))
			for z in range(1, 6):
				v[Vector3i(3, 18, z)] = Color("c0392b")
				v[Vector3i(4, 18, z)] = Color("c0392b")
			v[Vector3i(3, 19, 2)] = Color("e74c3c")
			v[Vector3i(4, 19, 3)] = Color("e74c3c")
			# shoulder plates
			for z in range(1, 5):
				v[Vector3i(-1, 8, z)] = Color("8d939b")
				v[Vector3i(8, 8, z)] = Color("8d939b")
		"Architect":
			for x in range(-1, 9):
				for z in range(0, 8):
					for y in range(16, 18):
						var q := Vector2((x - 3.5) / 5.2, (z - 3.5) / 4.4)
						if q.length() > 1.0 - (y - 16) * 0.25:
							continue
						v[Vector3i(x, y, z)] = Color("d39a26") if (x + z) % 5 else Color("bf8a1f")
			for x in range(0, 8):
				v[Vector3i(x, 16, 8)] = Color("bf8a1f")
			glow[Vector3i(3, 17, 8)] = Color("fff2b0")
			glow[Vector3i(4, 17, 8)] = Color("fff2b0")
			# tool belt pouch
			v[Vector3i(6, 5, 5)] = Color("8a5a32")
			v[Vector3i(6, 4, 5)] = Color("8a5a32")
		"Artificer":
			for x in range(-1, 9):
				for z in range(-1, 8):
					if x >= 0 and x <= 7 and z >= 0 and z <= 6:
						continue
					if z == 7 and x >= 0 and x <= 7:
						continue
					v[Vector3i(x, 13, z)] = Color("3b2f28")
			for x in [1, 2, 5, 6]:
				glow[Vector3i(x, 13, 7)] = Color("7fe3f0")
			v[Vector3i(3, 13, 7)] = Color("3b2f28")
			v[Vector3i(4, 13, 7)] = Color("3b2f28")
			# backpack with a wrench
			for x in range(2, 6):
				for y in range(4, 8):
					v[Vector3i(x, y, 0)] = Color("7a5232")
					v[Vector3i(x, y, -1)] = Color("6b4628")
			for y in range(6, 10):
				v[Vector3i(5, y, -2)] = Color("a7aab0")
			v[Vector3i(4, 9, -2)] = Color("a7aab0")
			glow[Vector3i(3, 5, -2)] = Color("f0c040")
	return build_mesh(v, s, Vector3(4.0, 0.0, 3.5), glow)


static func stalagmite_mesh(variant: int, s: float = 0.0625) -> ArrayMesh:
	var v := {}
	var hgt: int = [8, 12, 6][variant % 3]
	var base_r: float = [1.8, 2.2, 1.5][variant % 3]
	var col := Color("5e4a3c") if variant != 1 else Color("6b6159")
	for y in hgt:
		var r: float = base_r * pow(1.0 - float(y) / hgt, 1.4)
		if y == hgt - 1:
			r = 0.0
		for x in range(-3, 4):
			for z in range(-3, 4):
				if Vector2(x, z).length() <= r:
					var p := Vector3i(x, y, z)
					v[p] = jitter(col.lightened(0.04 * y), 0.08, hash3(p) + variant)
	return build_mesh(v, s, Vector3(0.5, 0, 0.5))


static func crystal_mesh(seed_value: int, s: float = 0.05) -> ArrayMesh:
	var glow := {}
	var a := Color("7ef6ff")
	var b := Color("b892ff")
	var spikes := [[0, 0, 7], [2, 1, 4], [-2, 1, 5], [1, -2, 3]]
	for i in spikes.size():
		var sp: Array = spikes[i]
		var c := a if (i + seed_value) % 2 == 0 else b
		for y in sp[2]:
			var lean := int(y * 0.25 * sign(sp[0]))
			glow[Vector3i(sp[0] + lean, y, sp[1])] = c if y < sp[2] - 1 else c.lightened(0.4)
			if y < sp[2] / 2:
				glow[Vector3i(sp[0] + lean + 1, y, sp[1])] = c.darkened(0.15)
	return build_mesh({}, s, Vector3(0.5, 0, 0.5), glow)


# ================================================================ loot and stations
# Guns are built pointing along +z, grip hanging down at the origin.
static func gun_mesh(type: String, accent: Color, s: float = 1.0 / 24.0) -> ArrayMesh:
	var v := {}
	var glow := {}
	var metal := Color("3b3f46")
	var dark := Color("26282d")
	var wood := Color("7a4e2c")
	var length := 5
	match type:
		"Pistol":
			length = 5
		"Shotgun":
			length = 10
		"SMG":
			length = 7
		"Rifle":
			length = 12
	for z in length:
		v[Vector3i(0, 0, z)] = metal if z < length - 1 else dark
		if type != "Rifle" or z < 6:
			v[Vector3i(0, 1, z)] = metal.lightened(0.1)
	# grip
	for y in range(-3, 0):
		v[Vector3i(0, y, 0)] = wood if type == "Shotgun" or type == "Rifle" else dark
	match type:
		"Shotgun":
			for z in range(-4, 0):
				v[Vector3i(0, 0, z)] = wood
				v[Vector3i(0, -1, z)] = wood
			for z in range(3, 6):
				v[Vector3i(0, -1, z)] = wood.lightened(0.15)
		"SMG":
			for y in range(-4, -1):
				v[Vector3i(0, y, 3)] = dark
			v[Vector3i(0, -1, 5)] = dark
		"Rifle":
			for z in range(-4, 0):
				v[Vector3i(0, 0, z)] = wood
				v[Vector3i(0, -1, z)] = wood
			for z in range(2, 6):
				v[Vector3i(0, 2, z)] = dark
			v[Vector3i(0, 2, 6)] = Color("7fd6ff")
	# rarity stripe
	for z in range(1, mini(length - 1, 5)):
		var p := Vector3i(1, 0, z)
		if accent.v > 0.95 and accent.s < 0.1:
			v[p] = accent
		else:
			glow[p] = accent
			glow[Vector3i(-1, 0, z)] = accent
	return build_mesh(v, s, Vector3(0.5, 0.0, 0.5), glow)


static func loot_crate_mesh(epic: bool, s: float = 0.0625) -> ArrayMesh:
	var v := {}
	var glow := {}
	var wood := Color("8a5a33") if not epic else Color("4b3f5c")
	var band := Color("5c6068") if not epic else Color("8a7bb0")
	for x in 8:
		for y in 6:
			for z in 6:
				var edge := int(x == 0 or x == 7) + int(y == 0 or y == 5) + int(z == 0 or z == 5) >= 2
				var c := band if edge or x == 2 or x == 5 else jitter(wood, 0.08, hash3(Vector3i(x, y, z)))
				v[Vector3i(x, y, z)] = c
	v.erase(Vector3i(3, 3, 5))
	v.erase(Vector3i(4, 3, 5))
	glow[Vector3i(3, 3, 6)] = Color("ffd166") if not epic else Color("c07bff")
	glow[Vector3i(4, 3, 6)] = Color("ffd166") if not epic else Color("c07bff")
	return build_mesh(v, s, Vector3(4, 0, 3), glow)


static func ore_chunk_mesh(s: float = 0.05) -> ArrayMesh:
	var v := {}
	var glow := {}
	for p in [Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(0, 0, 1), Vector3i(1, 0, 1), Vector3i(0, 1, 0), Vector3i(1, 1, 1), Vector3i(-1, 0, 1)]:
		v[p] = Color("4a3a30")
	for p in [Vector3i(0, 1, 1), Vector3i(1, 1, 0), Vector3i(0, 2, 1), Vector3i(1, 2, 0), Vector3i(1, 3, 0)]:
		glow[p] = Color("7ef6ff") if p.y % 2 == 0 else Color("b892ff")
	return build_mesh(v, s, Vector3(0.5, 0, 0.5), glow)


static func medkit_mesh(s: float = 0.05) -> ArrayMesh:
	var v := {}
	for x in 6:
		for y in 4:
			for z in 4:
				v[Vector3i(x, y, z)] = Color("e8e8e8")
	for p in [Vector3i(2, 3, 2), Vector3i(3, 3, 2), Vector3i(2, 3, 1), Vector3i(3, 3, 1), Vector3i(1, 3, 1), Vector3i(4, 3, 1), Vector3i(2, 3, 0), Vector3i(3, 3, 3)]:
		v[p + Vector3i(0, 1, 0)] = Color("d93a3a")
	v[Vector3i(2, 4, 0)] = Color("6b6b6b")
	v[Vector3i(3, 4, 0)] = Color("6b6b6b")
	return build_mesh(v, s, Vector3(3, 0, 2))


static func workbench_mesh(s: float = 0.0625) -> ArrayMesh:
	var v := {}
	var glow := {}
	var wood := Color("7a4e2c")
	for x in 14:
		for z in 7:
			v[Vector3i(x, 7, z)] = jitter(wood.lightened(0.1), 0.06, hash3(Vector3i(x, 7, z)))
			v[Vector3i(x, 8, z)] = jitter(wood, 0.06, hash3(Vector3i(x, 8, z)))
	for lx in [0, 13]:
		for lz in [0, 6]:
			for y in 7:
				v[Vector3i(lx, y, lz)] = wood.darkened(0.25)
	# anvil
	for x in range(3, 8):
		for z in range(2, 5):
			v[Vector3i(x, 9, z)] = Color("50545c")
	for x in range(2, 9):
		for z in range(2, 5):
			v[Vector3i(x, 10, z)] = Color("6a6f78")
	v[Vector3i(1, 10, 3)] = Color("6a6f78")
	# hammer and glowing parts tray
	for x in range(9, 13):
		v[Vector3i(x, 9, 1)] = Color("8a5a32")
	v[Vector3i(12, 10, 1)] = Color("9aa0a8")
	glow[Vector3i(10, 9, 4)] = Color("ffb347")
	glow[Vector3i(11, 9, 5)] = Color("ff8c2a")
	glow[Vector3i(11, 9, 4)] = Color("ffd166")
	return build_mesh(v, s, Vector3(7, 0, 3.5), glow)


static func medbay_mesh(s: float = 0.0625) -> ArrayMesh:
	var v := {}
	var glow := {}
	for x in 8:
		for z in 14:
			v[Vector3i(x, 3, z)] = Color("dcd7cc") if z > 2 else Color("f2efe8")
			if x == 0 or x == 7:
				v[Vector3i(x, 2, z)] = Color("6b6f78")
	for lx in [0, 7]:
		for lz in [0, 13]:
			for y in 3:
				v[Vector3i(lx, y, lz)] = Color("6b6f78")
	# a tall banner with a red cross
	for y in range(0, 18):
		v[Vector3i(-2, y, 0)] = Color("6b6f78")
	for x in range(-1, 5):
		for y in range(11, 18):
			v[Vector3i(x, y, 0)] = Color("f2efe8")
	for p in [Vector3i(1, 14, 0), Vector3i(2, 14, 0), Vector3i(1, 13, 0), Vector3i(2, 13, 0), Vector3i(1, 15, 0), Vector3i(2, 15, 0), Vector3i(0, 14, 0), Vector3i(3, 14, 0), Vector3i(1, 16, 0), Vector3i(1, 12, 0), Vector3i(2, 12, 0), Vector3i(2, 16, 0), Vector3i(0, 13, 0), Vector3i(3, 13, 0)]:
		v[p + Vector3i(0, 0, -1)] = Color("d93a3a")
	glow[Vector3i(5, 4, 1)] = Color("6dffa8")
	glow[Vector3i(5, 5, 1)] = Color("b8ffd6")
	return build_mesh(v, s, Vector3(4, 0, 7), glow)


static func torch_rack_mesh(s: float = 0.0625) -> ArrayMesh:
	var v := {}
	var glow := {}
	var wood := Color("6b4423")
	for x in 12:
		v[Vector3i(x, 0, 0)] = wood.darkened(0.2)
		v[Vector3i(x, 9, 0)] = wood
		v[Vector3i(x, 4, 0)] = wood.lightened(0.1)
	for y in 10:
		v[Vector3i(0, y, 0)] = wood
		v[Vector3i(11, y, 0)] = wood
	for i in 4:
		var x := 2 + i * 3
		for y in range(1, 8):
			v[Vector3i(x, y, 1)] = Color("7a5232")
		glow[Vector3i(x, 8, 1)] = Color("ffb347")
		glow[Vector3i(x, 9, 1)] = Color("ffe08a")
	return build_mesh(v, s, Vector3(6, 0, 0.5), glow)
