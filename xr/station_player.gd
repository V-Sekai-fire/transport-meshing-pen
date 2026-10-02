# The visitor in the station: rx's stick components as input, xr/station_walker.gd on the MuJoCo guest as
# the body. The station's frame is the original's, so the XR origin (or the flat camera) is the station's
# transform times the walker's. Missing station or guest: stays still, so the other gates are untouched.
extends Node3D

const Stage = preload("res://stages/station_physics_stage.gd")
const Walker = preload("res://xr/station_walker.gd")
const SNAP := PI / 6.0
const SNAP_COOLDOWN := 0.25
const TELEPORT_RANGE := 12.0

@export var station_path: NodePath
@export var origin_path: NodePath
@export var camera_path: NodePath
@export var flat_camera_path: NodePath
@export var aim_hand_path: NodePath

var stage
var walker
var _station: Node3D
var _snap_wait := 0.0
var _aiming := false
var _target = null
var _ring := CSGTorus3D.new()


func _ready() -> void:
	_station = get_node_or_null(station_path)
	_ring.inner_radius = 0.35
	_ring.outer_radius = 0.45
	_ring.visible = false
	add_child(_ring)
	if _station == null:
		set_process(false)
		return
	_station.built.connect(_start)


func _start(_stats: Dictionary) -> void:
	stage = Stage.new()
	add_child(stage)
	if stage.load_station(_station.ctx.physics, _station.ctx.L, 0.3, 1.7) < 0:
		push_warning("station_player: the guest did not take the station; staying still")
		set_process(false)
		return
	walker = Walker.new(stage, _station.ctx.L.WORLD.play)
	var h: Dictionary = _station.ctx.L.HERO
	walker.set_pose(h.x, h.z, h.yaw, h.pitch)


func xr_active() -> bool:
	var oxr := XRServer.find_interface("OpenXR")
	return oxr != null and oxr.is_initialized()


## One frame of input, settable by a gate: move (x right, y forward), turn edge (-1, 0, 1), aim, release.
func step(dt: float, move: Vector2, turn: int, aim: bool) -> void:
	if walker == null:
		return
	_snap_wait = maxf(0.0, _snap_wait - dt)
	if turn != 0 and _snap_wait == 0.0:
		walker.snap_turn(SNAP * turn)
		_snap_wait = SNAP_COOLDOWN
	var head := 0.0
	var cam: Node3D = get_node_or_null(camera_path)
	if cam and xr_active():
		head = cam.transform.basis.get_euler(EULER_ORDER_YXZ).y
	walker.yaw += head
	walker.update(dt, move)
	walker.yaw -= head
	_aim(aim)
	_place()


func _aim(aim: bool) -> void:
	var hand: Node3D = get_node_or_null(aim_hand_path)
	if aim and hand:
		var to_station: Transform3D = _station.global_transform.affine_inverse() * hand.global_transform
		_target = stage.ray_walkable(to_station.origin, -to_station.basis.z.normalized() + Vector3.DOWN * 0.3,
				TELEPORT_RANGE)
		_aiming = true
	elif _aiming:
		_aiming = false
		if _target != null:
			walker.teleport(_target)
		_target = null
	_ring.visible = _aiming and _target != null
	if _ring.visible:
		_ring.global_transform = _station.global_transform * Transform3D(Basis(), _target + Vector3.UP * 0.02)


func _place() -> void:
	if xr_active():
		var origin: Node3D = get_node_or_null(origin_path)
		if origin:
			origin.global_transform = _station.global_transform * walker.origin()
	else:
		var flat: Node3D = get_node_or_null(flat_camera_path)
		if flat:
			flat.global_transform = _station.global_transform * walker.camera_pose()


func _process(dt: float) -> void:
	var move := Input.get_vector("move_left", "move_right", "move_backwards", "move_forwards")
	var turn := int(Input.is_action_just_pressed("rotate_camera_right")) - int(Input.is_action_just_pressed("rotate_camera_left"))
	var aim := false
	var hand = get_node_or_null(aim_hand_path)
	if hand and xr_active():
		aim = hand.get_vector2("primary").y > 0.6
	step(dt, move, turn, aim)
