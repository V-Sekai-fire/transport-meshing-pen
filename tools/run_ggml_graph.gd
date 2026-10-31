extends SceneTree

const GgmlStage := preload("res://stages/ggml_stage.gd")

var _stage: Node
var _name := "kimodo_denoiser"
var _probe := "graph"
var _env := ""
var _state := "start"
var _t0 := 0
var _frames := 0

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--graph="):
			_name = a.substr(8)
		elif a.begins_with("--probe="):
			_probe = a.substr(8)
		elif a.begins_with("--env="):
			_env = a.substr(6)
	_t0 = Time.get_ticks_msec()
	_stage = GgmlStage.new()
	root.add_child(_stage)

func _process(_delta: float) -> bool:
	_frames += 1
	if _state == "start":
		print("attach: ", _stage.ggml_attach())
		print("start: ", _stage.ggml_probe_start(_probe, _name, _env))
		_state = "run"
		return false
	var s: String = _stage.ggml_pump()
	if s.begins_with("RUNNING"):
		if Time.get_ticks_msec() - _t0 > 280000:
			print("RESULT: FAIL (wallclock) ", s)
			quit(1)
		return false
	print("status: ", s)
	print("output: ", _stage.ggml_output())
	print("rd stats: ", _stage.ggml_rd_stats())
	print("device: ", _stage._ggml_rd.get_device_name() if _stage._ggml_rd != null else "none")
	print("elapsed_ms: ", Time.get_ticks_msec() - _t0, " frames: ", _frames)
	var out: String = _stage.ggml_output()
	var ok := s.begins_with("DONE") and out.contains("RESULT: PASS") and not out.contains("RESULT: FAIL")
	print("RESULT: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
	return false
