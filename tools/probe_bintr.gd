# Native translation gate (RFD 2293): every shipped ELF, opened the way its
# stage opens it, runs from its res://bintr/bintr-<HASH> library, and every
# .sgd's compiled program has its library (SafeGDScript binds no is_binary_translated).
#   godot --headless --path . --xr-mode off --script tools/probe_bintr.gd
# PASS when each one reports is_binary_translated(); an ELF whose hash has no
# library FAILs by name. With GODOT_SANDBOX_BINTR_EMIT=<dir> set, the addon
# writes each program's C99 there instead (tools/build.exs compiles it).
extends SceneTree

const SandboxUtil := preload("res://stages/sandbox_util.gd")

func _initialize() -> void:
	if OS.get_environment("GODOT_SANDBOX_BINTR_EMIT") != "":
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SandboxUtil.BINTR_DIR))
		ProjectSettings.set_setting("sandbox/binary_translation/cache_dir", SandboxUtil.BINTR_DIR + "/")
		ProjectSettings.set_setting("sandbox/binary_translation/enabled", true)
	else:
		print("bintr: lookup ", "on" if SandboxUtil.enable_native_translation() else "off (no library for this platform)")
	var opened := {}
	var curvenet = load("res://stages/curvenet_stage.gd").new()
	curvenet._ready()
	opened["curvenet.elf"] = curvenet
	var dress = load("res://stages/dress_on_stage.gd").new()
	dress._ready()
	opened["dress_on.elf"] = dress
	opened["mujoco.elf"] = load("res://stages/mujoco_stage.gd").new()
	var usd = load("res://stages/usd_stage.gd").new()
	usd.ensure()
	opened["usd.elf"] = usd
	# dress_on_stage.rw()'s Sandbox, made with its arguments.
	var holder := Node.new()
	SandboxUtil.make_sandbox(holder, "res://rd_worker.elf", 0, 4096, 4000000)
	opened["rd_worker.elf"] = holder
	# The station's build kernel, the Sandbox core/build/build_kernels.gd makes for the terrain.
	var kernels = load("res://addons/sakuragaoka_station/core/build/build_kernels.gd")
	var station := Node.new()
	if kernels.sandbox() != null:
		station.set_meta("sandbox", kernels.sandbox())
	opened["station_build.elf"] = station
	var failed := PackedStringArray()
	for name in opened:
		var n = opened[name]
		var sb = n.get_meta("sandbox") if n.has_meta("sandbox") else (n.sandbox if "sandbox" in n else (n.get_child(0) if n.get_child_count() > 0 else null))
		if sb == null:
			print("%s: FAIL not loaded" % name)
			failed.append(name)
			continue
		var hash := "%08X" % (int(sb.get_translation_hash()) & 0xFFFFFFFF)
		var tr: bool = sb.is_binary_translated()
		print("%s: hash %s %s" % [name, hash, "translated" if tr else "INTERPRETED"])
		if not tr:
			failed.append(name)
	for path in _sgd_files("res://"):
		var script = load(path)
		var inst = script.new() if script != null and script.can_instantiate() else null
		var h: int = int(script.get_translation_hash()) & 0xFFFFFFFF if script != null else 0
		var lib := "%s/bintr-%08X%s" % [SandboxUtil.BINTR_DIR, h, SandboxUtil.native_translation_suffix()]
		var ok := h != 0 and FileAccess.file_exists(lib)
		var emitting := OS.get_environment("GODOT_SANDBOX_BINTR_EMIT") != ""
		print("%s: hash %08X %s" % [path, h, "library present" if ok else ("emitted" if emitting and h != 0 else ("FAIL no program" if h == 0 else "FAIL no library"))])
		if not ok and not emitting:
			failed.append(path.get_file())
		if inst is Object and not inst is RefCounted:
			inst.free()
	for name in opened:
		opened[name].free()
	kernels.shutdown()
	print("RESULT: ", "PASS" if failed.is_empty() else "FAIL " + ", ".join(failed))
	quit(0 if failed.is_empty() else 1)


func _sgd_files(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	for d in DirAccess.get_directories_at(dir):
		if not d.begins_with("."):
			out.append_array(_sgd_files(dir.path_join(d)))
	for f in DirAccess.get_files_at(dir):
		if f.get_extension() == "sgd":
			out.append(dir.path_join(f))
	return out
