# The walker's first headless run: the four modules' colliders into mujoco.elf, a spawn at the
# original's hero point, and three seconds walking forward at a fixed step.
#   godot --headless --path . --script tools/probe_walker.gd
extends SceneTree

const Ctx = preload("res://addons/sakuragaoka_station/core/ctx.gd")
const Stage = preload("res://stages/station_physics_stage.gd")
const Walker = preload("res://xr/station_walker.gd")
const MODULES := ["environment", "station", "plaza", "sakura"]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var ctx = Ctx.new(1)
	for n in MODULES:
		load("res://addons/sakuragaoka_station/world/%s.gd" % n).new().build(ctx)
	var stage = Stage.new()
	root.add_child(stage)
	var t0 := Time.get_ticks_msec()
	var geoms: int = stage.load_station(ctx.physics, ctx.L, 0.3, 1.7)
	print("load: %d geoms in %d ms" % [geoms, Time.get_ticks_msec() - t0])
	if geoms < 0:
		print("RESULT: FAIL (the guest did not load the station)")
		quit(1)
		return
	var w = Walker.new(stage, ctx.L.WORLD.play)
	var h = ctx.L.HERO
	w.set_pose(h.x, h.z, h.yaw, h.pitch)
	var g: float = w.pos.y
	var terrain: float = ctx.L.height_at(h.x, h.z)
	print("spawn: feet %.4f, height_at %.4f, ground %.4f" % [w.pos.y, terrain, g])
	var start: Vector3 = w.pos
	stage.take_vm_us()
	var t1 := Time.get_ticks_msec()
	for i in 180:
		w.update(1.0 / 60.0, Vector2(0, 0.9))
	var vm: int = stage.take_vm_us()
	var walked: float = Vector2(w.pos.x - start.x, w.pos.z - start.z).length()
	print("walk: %.3f m in 3 s, feet %.4f, %d ms host, guest %.2f ms/frame" % [walked, w.pos.y,
			Time.get_ticks_msec() - t1, vm / 1000.0 / 180.0])
	var ok: bool = walked > 8.0 and walked < 10.0
	print("RESULT: %s" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
