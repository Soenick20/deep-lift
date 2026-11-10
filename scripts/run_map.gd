# The branching map for one depth: a start floor, a few layers of choices, then the depth boss.
extends RefCounted

const INFO := {
	"mine": {"name": "MINE", "short": "M", "color": Color("7ef6ff"), "desc": "Hunt the shard, loot as you go"},
	"vault": {"name": "VAULT", "short": "V", "color": Color("ffd166"), "desc": "Locked caches, more guards"},
	"miniboss": {"name": "MINI-BOSS", "short": "B", "color": Color("ff6a5c"), "desc": "A Brute guards the shard. Big reward"},
	"boss": {"name": "DEPTH BOSS", "short": "!", "color": Color("e05cff"), "desc": "The end of this depth"}}

const CHOICE_LAYERS := 5

# layers[i] = Array of nodes {type, edges: Array[int] into layers[i + 1], visited}
# layer 0 is the start floor (one node), the last layer is the boss (one node)
var layers: Array = []
var cur_layer := 0
var cur_index := 0


func generate(rng: RandomNumberGenerator) -> void:
	layers.clear()
	layers.append([{"type": "mine", "edges": [], "visited": true}])
	for i in CHOICE_LAYERS:
		var layer: Array = []
		var n := rng.randi_range(2, 3)
		for k in n:
			var r := rng.randf()
			var t := "mine"
			if r < 0.25:
				t = "vault"
			elif r < 0.42 and i > 0:
				t = "miniboss"
			layer.append({"type": t, "edges": [], "visited": false})
		layers.append(layer)
	layers.append([{"type": "boss", "edges": [], "visited": false}])
	# make sure every depth offers at least one vault and one mini-boss somewhere
	_ensure(rng, "vault", 1)
	_ensure(rng, "miniboss", 2)
	# connect each layer to the next without crossings: node j reaches the nodes "below" it
	for li in layers.size() - 1:
		var a: Array = layers[li]
		var b: Array = layers[li + 1]
		for j in a.size():
			var lo := int(floor(float(j) * b.size() / a.size()))
			var hi := int(ceil(float(j + 1) * b.size() / a.size())) - 1
			for k in range(lo, maxi(hi, lo) + 1):
				if not (k in a[j].edges):
					a[j].edges.append(k)
			# give single-path nodes a second way forward where possible, so there is a choice
			if a[j].edges.size() == 1 and lo + 1 < b.size():
				a[j].edges.append(lo + 1)
	cur_layer = 0
	cur_index = 0


func _ensure(rng: RandomNumberGenerator, t: String, from_layer: int) -> void:
	for li in range(1, layers.size() - 1):
		for nd in layers[li]:
			if nd.type == t:
				return
	var li := rng.randi_range(from_layer, layers.size() - 2)
	var layer: Array = layers[li]
	layer[rng.randi() % layer.size()].type = t


func current() -> Dictionary:
	return layers[cur_layer][cur_index]


func current_type() -> String:
	return current().type


func at_boss() -> bool:
	return cur_layer == layers.size() - 1


func floor_number() -> int:
	return cur_layer + 1


func floor_count() -> int:
	return layers.size()


# The nodes you can jump to next: Array of [layer, index].
func options() -> Array:
	var out: Array = []
	if at_boss():
		return out
	for k in current().edges:
		out.append([cur_layer + 1, k])
	return out


func type_of(opt: Array) -> String:
	return layers[opt[0]][opt[1]].type


func advance(opt: Array) -> void:
	cur_layer = opt[0]
	cur_index = opt[1]
	current().visited = true
