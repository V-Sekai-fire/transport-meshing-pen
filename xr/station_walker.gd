# The original's first-person walker (src/core/player.js at 4112f57) ported line for line, with its
# collisions answered by the MuJoCo guest (stages/station_physics_stage.gd) instead of physics.js.
# Input is a frame's intent: move (x right, y forward, -1..1), turn and pitch in radians, jump, fly
# and up. A move longer than 0.95 runs, as the original's touch stick does. In VR the headset owns
# the eye height, the pitch and the head bob, so camera_pose reports the feet and yaw.
extends RefCounted

const STEP_HEIGHT := 0.45
const DEG := PI / 180.0

var physics
var bounds: Dictionary
var pos := Vector3.ZERO
var vel := Vector3.ZERO
var vy := 0.0
var yaw := 0.0
var pitch := 0.0
var eye := 1.52
var radius := 0.3
var height := 1.7
var walk := 3.1
var run := 6.4
var fly := false
var enabled := true
var on_ground := true
var bob := 0.0
var smooth_y = null
var distance := 0.0


func _init(station_physics, play_bounds: Dictionary) -> void:
	physics = station_physics
	bounds = play_bounds


## x, z world; yaw and pitch in degrees (yaw 0 is north). y, when given, is the eye and flies.
func set_pose(x: float, z: float, yaw_deg := 0.0, pitch_deg := 0.0, y = null) -> void:
	pos = Vector3(x, 0.0, z)
	pos.y = y - eye if y != null else physics.ground_height(x, z, 1e9)
	if y != null:
		fly = true
	yaw = yaw_deg * DEG
	pitch = pitch_deg * DEG
	vy = 0.0
	smooth_y = null
	apply_camera(0.0)


func jump() -> void:
	if enabled and (on_ground or fly):
		if not fly:
			vy = 4.2


func update(dt: float, move := Vector2.ZERO, turn := 0.0, look_pitch := 0.0, up := 0.0) -> void:
	dt = minf(dt, 0.05)
	yaw -= turn
	pitch = clampf(pitch - look_pitch, -85.0 * DEG, 85.0 * DEG)
	var f := 0.0
	var s := 0.0
	var u := 0.0
	if enabled:
		f = move.y
		s = move.x
		u = up
	var running: bool = move.length() > 0.95
	var speed: float = (run if running else walk) * (2.6 if fly else 1.0)
	var fx: float = -sin(yaw)
	var fz: float = -cos(yaw)
	var rx: float = cos(yaw)
	var rz: float = -sin(yaw)
	var mx: float = fx * f + rx * s
	var mz: float = fz * f + rz * s
	var ml: float = Vector2(mx, mz).length()
	if ml > 1.0:
		mx /= ml
		mz /= ml
	var target := Vector3(mx * speed, 0.0, mz * speed)
	var acc: float = 10.0 if on_ground or fly else 2.5
	vel.x += (target.x - vel.x) * minf(1.0, acc * dt)
	vel.z += (target.z - vel.z) * minf(1.0, acc * dt)

	if fly:
		pos.x += vel.x * dt
		pos.z += vel.z * dt
		pos.y += u * speed * dt
		on_ground = false
	else:
		var dist: float = Vector2(vel.x, vel.z).length() * dt
		var n: int = maxi(1, ceili(dist / 0.12))
		var p := Vector2(pos.x, pos.z)
		for i in n:
			var o := p
			p += Vector2(vel.x, vel.z) * dt / n
			p = physics.resolve(p, pos.y)
			var g: float = physics.ground_height(p.x, p.y, pos.y)
			if g - pos.y > STEP_HEIGHT:
				p = o
		p.x = clampf(p.x, bounds.x0, bounds.x1)
		p.y = clampf(p.y, bounds.z0, bounds.z1)
		distance += Vector2(p.x - pos.x, p.y - pos.z).length()
		pos.x = p.x
		pos.z = p.y
		var g: float = physics.ground_height(pos.x, pos.z, pos.y)
		vy -= 12.0 * dt
		pos.y += vy * dt
		if pos.y <= g:
			pos.y = g
			vy = 0.0
			on_ground = true
		elif pos.y - g < 0.06 and vy <= 0.0:
			pos.y = g
			vy = 0.0
			on_ground = true
		else:
			on_ground = false
	apply_camera(dt)


func apply_camera(dt: float) -> void:
	var sp: float = Vector2(vel.x, vel.z).length()
	if on_ground and sp > 0.3:
		bob += dt * sp * 2.1
	else:
		bob *= 0.9
	var eye_y: float = pos.y + eye
	if smooth_y == null or fly:
		smooth_y = eye_y
	else:
		smooth_y += (eye_y - smooth_y) * minf(1.0, dt * 14.0)
	if absf(smooth_y - eye_y) > 1.2:
		smooth_y = eye_y


## The feet under the smoothed eye, and the yaw: what the XR origin follows.
func origin() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw), Vector3(pos.x, smooth_y - eye, pos.z))


## The original's desktop camera, with its head bob, for a flat-screen view.
func camera_pose() -> Transform3D:
	var sp: float = Vector2(vel.x, vel.z).length()
	var bob_y: float = 0.0 if fly else sin(bob * 2.0) * 0.022 * minf(1.0, sp / 3.0)
	var roll: float = sin(bob) * 0.0025 * minf(1.0, sp / 3.0)
	var b := Basis.from_euler(Vector3(pitch, yaw, roll), EULER_ORDER_YXZ)
	return Transform3D(b, Vector3(pos.x, smooth_y + bob_y, pos.z))


## Snap turn and teleport, the two VR additions the original has no keys for.
func snap_turn(radians: float) -> void:
	yaw -= radians


## Lands on walkable ground at target if the body fits there; returns whether it moved.
func teleport(target: Vector3) -> bool:
	var g: float = physics.ground_height(target.x, target.z, target.y)
	var p: Vector2 = physics.resolve(Vector2(target.x, target.z), g)
	if p.distance_to(Vector2(target.x, target.z)) > 1e-3 or absf(g - target.y) > STEP_HEIGHT:
		return false
	if not physics.floor_under(target.x, target.z, g):
		return false
	pos = Vector3(target.x, g, target.z)
	vel = Vector3.ZERO
	vy = 0.0
	smooth_y = null
	apply_camera(0.0)
	return true
