# SimpleSketch's API as one Line3D per stroke, so a point rebuilds only its own stroke.
class_name Line3DSketch extends RefCounted

const L3D := preload("res://addons/lines_and_trails_3d/line_3d.gd")

var parent: Node3D
var _line = null
var _dirty := false

func _init(p: Node3D) -> void:
	parent = p

func stroke_begin() -> void:
	_flush()
	_line = null

func stroke_add(point: Vector3, size: float = 0.01, color: Color = Color(0, 0, 0)) -> void:
	if parent == null:
		return
	if _line == null:
		_line = L3D.new()
		_line.billboard_mode = L3D.BillboardMode.VIEW
		_line.material_type = L3D.MaterialType.SOLID_UNLIT
		_line.width = size * 2.0
		_line.color = color
		parent.add_child(_line)
	_line.points.append(point)
	if not _dirty:
		_dirty = true
		_flush.call_deferred()

func stroke_end() -> void:
	_flush()
	_line = null

func _flush() -> void:
	if _dirty and _line != null and is_instance_valid(_line) and _line.points.size() >= 2:
		_line.rebuild()
	_dirty = false
