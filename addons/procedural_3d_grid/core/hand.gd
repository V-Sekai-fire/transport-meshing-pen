# Copyright (c) 2023-present. This file is part of V-Sekai https://v-sekai.org/.
# K. S. Ernest (Fire) Lee & Contributors (see .all-contributorsrc).
# hand.gd  
# SPDX-License-Identifier: MIT

extends XRController3D

@onready var sketch_tool: Node3D = $SketchTool

var prev_hand_transform: Transform3D
var prev_hand_pressed: float


func _process(_delta: float) -> void:
	# get_float/is_button_pressed null-deref the double build when the controller has
	# no action map, and only OpenXR supplies one here; skip inputs unless it is up.
	var oxr := XRServer.find_interface("OpenXR")
	if oxr == null or not oxr.is_initialized():
		return
	var hand_pressed: float = get_float("trigger")
	var max_size: float = 0.01

	if hand_pressed <= 0.05:
		sketch_tool.active = false
	else:
		sketch_tool.active = true
		sketch_tool.pressure = hand_pressed * max_size

