# Draws the depth's branching map: layers left to right, the route taken, where you are and the choices.
extends Control

const RunMap = preload("res://scripts/run_map.gd")

var run_map
var choices: Array = []     # options shown with numbers while voting
var title := ""


func _draw() -> void:
	if run_map == null or run_map.layers.is_empty():
		return
	var font := ThemeDB.fallback_font
	var w := size.x
	var h := size.y
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.03, 0.04, 0.06, 0.72))
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.5, 0.9, 1.0, 0.25), false, 1.5)
	draw_string(font, Vector2(10, 18), title, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("cfe9f2"))
	var layers: Array = run_map.layers
	var nl := layers.size()
	var top := 30.0
	var pos := func(li: int, k: int) -> Vector2:
		var n: int = layers[li].size()
		var x := 22.0 + (w - 44.0) * li / maxf(nl - 1, 1)
		var y := top + (h - top - 14.0) * (k + 1) / (n + 1)
		return Vector2(x, y)
	# edges
	for li in nl - 1:
		for k in layers[li].size():
			var nd: Dictionary = layers[li][k]
			for e in nd.edges:
				var taken: bool = nd.visited and layers[li + 1][e].visited
				var col := Color(0.6, 0.9, 1.0, 0.85) if taken else Color(1, 1, 1, 0.16)
				draw_line(pos.call(li, k), pos.call(li + 1, e), col, 2.5 if taken else 1.5)
	# nodes
	var t := Time.get_ticks_msec() / 1000.0
	for li in nl:
		for k in layers[li].size():
			var nd: Dictionary = layers[li][k]
			var info: Dictionary = RunMap.INFO[nd.type]
			var p: Vector2 = pos.call(li, k)
			var col: Color = info.color
			var r := 9.5 if nd.type != "boss" else 12.0
			var is_cur: bool = li == run_map.cur_layer and k == run_map.cur_index
			var choice_i := -1
			for ci in choices.size():
				if choices[ci][0] == li and choices[ci][1] == k:
					choice_i = ci
			var a := 1.0 if (nd.visited or choice_i >= 0 or is_cur) else 0.45
			if choice_i >= 0:
				r += 2.0 + sin(t * 6.0) * 1.5
			draw_circle(p, r, Color(col.r, col.g, col.b, 0.9 * a))
			draw_circle(p, r - 2.5, Color(0.05, 0.06, 0.08, 0.95))
			draw_string(font, p + Vector2(-4.5, 5), info.short, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(col.r, col.g, col.b, a))
			if is_cur:
				draw_arc(p, r + 4.0, 0, TAU, 24, Color.WHITE, 2.0)
			if choice_i >= 0:
				draw_string(font, p + Vector2(-4, -r - 4), str(choice_i + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)
