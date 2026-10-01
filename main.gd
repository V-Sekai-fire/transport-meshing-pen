# The host root of interactor-dress-on (node "Main", so MCP reaches it at
# /root/Main in main.tscn and in xr_main.tscn). A thin root (AGENTS.md rule
# 6): one stage node per ELF, each owning its Sandbox (stages/sandbox_util.gd
# makes them the way Gate 0F says), and the pipeline that composes them.
#
#   DressOn   stages/dress_on_stage.gd   dress_on.elf (Stage 1) + probes.elf (Gate 0F) + rd_worker.elf (6G.1)
#   Curvenet  stages/curvenet_stage.gd   curvenet.elf (Cut 4)
#   Infer     stages/infer_stage.gd      infer.elf (Cut 4b / 7); fixtures until then
#   Ggml      stages/ggml_stage.gd       ggml_test.elf (Cut 3: ggml-rd, Gate 3), made on first use
#   Usd       stages/usd_stage.gd        usd.elf (Cut U: a .usdz package -> mesh + material arrays)
#   Pipeline  stages/pipeline.gd         the loop's state machine
#
# Every guest entry point keeps a no-argument wrapper here (rule 8), each a
# one-line delegate to its stage, so MCP call_method needs no argument
# marshalling and the Gate 1 / 2 / 0F / 0E drives keep working.
extends Node

const DressOnStage := preload("res://stages/dress_on_stage.gd")
const CurvenetStage := preload("res://stages/curvenet_stage.gd")
const InferStage := preload("res://stages/infer_stage.gd")
const GgmlStage := preload("res://stages/ggml_stage.gd")
const UsdStage := preload("res://stages/usd_stage.gd")
const MujocoStage := preload("res://stages/mujoco_stage.gd")
const StrokesUsd := preload("res://util/strokes_usd.gd")
const Pipeline := preload("res://stages/pipeline.gd")

var dress_on = null
var curvenet = null
var infer = null
var ggml = null
var usd = null
var mujoco = null
var pipeline = null

func _ready() -> void:
	dress_on = _add(DressOnStage, "DressOn")
	curvenet = _add(CurvenetStage, "Curvenet")
	infer = _add(InferStage, "Infer")
	ggml = _add(GgmlStage, "Ggml")
	usd = _add(UsdStage, "Usd")
	mujoco = _add(MujocoStage, "Mujoco")
	pipeline = _add(Pipeline, "Pipeline")
	pipeline.setup({"infer": infer, "curvenet": curvenet, "usd": usd, "mujoco": mujoco})
	var world = get_node_or_null("World")
	if world != null and world.has_method("attach"):
		world.attach(self)

func _add(script: Script, n: String) -> Node:
	var s: Node = script.new()
	s.name = n
	add_child(s)
	return s

# --- the loop (Cut 8) ------------------------------------------------------------------
# dress_on_run starts the pipeline and returns at once; poll dress_on_status
# until it reads DONE or FAILED(reason), then dress_on_result for the record.
# allow_fixture: stages whose fixture may stand in (infer,rig by default: the
# FoxGirl body and skeleton, labelled FIXTURE).

func dress_on_run(allow_fixture: String = "infer,rig", pen: String = "scripted") -> String:
	return pipeline.start({"allow_fixture": allow_fixture, "pen": pen})

# Gate 8's control: the back seam is not drawn; must end FAILED(MESH: ...).
func dress_on_run_drop_seam(allow_fixture: String = "infer,rig") -> String:
	return pipeline.start({"allow_fixture": allow_fixture, "drop_seam": true})

# Save the strokes drawn in the last run (pen or scripted) as OpenUSD, one
# BasisCurves per stroke (util/strokes_usd.gd); "" picks user://creations/<utc>.usda.
func dress_on_save_strokes(path: String = "") -> String:
	var strokes: Array = pipeline.data.get("authored", [])
	if strokes.is_empty():
		return "FAIL: no strokes drawn yet (state %s)" % pipeline.state
	if path == "":
		path = "user://creations/%s.usda" % Time.get_datetime_string_from_system(true).replace(":", "")
	var r := StrokesUsd.to_usda(usd, strokes, {"source": "pen", "saved_at": Time.get_datetime_string_from_system(true)})
	if r.has("error"):
		return "FAIL: " + r.error
	var g := ProjectSettings.globalize_path(path)
	DirAccess.make_dir_recursive_absolute(g.get_base_dir())
	var f := FileAccess.open(g, FileAccess.WRITE)
	if f == null:
		return "FAIL: cannot write %s (%s)" % [path, error_string(FileAccess.get_open_error())]
	f.store_string(r.text)
	f.close()
	return "ok %d strokes -> %s" % [strokes.size(), path]

# Run the loop on saved strokes instead of the scripted skirt.
func dress_on_run_strokes(path: String = "res://../gates/S-strokes/inputs/skirt.usda") -> String:
	return pipeline.start({"allow_fixture": "infer,rig", "strokes_from": path})

func dress_on_run_opts(opts: Dictionary = {}) -> String:
	return pipeline.start(opts)

func dress_on_status() -> String:
	return pipeline.status()

func dress_on_result() -> String:
	return JSON.stringify(pipeline.summary(), "  ")

# pen = xr: end the authoring (the menu button or Enter do the same).
func dress_on_author_done() -> String:
	pipeline.pen_finish()
	return "pen finished in %s" % pipeline.state

# The XR pen's boundary mode (xr/pen_bridge.gd): strokes begun while it is on
# are the edges of openings (a skirt's waist and hem), whose cycles get no
# patch. The thumbstick click toggles it in the headset.
func dress_on_pen_boundary(on: bool = true) -> String:
	var bridge = get_node_or_null("World/PenBridge")
	if bridge == null:
		return "FAIL: no World/PenBridge (xr_main.tscn only)"
	bridge.boundary_mode = on
	return "pen boundary mode %s" % ("on" if on else "off")

# Which stages have their ELF (and its API), and why not.
func dress_on_stages() -> String:
	var out := PackedStringArray()
	for s in [infer, curvenet]:
		var why: String = s.reason if not s.available() else ""
		out.append("%s: %s" % [s.stage_name, "ok" if why == "" else why])
	return " | ".join(out)

# --- Stage 1: the GPU layer's own probes (dress_on.elf) ----------------------------------

func rd_open() -> String: return dress_on.rd_open()
func rd_close() -> String: return dress_on.rd_close()
func rd_probe() -> String: return dress_on.rd_probe()
func rd_bench(n_dispatch: int = 1, n_submit: int = 1, barrier: bool = true) -> String: return dress_on.rd_bench(n_dispatch, n_submit, barrier)
func rd_last_step() -> String: return dress_on.rd_last_step()
func rd_bench_quiet(n_dispatch: int = 1, n_submit: int = 1, barrier: bool = true) -> String: return dress_on.rd_bench_quiet(n_dispatch, n_submit, barrier)
func rd_set_probe() -> String: return dress_on.rd_set_probe()
# kind: ticks|limit|clock|bind|barrier|dispatch|submit|buffer|shader|shader-pba|pipeline|uset|readback|instantiate
func rd_calls(kind: String = "ticks", n: int = 1000) -> String: return dress_on.rd_calls(kind, n)

# --- Cut 4: the curvenet stage (curvenet.elf) ---------------------------------------------

func cn_reset() -> String: return curvenet.cn_reset()
func cn_set_param(name: String = "snap_radius", value: float = 0.03) -> String: return curvenet.cn_set_param(name, value)
func cn_set_body_sphere(radius: float = 0.5) -> String: return curvenet.cn_set_body_sphere(radius)
func pen_demo_circle() -> String: return curvenet.pen_demo_circle()
func cn_get_param(name: String = "snap_radius") -> String: return curvenet.cn_get_param(name)
# The scripted pen: pen_begin loads pen_demo_circle's stroke and sends its first
# sample, pen_point the next count (0: all), pen_end(-1) ends it.
func pen_begin(samples: int = 64, pressure: float = 0.5) -> String: return curvenet.pen_begin(samples, pressure)
func pen_point(count: int = 0) -> String: return curvenet.pen_point(count)
func pen_end(id: int = -1) -> String: return curvenet.pen_end(id)
func patch_count() -> String: return curvenet.patch_count()
func patch_vertices(i: int = 0) -> String: return curvenet.patch_vertices(i)
func patch_indices(i: int = 0) -> String: return curvenet.patch_indices(i)
func mesh_patch_ids() -> String: return curvenet.mesh_patch_ids()
func check_names() -> String: return curvenet.check_names()
func curvenet_checks() -> String: return curvenet.curvenet_checks()
func curvenet_check(name: String = "pen_sphere") -> String: return curvenet.curvenet_check(name)
func curvenet_build() -> String: return curvenet.curvenet_build()
func mesh_build(target_edge_length: float = 0.02, weld_eps: float = 1e-5) -> String: return curvenet.mesh_build(target_edge_length, weld_eps)
func mesh_array_mesh() -> ArrayMesh: return curvenet.mesh_array_mesh()
func curvenet_extract_demo() -> String: return curvenet.curvenet_extract_demo()

# --- Gate 0F: probes.elf, the sandbox runtime probes ---------------------------------------
# gate_runtime.gd is the gate; these are the no-argument wrappers, every
# argument defaulted.

func p_exceptions(do_throw: bool = true) -> String: return dress_on.pv("p_exceptions", [do_throw])
func p_fenv() -> String: return dress_on.pv("p_fenv")
func p_file(path: String = "res://project.godot") -> String: return dress_on.pv("p_file", [path])
func p_threads() -> String: return dress_on.pv("p_threads")
func p_spin(n: int = 1000000) -> String: return dress_on.pv("p_spin", [n])
func p_alloc(mb: int = 64) -> String: return dress_on.pv("p_alloc", [mb])
func p_memalign(n: int = 1000, upstream: bool = false) -> String: return dress_on.pv("p_memalign", [n, upstream])
func echo_f(x: float = 0.1) -> String: return dress_on.pv("echo_f", [x])
func echo_i(x: int = 9007199254740993) -> String: return dress_on.pv("echo_i", [x])
func echo_b(x: bool = true) -> String: return dress_on.pv("echo_b", [x])
func echo_s(s: String = "héllo") -> String: return dress_on.pv("echo_s", [s])
func echo_pf32() -> String: return dress_on.pv("echo_pf32", [PackedFloat32Array([0.1, -0.0, 1e-40])])
func echo_pb() -> String: return dress_on.pv("echo_pb", [PackedByteArray(range(256))])
func f_bits(x: float = 0.1) -> String: return dress_on.pv("f_bits", [x])
func echo_var(v = 1.5) -> String: return dress_on.pv("echo_var", [v])
func p_hold(mb: int = 64) -> String: return dress_on.pv("p_hold", [mb])
func p_release() -> String: return dress_on.pv("p_release")
func p_rd() -> String: return dress_on.pv("p_rd")
func fib_start() -> String: return dress_on.pv("fib_start")
func fib_pump() -> String: return dress_on.pv("fib_pump") # once per frame (rule 4)
func sm_start() -> String: return dress_on.pv("sm_start")
func sm_pump() -> String: return dress_on.pv("sm_pump")
func big_buffer(bytes: int = 256 << 20, direct: bool = false) -> String: return dress_on.pv("big_buffer", [bytes, direct])
func refs_setup() -> String: return dress_on.pv("refs_setup")
func refs_run(n: int = 1000, aliased: bool = false) -> String: return dress_on.pv("refs_run", [n, aliased])
func refs_usets(n: int = 16) -> String: return dress_on.pv("refs_usets", [n])
func refs_setup_one(k: int = 0) -> String: return dress_on.pv("refs_setup_one", [k])
func rid_hold(permanent: bool = true) -> String: return dress_on.pv("rid_hold", [permanent])
func rid_use() -> String: return dress_on.pv("rid_use") # a later vmcall than rid_hold
func set0_share(variant: String = "") -> String: return dress_on.pv("set0_share", [variant]) # "", "_stripped" or "_o1pp"
# mode: 0 aliased, 1 rw_only, 2 pingpong, 3 ro_then_rw, 4 rw_then_ro
func inplace_run(mode: int = 0, rounds: int = 1000) -> String: return dress_on.pv("inplace_run", [mode, rounds])
func p_rd_close() -> String: return dress_on.pv("p_rd_close")
func p_list_end() -> String: return dress_on.pv("p_list_end")
func p_recovery(on: bool = true) -> String: return dress_on.pv("p_recovery", [on])
func f16_read() -> String:
	var h := PackedByteArray()
	h.resize(128)
	for i in 64:
		h.encode_u16(2 * i, 0x3C00 + i) # 1.0 upward
	return dress_on.pv("f16_read", [h])
func ggml_probe(n: int = 256) -> String: return dress_on.pv("ggml_probe", [n])
func zfh_probe() -> String: return dress_on.pv("zfh_probe")

# --- Cut 3: ggml_test.elf, ggml-rd under test-backend-ops (stages/ggml_stage.gd) -----------
# Start a job (or a preset), then poll ggml_job_status() until it is not
# RUNNING; the stage pumps it once per frame (rule 4). A job that runs
# ggml-cpu has every vmcall capped at ~5 minutes (rule 10).

func ggml_attach(total_mb: int = GgmlStage.GGML_TOTAL_MB) -> String: return ggml.ggml_attach(total_mb)
func ggml_ops_start(args: String = "-o ADD,MUL -b RD0", env: String = "") -> String: return ggml.ggml_ops_start(args, env)
func ggml_probe_start(name: String = "chain", arg: String = "256", env: String = "") -> String: return ggml.ggml_probe_start(name, arg, env)
func ggml_pump() -> String: return ggml.ggml_pump()
func ggml_output() -> String: return ggml.ggml_output()
func ggml_rd_stats() -> String: return ggml.ggml_rd_stats()
func ggml_rd_close() -> String: return ggml.ggml_rd_close()
func ggml_job_status() -> String: return ggml.ggml_job_status()
func ggml_ops_add_mul() -> String: return ggml.ggml_ops_add_mul()
func ggml_ops_barrier_all() -> String: return ggml.ggml_ops_barrier_all()
func ggml_ops_fault() -> String: return ggml.ggml_ops_fault()
func ggml_probe_chain() -> String: return ggml.ggml_probe_chain()
func ggml_probe_independent() -> String: return ggml.ggml_probe_independent()
func ggml_probe_alias_rw() -> String: return ggml.ggml_probe_alias_rw()
func ggml_probe_alias_ro() -> String: return ggml.ggml_probe_alias_ro()
func ggml_ops_k1k5() -> String: return ggml.ggml_ops_k1k5()
func ggml_probe_census() -> String: return ggml.ggml_probe_census()
func ggml_probe_census_fault() -> String: return ggml.ggml_probe_census_fault()
func ggml_probe_perf() -> String: return ggml.ggml_probe_perf()
func ggml_ops_move() -> String: return ggml.ggml_ops_move()
func ggml_ops_move_fault() -> String: return ggml.ggml_ops_move_fault()
func ggml_probe_perf_move() -> String: return ggml.ggml_probe_perf_move()
func ggml_ops_conv() -> String: return ggml.ggml_ops_conv()
func ggml_ops_conv_fault() -> String: return ggml.ggml_ops_conv_fault()
func ggml_probe_conv_perf() -> String: return ggml.ggml_probe_conv_perf()
func ggml_ops_rows() -> String: return ggml.ggml_ops_rows()
func ggml_probe_rows_perf() -> String: return ggml.ggml_probe_rows_perf()
func ggml_ops_mul_mat() -> String: return ggml.ggml_ops_mul_mat()
func ggml_probe_mm_perf() -> String: return ggml.ggml_probe_mm_perf()
func ggml_ops_flash_attn() -> String: return ggml.ggml_ops_flash_attn()
func ggml_probe_fa_perf() -> String: return ggml.ggml_probe_fa_perf()
func ggml_ops_all() -> String: return ggml.ggml_ops_all()
func ggml_graph_qwen() -> String: return ggml.ggml_graph_qwen()
func ggml_graph_sconv() -> String: return ggml.ggml_graph_sconv()
func ggml_graph_dit() -> String: return ggml.ggml_graph_dit()
func ggml_graph_kimodo_denoiser() -> String: return ggml.ggml_graph_kimodo_denoiser()
func ggml_graph_kimodo_text() -> String: return ggml.ggml_graph_kimodo_text()
func ggml_dump_list() -> String: return ggml.ggml_dump_list()
func ggml_dump_chunk(index: int = 0, offset: int = 0, bytes: int = 4096) -> PackedByteArray: return ggml.ggml_dump_chunk(index, offset, bytes)
func ggml_graph_dump() -> String: return ggml.ggml_graph_dump()
func ggml_cost_decode() -> String: return ggml.ggml_cost_decode()
func ggml_cost_dit() -> String: return ggml.ggml_cost_dit()
func ggml_probe_files() -> String: return ggml.ggml_probe_files()

# --- Gate 6G.1: rd_worker.elf, GPU round trips for a worker Thread (gates/6g-polyfem-gpu) ---
# gate_rd_worker.gd is the gate (its worker arms need a Thread); these run on
# the calling thread. rw_round / rw_rounds sync inside their own vmcall, as
# rd_bench does: probes, not a pattern. rw_submit then rw_collect a frame later
# is the rule-4 round trip.
func rw_open(n: int = 2796) -> String: return dress_on.rw("rw_open", [n])
func rw_round(k: int = 10, mode: int = 0) -> String: return dress_on.rw("rw_round", [k, mode]) # mode 0 sync_get, 1 get, 2 sync
func rw_rounds(k: int = 10, mode: int = 0, reps: int = 100) -> String: return dress_on.rw("rw_rounds", [k, mode, reps])
func rw_submit(k: int = 10) -> String: return dress_on.rw("rw_submit", [k])
func rw_collect() -> String: return dress_on.rw("rw_collect") # a frame after rw_submit (rule 4)
func rw_stats() -> String: return dress_on.rw("rw_stats")
func rw_close() -> String: return dress_on.rw("rw_close")
func rw_spirv(name: String = "saxpby") -> String: return dress_on.rw("rw_spirv", [name]) # its size

# --- Cut U: the usd stage (usd.elf) ----------------------------------------------------
# One delegate per guest entry point (rule 8); big arrays answer as summary lines.

func usd_init() -> String: return usd.usd_init()
func usd_open(path: String = UsdStage.DEFAULT_PACKAGE) -> String: return usd.usd_open(path)
func usd_push(path: String = UsdStage.DEFAULT_PACKAGE) -> String: return usd.usd_push(path)
func usd_open_staged() -> String: return usd.usd_open_staged()
func usd_blake3(path: String = UsdStage.DEFAULT_PACKAGE) -> String: return usd.usd_blake3(path)
func usd_close() -> String: return usd.usd_close()
func usd_curve_count() -> int: return usd.usd_curve_count()
func usd_curve_info(i: int = 0) -> String: return usd.usd_curve_info(i)
func usd_curve_points(i: int = 0) -> String: return usd.usd_curve_points(i)
func usd_layer_data() -> String: return usd.usd_layer_data()
func usd_write_curves() -> String: return usd.usd_write_curves()
func usd_mesh_count() -> int: return usd.usd_mesh_count()
func usd_material_count() -> int: return usd.usd_material_count()
func usd_texture_count() -> int: return usd.usd_texture_count()
func usd_mesh_info(i: int = 0) -> String: return usd.usd_mesh_info(i)
func usd_mesh_points(i: int = 0) -> String: return usd.usd_mesh_points(i)
func usd_mesh_points_slice(i: int = 0, from: int = 0, count_: int = 4) -> String: return usd.usd_mesh_points_slice(i, from, count_)
func usd_mesh_normals(i: int = 0) -> String: return usd.usd_mesh_normals(i)
func usd_mesh_normals_slice(i: int = 0, from: int = 0, count_: int = 4) -> String: return usd.usd_mesh_normals_slice(i, from, count_)
func usd_mesh_uvs(i: int = 0) -> String: return usd.usd_mesh_uvs(i)
func usd_mesh_uvs_slice(i: int = 0, from: int = 0, count_: int = 4) -> String: return usd.usd_mesh_uvs_slice(i, from, count_)
func usd_mesh_indices(i: int = 0) -> String: return usd.usd_mesh_indices(i)
func usd_mesh_indices_slice(i: int = 0, from: int = 0, count_: int = 4) -> String: return usd.usd_mesh_indices_slice(i, from, count_)
func usd_mesh_transform(i: int = 0) -> String: return usd.usd_mesh_transform(i)
func usd_material(i: int = 0) -> String: return usd.usd_material(i)
func usd_texture_info(i: int = 0) -> String: return usd.usd_texture_info(i)
func usd_texture(i: int = 0) -> String: return usd.usd_texture(i)
func usd_texture_slice(i: int = 0, from: int = 0, count_: int = 16) -> String: return usd.usd_texture_slice(i, from, count_)
func usd_scene() -> String: return usd.usd_scene()

# --- Gate 0G: usd_probe.elf, OpenUSD reading a stage from bytes (gates/0g-openusd) ---
# A probe, not a pipeline stage: its Sandbox is made on first use.
const USD_SAMPLE := "res://../gates/0g-openusd/inputs/skel_quad.usda"
var _usd_sb = null

func _usd_call(fn: String, args: Array = []) -> String:
	if _usd_sb == null:
		var r: Dictionary = preload("res://stages/sandbox_util.gd").make_sandbox(self, "res://usd_probe.elf", 1024)
		if r.sandbox == null:
			return "FAIL: " + str(r.reason)
		_usd_sb = r.sandbox
	return str(_usd_sb.callv("vmcall", [fn] + args))

func usd_probe_init() -> String: return _usd_call("usd_init")
# path_mode 0: USDA through SdfLayer::ImportFromString; 1: the in-memory resolver.
func usd_load(path: String = USD_SAMPLE, path_mode: int = 0) -> String:
	var bytes := FileAccess.get_file_as_bytes(ProjectSettings.globalize_path(path))
	return _usd_call("usd_load", [bytes, path_mode])
