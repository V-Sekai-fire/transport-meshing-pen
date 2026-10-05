# Native translation gate (RFD 2293): every shipped ELF, opened the way its
# stage opens it, runs from its res://bintr/bintr-<HASH> library.
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
	var failed := PackedStringArray()
	for name in opened:
		var n = opened[name]
		var sb = n.sandbox if "sandbox" in n else (n.get_child(0) if n.get_child_count() > 0 else null)
		if sb == null:
			print("%s: FAIL not loaded" % name)
			failed.append(name)
			continue
		var hash := "%08X" % (int(sb.get_translation_hash()) & 0xFFFFFFFF)
		var tr: bool = sb.is_binary_translated()
		print("%s: hash %s %s" % [name, hash, "translated" if tr else "INTERPRETED"])
		if not tr:
			failed.append(name)
	for name in opened:
		opened[name].free()
	print("RESULT: ", "PASS" if failed.is_empty() else "FAIL " + ", ".join(failed))
	quit(0 if failed.is_empty() else 1)
