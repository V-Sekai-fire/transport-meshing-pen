# The permanent-slot gate: rd_compute releases the permanent Variant slot of every RID it frees, so a
# long-running guest (motion.elf live) never runs out. PASS when 80 calls of 1000 uniform sets made and
# freed all succeed and hold no more slots after than before. The control keeps its sets: slots climb.
#   godot --path . --xr-mode off --script tools/gate_rid_slots.gd -- [--control=kept]
extends SceneTree


func _initialize() -> void:
	var kept := "--control=kept" in OS.get_cmdline_user_args()
	var sb = ClassDB.instantiate("Sandbox")
	root.add_child(sb)
	sb.memory_max = 512
	sb.program = load("res://probes.elf")
	sb.references_max = 65536
	sb.execution_timeout = 0
	print(sb.vmcall("refs_setup"))
	var before := str(sb.vmcall("refs_usets", 0)).get_slice("permanent=", 1)
	var before := str(sb.vmcall("refs_usets", 0)).get_slice("permanent=", 1)
	var fn := "refs_usets_kept" if kept else "refs_usets"
	var calls := 0
	var last := ""
	for k in 80:
		last = str(sb.vmcall(fn, 1000))
		if not last.begins_with("uniform_sets made=1000 of 1000"):
			break
		calls += 1
	var after := last.get_slice("permanent=", 1)
	var ok := calls == 80 and after == before
	print("%s %s: %d of 80 calls made 1000 sets; permanent slots %s before, %s after" % ["PASS" if ok else "FAIL", fn,
			calls, before, after])
	quit(0 if ok else 1)
