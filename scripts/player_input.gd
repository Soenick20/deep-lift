# Reads one player's device: "kbm" (keyboard + mouse), "kb2" (second keyboard player) or a joypad id.
extends RefCounted

var device: String = "kbm"
var joy_id: int = -1

var move := Vector2.ZERO
var aim_stick := Vector2.ZERO   # controller right stick
var shoot := false
var dig := false
var interact := false
var interact_pressed := false
var torch_pressed := false
var swap := false
var swap_pressed := false
var _prev_swap := false

var _prev_interact := false
var _prev_torch := false

# Set by the game for "kbm": the mouse position projected onto the floor.
var mouse_world := Vector3.ZERO
var mouse_active := false

# Debug/autotest can drive a player by writing these and setting scripted = true.
var scripted := false


static func make(dev: String, joy: int = -1):
	var s = load("res://scripts/player_input.gd").new()
	s.device = dev
	s.joy_id = joy
	return s


func _k(key: Key) -> bool:
	return Input.is_physical_key_pressed(key)


func poll() -> void:
	if scripted:
		interact_pressed = interact and not _prev_interact
		_prev_interact = interact
		torch_pressed = false
		swap_pressed = swap and not _prev_swap
		_prev_swap = swap
		return
	var i := false
	var t := false
	var sw := false
	match device:
		"kbm":
			move = Vector2(float(_k(KEY_D)) - float(_k(KEY_A)), float(_k(KEY_S)) - float(_k(KEY_W)))
			shoot = Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or _k(KEY_SPACE)
			dig = Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) or _k(KEY_F)
			i = _k(KEY_E)
			t = _k(KEY_Q)
			sw = _k(KEY_R)
		"kb2":
			move = Vector2(float(_k(KEY_RIGHT)) - float(_k(KEY_LEFT)), float(_k(KEY_DOWN)) - float(_k(KEY_UP)))
			shoot = _k(KEY_PERIOD)
			dig = _k(KEY_COMMA)
			i = _k(KEY_SLASH)
			t = _k(KEY_M)
			sw = _k(KEY_N)
		_:
			var lx := Input.get_joy_axis(joy_id, JOY_AXIS_LEFT_X)
			var ly := Input.get_joy_axis(joy_id, JOY_AXIS_LEFT_Y)
			move = Vector2(lx, ly)
			if move.length() < 0.2:
				move = Vector2.ZERO
			aim_stick = Vector2(Input.get_joy_axis(joy_id, JOY_AXIS_RIGHT_X), Input.get_joy_axis(joy_id, JOY_AXIS_RIGHT_Y))
			if aim_stick.length() < 0.35:
				aim_stick = Vector2.ZERO
			shoot = Input.get_joy_axis(joy_id, JOY_AXIS_TRIGGER_RIGHT) > 0.4 or Input.is_joy_button_pressed(joy_id, JOY_BUTTON_RIGHT_SHOULDER)
			dig = Input.get_joy_axis(joy_id, JOY_AXIS_TRIGGER_LEFT) > 0.4 or Input.is_joy_button_pressed(joy_id, JOY_BUTTON_X)
			i = Input.is_joy_button_pressed(joy_id, JOY_BUTTON_A)
			t = Input.is_joy_button_pressed(joy_id, JOY_BUTTON_Y) or Input.is_joy_button_pressed(joy_id, JOY_BUTTON_LEFT_SHOULDER)
			sw = Input.is_joy_button_pressed(joy_id, JOY_BUTTON_B)
	if move.length() > 1.0:
		move = move.normalized()
	interact = i
	interact_pressed = i and not _prev_interact
	_prev_interact = i
	torch_pressed = t and not _prev_torch
	_prev_torch = t
	swap_pressed = sw and not _prev_swap
	_prev_swap = sw


static func kb2_join_pressed() -> bool:
	for k in [KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT, KEY_PERIOD, KEY_SLASH]:
		if Input.is_physical_key_pressed(k):
			return true
	return false


static func joy_join_pressed(id: int) -> bool:
	return Input.is_joy_button_pressed(id, JOY_BUTTON_A) or Input.is_joy_button_pressed(id, JOY_BUTTON_START)
