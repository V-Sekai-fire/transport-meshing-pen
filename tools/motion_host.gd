# MotionBricks live for xr-pilot's simulated body: motion.elf on ggml-rd, steered over loopback UDP.
#   godot --path . --minimized --script tools/motion_host.gd -- [--port=47830] [--models=DIR] [--bench=SECONDS]
# xr-pilot sends "steer mx mz fx fz speed" and "skeleton"; each frame goes back to the last sender as
# "MBF1", uint32 joints, then joints x 3 float32 world positions, at 30 frames a second.
extends SceneTree

const InferHost = preload("res://infer_host.gd")
const FPS := 30.0

var _sb = null
var _rd: RenderingDevice = null
var _host = null
var _udp := PacketPeerUDP.new()
var _peer_ip := ""
var _peer_port := 0
var _queue: Array = []
var _joints := 0
var _clock := 0.0
var _bench := 0.0
var _bench_t0 := 0
var _bench_frames := 0
var _sent := 0
var _last_report := -1


func _initialize() -> void:
	var port := 47830
	var models := ProjectSettings.globalize_path("res://").path_join("../../5-repository")
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--port="):
			port = int(a.substr(7))
		elif a.begins_with("--models="):
			models = a.substr(9)
		elif a.begins_with("--bench="):
			_bench = float(a.substr(8))
	_sb = ClassDB.instantiate("Sandbox")
	if _sb == null:
		_quit("FAIL: no Sandbox class")
		return
	root.add_child(_sb)
	_sb.memory_max = 2048
	_sb.program = load("res://motion.elf")
	_sb.references_max = 65536
	_sb.execution_timeout = 1000000
	_rd = RenderingServer.create_local_rendering_device()
	if _rd == null:
		_quit("FAIL: no local RenderingDevice (run with a window, not --headless)")
		return
	print(_sb.vmcall("motion_open", _rd, 2048, models.simplify_path()))
	print(_sb.vmcall("motion_live_start", 0))
	_host = InferHost.new(_sb, _rd, "motion_pump")
	_host.reset(false)
	if _bench > 0.0:
		_sb.vmcall("motion_live_steer", 0.0, 1.0, 0.0, 1.0, 1.2)
		_bench_t0 = Time.get_ticks_msec()
	elif _udp.bind(port, "127.0.0.1") != OK:
		_quit("FAIL: cannot bind 127.0.0.1:%d" % port)
		return
	print("motion host: listening on 127.0.0.1:%d" % port)


func _quit(why: String) -> void:
	print(why)
	quit(0 if why.begins_with("PASS") or why.begins_with("BENCH") else 1)


func _process(delta: float) -> bool:
	if _host == null:
		return false
	if _host.state == "running":
		_host.pump_frame()
	elif _host.state == "error":
		_quit("FAIL: %s" % _host.text)
		return true
	_receive()
	# Live, frames are taken only while few wait to be sent, so a steer reaches the body in a few frames.
	var f := PackedFloat32Array()
	if _bench > 0.0 or _queue.size() < 4:
		f = _sb.vmcall("motion_live_frames")
	if f.size() >= 2 and int(f[1]) > 0:
		_joints = int(f[0])
		for i in int(f[1]):
			_queue.append(f.slice(2 + i * _joints * 3, 2 + (i + 1) * _joints * 3))
			_bench_frames += 1
	if _bench > 0.0:
		var s := (Time.get_ticks_msec() - _bench_t0) / 1000.0
		if int(s) % 10 == 0 and int(s) != _last_report:
			_last_report = int(s)
			print("t=%d %s" % [int(s), _sb.vmcall("motion_live_status")])
		if s >= _bench:
			_quit("BENCH %d frames planned in %.1f s: %.2f x real time (%s; %s)" % [_bench_frames, s,
					_bench_frames / FPS / s, _sb.vmcall("motion_live_status"), _host.summary()])
			return true
		return false
	_clock += delta
	while _clock >= 1.0 / FPS and not _queue.is_empty():
		_clock -= 1.0 / FPS
		_send(_queue.pop_front())
	if _queue.is_empty():
		_clock = min(_clock, 1.0 / FPS)
	return false


func _receive() -> void:
	while _udp.get_available_packet_count() > 0:
		var words := _udp.get_packet().get_string_from_utf8().strip_edges().split(" ")
		_peer_ip = _udp.get_packet_ip()
		_peer_port = _udp.get_packet_port()
		if words[0] == "steer" and words.size() == 6:
			_sb.vmcall("motion_live_steer", float(words[1]), float(words[2]), float(words[3]), float(words[4]),
					float(words[5]))
		elif words[0] == "skeleton":
			_udp.set_dest_address(_peer_ip, _peer_port)
			_udp.put_packet(("MBS1\n" + str(_sb.vmcall("motion_live_skeleton"))).to_utf8_buffer())
		elif words[0] == "status":
			_udp.set_dest_address(_peer_ip, _peer_port)
			_udp.put_packet(("MBT1 %s sent=%d" % [_sb.vmcall("motion_live_status"), _sent]).to_utf8_buffer())


func _send(frame: PackedFloat32Array) -> void:
	if _peer_port == 0:
		return
	var b := PackedByteArray()
	b.append_array("MBF1".to_ascii_buffer())
	b.resize(8)
	b.encode_u32(4, _joints)
	b.append_array(frame.to_byte_array())
	_udp.set_dest_address(_peer_ip, _peer_port)
	_udp.put_packet(b)
	_sent += 1
