# Ported from entities-multiplayer-fabric-rx addons/sar_game_framework/3d/xr/ (MIT); the stick is "primary"
# here, the pen's action map name for the thumbstick on each hand.
extends Node

const DEADZONE: float = 0.2
var previous_rotate: Vector2 = Vector2()

func _process(_delta: float) -> void:
	var rotate: Vector2 = Vector2()
	
	var controller: XRController3D = get_parent()
	# get_vector2 null-derefs the double build without OpenXR's action map, as hand.gd notes.
	var oxr := XRServer.find_interface("OpenXR")
	if controller and oxr != null and oxr.is_initialized():
		if controller.get_is_active():
			rotate = controller.get_vector2("primary")
	
	if rotate.x > DEADZONE:
		var right_event = InputEventAction.new()
		right_event.action = "rotate_camera_right"
		right_event.strength = abs(rotate.x)
		right_event.pressed = true
		Input.parse_input_event(right_event)
	else:
		if previous_rotate.x > DEADZONE:
			var right_event = InputEventAction.new()
			right_event.action = "rotate_camera_right"
			right_event.pressed = false
			Input.parse_input_event(right_event)
			
	if rotate.x < -DEADZONE:
		var left_event = InputEventAction.new()
		left_event.action = "rotate_camera_left"
		left_event.strength = abs(rotate.x)
		left_event.pressed = true
		Input.parse_input_event(left_event)
	else:
		if previous_rotate.x < -DEADZONE:
			var left_event = InputEventAction.new()
			left_event.action = "rotate_camera_left"
			left_event.pressed = false
			Input.parse_input_event(left_event)
		
	previous_rotate = rotate
