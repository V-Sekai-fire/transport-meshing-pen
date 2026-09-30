cmake_minimum_required(VERSION 3.16)
project(transport_meshing_pen C CXX)

# The fiber's context switch (guest/fiber, Gate 0F) is a .S file; clang
# assembles it, and needs the same target triple as C (the toolchain file
# only sets C and CXX).
if(CMAKE_C_COMPILER_TARGET AND NOT CMAKE_ASM_COMPILER_TARGET)
	set(CMAKE_ASM_COMPILER_TARGET ${CMAKE_C_COMPILER_TARGET})
endif()
enable_language(ASM)

# The stage code lives in its own repositories, placed by the goal manifest
# (contract-manifest-taskweft); WEFT_ROOT is the root of that checkout.
set(WEFT_ROOT "${CMAKE_SOURCE_DIR}/../.." CACHE PATH "Root of the manifest checkout")
get_filename_component(WEFT_ROOT "${WEFT_ROOT}" ABSOLUTE)
set(GUEST_RUNTIME_ROOT ${WEFT_ROOT}/2-contract/guest-runtime)
set(GUEST_COMMON_ROOT ${WEFT_ROOT}/2-contract/guest-common)
set(GGML_RD_ROOT ${WEFT_ROOT}/2-contract/ggml-rd)
set(LBFGSB_ROOT ${WEFT_ROOT}/2-contract/lbfgsb)
set(ANNY_KERNELS_ROOT ${WEFT_ROOT}/2-contract/anny-kernels)
set(SINEW_ALIGN_ROOT ${WEFT_ROOT}/2-contract/sinew-align)
set(DRAPE_ROOT ${WEFT_ROOT}/3-interactor/drape)
set(CURVENET_ROOT ${WEFT_ROOT}/3-interactor/curvenet)
set(GARMENT_FIT_ROOT ${WEFT_ROOT}/3-interactor/garment-fit)
set(CAGE_ROOT ${WEFT_ROOT}/3-interactor/cage)
set(HEADFIT_ROOT ${WEFT_ROOT}/3-interactor/headfit)
set(LASSO_ROOT ${WEFT_ROOT}/3-interactor/lasso)
set(MOTION_GUEST_ROOT ${WEFT_ROOT}/3-interactor/motion-guest)
set(RFDETR_SEG_ROOT ${WEFT_ROOT}/3-interactor/rfdetr-seg-guest)
set(USD_GUEST_ROOT ${WEFT_ROOT}/3-interactor/usd-guest)
set(GGML_ROOT ${WEFT_ROOT}/2-contract/ggml)
set(KIMODO_GGML_ROOT ${WEFT_ROOT}/3-interactor/kimodo-ggml)
set(RF_DETR_GGML_ROOT ${WEFT_ROOT}/3-interactor/rf-detr-ggml)

# __FILE__ (ggml's asserts) and debug info name sources relative to their
# repository, as they were named inside interactor-dress-on before the split,
# so a committed ELF names neither the machine nor the checkout it was built in.
add_compile_options("-ffile-prefix-map=${CMAKE_SOURCE_DIR}/=")
foreach(root GUEST_RUNTIME_ROOT GUEST_COMMON_ROOT GGML_RD_ROOT LBFGSB_ROOT ANNY_KERNELS_ROOT SINEW_ALIGN_ROOT
		DRAPE_ROOT CURVENET_ROOT GARMENT_FIT_ROOT CAGE_ROOT HEADFIT_ROOT LASSO_ROOT MOTION_GUEST_ROOT
		RFDETR_SEG_ROOT USD_GUEST_ROOT)
	add_compile_options("-ffile-prefix-map=${${root}}/=")
endforeach()
add_compile_options("-ffile-prefix-map=${GGML_ROOT}/=vendor/ggml/"
	"-ffile-prefix-map=${KIMODO_GGML_ROOT}/=vendor/kimodo-ggml/"
	"-ffile-prefix-map=${RF_DETR_GGML_ROOT}/=vendor/rf-detr-ggml/")

# The guest ELF. It builds against godot-sandbox's guest API
# (contract-guest-runtime's vendor/sandbox-api) and nothing else; the riscv64
# sysroot comes in through the toolchain file that build.sh passes.

# The helper would otherwise download a generated header from upstream's
# releases. The guest includes <api.hpp> only.
set(DOWNLOAD_RUNTIME_API OFF CACHE BOOL "" FORCE)
add_subdirectory(${GUEST_RUNTIME_ROOT}/vendor/sandbox-api/cmake sandbox_api)

# The GPU layer is a library, not a member of one program: every ELF that
# touches the GPU links it (composition -- one ELF per stage, each with its own
# heap, rather than one monolith).
add_library(rd_compute STATIC ${GUEST_RUNTIME_ROOT}/guest/rd_compute.cpp)
target_include_directories(rd_compute PUBLIC ${GUEST_RUNTIME_ROOT}/guest)
target_link_libraries(rd_compute PUBLIC sandbox_api)

# The AVBD solver, one source two targets (AGENTS.md rule 2): the Lean-emitted
# kernels as slangc cpp (AvbdCpu) and as SPIR-V embedded by kernels/avbd/gen.sh
# into ${CMAKE_BINARY_DIR}/avbd_kernels.inc (AvbdRd). build.sh runs gen.sh
# before configuring so the embedded header exists.
add_library(avbd STATIC
	${DRAPE_ROOT}/guest/avbd/avbd_topology.cpp
	${DRAPE_ROOT}/guest/avbd/avbd_cpu.cpp
	${DRAPE_ROOT}/guest/avbd/avbd_cpu_backward.cpp
	${DRAPE_ROOT}/guest/avbd/avbd_rd.cpp
	${DRAPE_ROOT}/guest/avbd/avbd_rd_backward.cpp
	${DRAPE_ROOT}/guest/avbd/cloth_grid.cpp
)
target_include_directories(avbd PUBLIC ${GUEST_RUNTIME_ROOT}/guest ${DRAPE_ROOT}/guest ${DRAPE_ROOT}/guest/avbd
	${DRAPE_ROOT}/kernels/avbd/cpp ${GUEST_RUNTIME_ROOT}/guest/avbd/slang-rt ${CMAKE_BINARY_DIR})
target_link_libraries(avbd PUBLIC rd_compute)

# One ELF per stage, each installed at this project's root as <name>.elf,
# which is what the pen's Sandbox nodes load.
function(add_stage_elf name)
	add_sandbox_program(${name} ${ARGN})
	target_link_libraries(${name} PRIVATE rd_compute -lm -lstdc++)
	add_custom_command(TARGET ${name} POST_BUILD
		COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:${name}> ${CMAKE_SOURCE_DIR}/${name}.elf
		COMMENT "Installing ${name}.elf"
	)
endfunction()

# The curvenet stage (Cut 4): Cassie's pen -> curvenet -> mesh on Geogram,
# PMP and MWT subsets, Eigen-free. interactor-curvenet's cmake/curvenet.cmake
# defines its libraries.
option(DRESS_ON_WITH_CURVENET "Build the Cassie curvenet stage libraries" ON)
if(DRESS_ON_WITH_CURVENET)
	include(${CURVENET_ROOT}/cmake/curvenet.cmake OPTIONAL)
	# CASSIE's sketch graph from godot-cassie (the expected cycles of a sketch).
	include(${CURVENET_ROOT}/cmake/cassie_graph.cmake OPTIONAL)
endif()

# lasso.elf (RFD 2287 step 2) on the same godot-lite shim.
include(${LASSO_ROOT}/cmake/lasso.cmake)


# Stage 1: the GPU layer's own probes.
add_stage_elf(dress_on ${GUEST_RUNTIME_ROOT}/guest/main.cpp)

# Stage 2: the drape -- the AVBD solver on both backends, its oracle and bench.
add_stage_elf(drape ${DRAPE_ROOT}/guest/drape/main.cpp ${DRAPE_ROOT}/guest/drape/avbd_jobs.cpp
	${GUEST_RUNTIME_ROOT}/guest/jobs.cpp ${DRAPE_ROOT}/guest/avbd_fixture.cpp
	${DRAPE_ROOT}/guest/drape/drape_jobs.cpp ${DRAPE_ROOT}/guest/drape/drape_scene.cpp
	${DRAPE_ROOT}/guest/drape/primitives.cpp ${DRAPE_ROOT}/guest/drape/body_mesh.cpp
	${LBFGSB_ROOT}/guest/drape/lbfgsb.cpp ${LBFGSB_ROOT}/guest/drape/lbfgsb_gate.cpp
	${DRAPE_ROOT}/guest/drape/lbfgsb_jobs.cpp ${LBFGSB_ROOT}/guest/drape/vec_cpu.cpp
	${LBFGSB_ROOT}/guest/drape/vec_rd.cpp ${DRAPE_ROOT}/guest/drape/inverse_jobs.cpp
	${SINEW_ALIGN_ROOT}/vendor/sinew-align/sinew_align.c)
# The drape driver ports DiffCloth arithmetic that ran on x86-64 without FMA;
# rv64gc has fused multiply-add, which clang would contract into.
set_source_files_properties(${DRAPE_ROOT}/guest/drape/drape_jobs.cpp ${DRAPE_ROOT}/guest/drape/drape_scene.cpp
	${DRAPE_ROOT}/guest/drape/primitives.cpp ${DRAPE_ROOT}/guest/drape/inverse_jobs.cpp
	PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
# The L-BFGS-B driver and its CPU kernels are compiled uncontracted too, so the
# guest's cpu path computes what tests/lbfgsb_driver computes on the host.
# vec_rd.cpp includes ${CMAKE_BINARY_DIR}/drape_kernels.inc (kernels/drape/gen.sh).
set_source_files_properties(${LBFGSB_ROOT}/guest/drape/lbfgsb.cpp ${LBFGSB_ROOT}/guest/drape/lbfgsb_gate.cpp
	${LBFGSB_ROOT}/guest/drape/vec_cpu.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
# The org's rotation fitter (contract-sinew-align, Align.lean's C port) for the
# fit phase's similarity rest update; its unit test runs in the guest as
# drape_sinew_align_test.
target_include_directories(drape PRIVATE ${GUEST_RUNTIME_ROOT}/guest ${GUEST_COMMON_ROOT}/guest ${DRAPE_ROOT}/guest ${LBFGSB_ROOT}/guest
	${DRAPE_ROOT}/guest/drape ${LBFGSB_ROOT}/guest/drape ${SINEW_ALIGN_ROOT}/vendor/sinew-align)
target_link_libraries(drape PRIVATE avbd)

# ggml (contract-ggml's checkout, V-Sekai-fire/ggml): static, riscv64 at rv64gc,
# one thread, no dynamic backend loading, no OpenMP, llamafile or vector
# paths, never Zfh (Gate 0F probe 15 and its Zfh control). ggml's own CMake
# gives its libraries -march=rv64gc; the TUs that include its headers build
# at sandbox-api's -march=rv64gcv_zba_zbb_zbs_zbc. Gate 0F's probes.elf and
# Cut 3's ggml-rd both link it.
foreach(opt GGML_NATIVE GGML_BACKEND_DL BUILD_SHARED_LIBS GGML_OPENMP GGML_LLAMAFILE
		GGML_RVV GGML_RV_ZFH GGML_RV_ZVFH GGML_RV_ZICBOP GGML_RV_ZIHINTPAUSE GGML_RV_ZVFBFWMA
		GGML_BUILD_TESTS GGML_BUILD_EXAMPLES GGML_CCACHE)
	set(${opt} OFF CACHE BOOL "" FORCE)
endforeach()
add_subdirectory(${GGML_ROOT} ggml EXCLUDE_FROM_ALL)
# ggml stamps ggml_commit() with `git rev-parse HEAD`; stamp the commit the ELFs
# were verified against, so a committed ELF does not change with every ggml commit.
get_target_property(_ggml_defs ggml-base COMPILE_DEFINITIONS)
list(FILTER _ggml_defs EXCLUDE REGEX "^GGML_COMMIT=")
list(APPEND _ggml_defs "GGML_COMMIT=\"04b55bba\"")
set_target_properties(ggml-base PROPERTIES COMPILE_DEFINITIONS "${_ggml_defs}")
# clang predefines __riscv_v_intrinsic for every riscv64 target, V or not,
# and ggml-cpu keys its RVV paths on that macro alone; at rv64gc they then
# fail on vfloat32m8_t. Undefine it so the scalar paths are compiled (Gate 0F
# finding 5).
target_compile_options(ggml-cpu PRIVATE -U__riscv_v_intrinsic)
# ggml is compiled as is; its warnings are upstream's, silenced here rather than patched.
target_compile_options(ggml-cpu PRIVATE -Wno-switch)

# Gate 0F: probes.elf, the sandbox runtime probes (gates/0f-runtime). One ELF,
# its own Sandbox, sharing only rd_compute. Its kernels come from
# Lean (lean/ `lake exe emit_probes`) through kernels/probes/gen.sh into
# ${CMAKE_BINARY_DIR}/probes_kernels.inc. Probe 15 runs ggml-cpu in the guest.
add_stage_elf(probes
	${GUEST_RUNTIME_ROOT}/guest/probes/main.cpp
	${GUEST_RUNTIME_ROOT}/guest/probes/zfh_probe.cpp
	${GUEST_RUNTIME_ROOT}/guest/probes/ggml_probe.cpp
	${GUEST_RUNTIME_ROOT}/guest/fiber/fiber.cpp
	${GUEST_RUNTIME_ROOT}/guest/fiber/fiber_riscv64.S
)
target_include_directories(probes PRIVATE ${GUEST_RUNTIME_ROOT}/guest ${GUEST_RUNTIME_ROOT}/guest/probes ${CMAKE_BINARY_DIR})
# The Zfh control arm: this one TU may emit half-precision instructions.
set_source_files_properties(${GUEST_RUNTIME_ROOT}/guest/probes/zfh_probe.cpp PROPERTIES COMPILE_OPTIONS "-march=rv64gc_zfh")
target_compile_definitions(probes PRIVATE PROBES_WITH_GGML=1)
target_link_libraries(probes PRIVATE ggml ggml-cpu ggml-base)

# --- Cut 3: the ggml-rd backend and Gate 3's ggml_test.elf -----------------------

# The pump protocol: a job on a guest fiber, advanced one host call at a time.
add_library(pump STATIC ${GUEST_RUNTIME_ROOT}/guest/pump/pump.cpp ${GUEST_RUNTIME_ROOT}/guest/fiber/fiber.cpp
	${GUEST_RUNTIME_ROOT}/guest/fiber/fiber_riscv64.S)
target_include_directories(pump PUBLIC ${GUEST_RUNTIME_ROOT}/guest)
target_link_libraries(pump PUBLIC sandbox_api)

# ggml-rd: ggml's backend over rd_compute. An OBJECT library, so every
# ops/<op>.cpp is linked and its GGML_RD_OP registrar runs; the glob means an
# op family adds a file, not a line here. The kernels come from Lean through
# kernels/ggml/gen.sh (${CMAKE_BINARY_DIR}/ggml_kernels.inc).
file(GLOB GGML_RD_OPS CONFIGURE_DEPENDS ${GGML_RD_ROOT}/guest/ggml-rd/ops/*.cpp)
# The CPU fallback (guest/ggml-rd/rd_cpu.cpp): the same kernels' slangc cpp
# emits (kernels/ggml/cpp, the other target of rule 2), through the runner
# the host L2 harness uses, generated into the build directory from
# kernels/ggml/kernels.txt. -ffp-contract=off: rv64gc has FMA and the emits
# must round like the harness's x86 build (and ggml-cpu's reference).
find_package(Python3 REQUIRED COMPONENTS Interpreter)
set(GGML_RD_CPU_RUNNER ${CMAKE_BINARY_DIR}/ggml_rd_cpu_kernels.cpp)
file(GLOB GGML_RD_EMITS CONFIGURE_DEPENDS ${GGML_RD_ROOT}/kernels/ggml/cpp/*_emit.cpp)
add_custom_command(
	OUTPUT ${GGML_RD_CPU_RUNNER}
	COMMAND ${Python3_EXECUTABLE} ${GGML_RD_ROOT}/tests/ggml_rd_kernels/gen_host_kernels.py
		${GGML_RD_ROOT}/kernels/ggml/kernels.txt ${GGML_RD_CPU_RUNNER} ${GGML_RD_ROOT}/kernels/ggml/cpp_siblings.txt
	DEPENDS ${GGML_RD_ROOT}/tests/ggml_rd_kernels/gen_host_kernels.py ${GGML_RD_ROOT}/kernels/ggml/kernels.txt
		${GGML_RD_ROOT}/kernels/ggml/cpp_siblings.txt ${GGML_RD_EMITS}
	COMMENT "ggml-rd CPU fallback runners from kernels/ggml/kernels.txt"
)
add_library(ggml_rd OBJECT
	${GGML_RD_ROOT}/guest/ggml-rd/ggml-rd.cpp
	${GGML_RD_ROOT}/guest/ggml-rd/rd_graph.cpp
	${GGML_RD_ROOT}/guest/ggml-rd/rd_kernels.cpp
	${GGML_RD_ROOT}/guest/ggml-rd/rd_pack.cpp
	${GGML_RD_ROOT}/guest/ggml-rd/rd_cpu.cpp
	${GGML_RD_CPU_RUNNER}
	${GGML_RD_OPS}
)
set_source_files_properties(${GGML_RD_CPU_RUNNER} PROPERTIES COMPILE_OPTIONS "-ffp-contract=off"
	INCLUDE_DIRECTORIES "${GGML_RD_ROOT}/kernels/ggml/cpp;${GUEST_RUNTIME_ROOT}/guest/avbd/slang-rt")
target_include_directories(ggml_rd PUBLIC ${GGML_RD_ROOT}/guest/ggml-rd ${GGML_RD_ROOT}/kernels/ggml
	${GGML_RD_ROOT}/tests/ggml_rd_kernels ${CMAKE_BINARY_DIR} ${GGML_ROOT}/src)
target_link_libraries(ggml_rd PUBLIC ggml ggml-base rd_compute)

# Gate 3 (G3.ops): test-backend-ops in the guest, ggml-rd against ggml-cpu.
# test-backend-ops.cpp is ggml's own, compiled as is (its three embedder hooks
# are #ifdef-guarded upstream in V-Sekai-fire/ggml) with its main renamed; the
# link gives every CPU backend it creates one thread (guest/ggml_test/main.cpp
# says why).
add_stage_elf(ggml_test
	${GGML_RD_ROOT}/guest/ggml_test/main.cpp
	${GGML_RD_ROOT}/guest/ggml_test/probes.cpp
	${GGML_RD_ROOT}/guest/ggml_test/census.cpp
	${GGML_RD_ROOT}/guest/ggml_test/probes_rows.cpp
	${GGML_RD_ROOT}/guest/ggml_test/probe_conv.cpp
	${GGML_RD_ROOT}/guest/ggml_test/probe_graph.cpp
	${GGML_RD_ROOT}/guest/ggml_test/graph_nets.cpp
	${GGML_RD_ROOT}/guest/ggml_test/app_graphs/app_graphs.cpp
	${GGML_ROOT}/tests/test-backend-ops.cpp
)
set_source_files_properties(${GGML_ROOT}/tests/test-backend-ops.cpp PROPERTIES
	COMPILE_OPTIONS "-Wno-deprecated-enum-enum-conversion"
	COMPILE_DEFINITIONS "main=ggml_test_backend_ops_main;GGML_GUEST_REGISTER_BACKENDS;N_THREADS=1;GGML_GUEST_EXTRA_EVAL_CASES=\"census_cases.inc\"")
target_include_directories(ggml_test PRIVATE ${GUEST_RUNTIME_ROOT}/guest ${GGML_RD_ROOT}/guest/ggml_test)
target_link_libraries(ggml_test PRIVATE ggml_rd pump ggml ggml-cpu ggml-base)
target_link_options(ggml_test PRIVATE -Wl,--wrap=ggml_backend_init_by_type)

# rfdetr_seg.elf: RF-DETR instance segmentation (RFDETRSegNano) on ggml-rd, the graph
# from interactor-rf-detr-ggml unchanged; weights reach the RD buffer by the pump's UPLOAD.
add_stage_elf(rfdetr_seg
	${RFDETR_SEG_ROOT}/guest/rfdetr_seg/main.cpp
	${RF_DETR_GGML_ROOT}/src/ops.cpp
	${RF_DETR_GGML_ROOT}/src/backbone.cpp
	${RF_DETR_GGML_ROOT}/src/projector.cpp
	${RF_DETR_GGML_ROOT}/src/deform_attn.cpp
	${RF_DETR_GGML_ROOT}/src/decoder.cpp
	${RF_DETR_GGML_ROOT}/src/keypoints.cpp
	${RF_DETR_GGML_ROOT}/src/segmentation.cpp
)
target_include_directories(rfdetr_seg PRIVATE ${GUEST_RUNTIME_ROOT}/guest ${RF_DETR_GGML_ROOT}/src)
target_link_libraries(rfdetr_seg PRIVATE ggml_rd pump ggml ggml-base)

# motion.elf (RFD 2277 A2, gates/10-motion): our own motion for the in-motion
# dress fit. Kimodo-SOMA (kimodo-ggml's denoiser and DDIM sampler; its
# fopen weight loader is replaced by guest/motion/kimodo_weights.cpp) and
# MotionBricks-G1 (interactor-motion-guest's vendor/motion-bricks-ggml: its
# agent, planner and graphs; its neural runtime by guest/motion/mb_runtime.cpp,
# and its four filesystem calls routed through guest_io.hpp) on ggml-rd; the
# weights reach the RD buffer by the pump's UPLOAD. The flexion retarget
# (guest/motion/retarget.cpp) and the matrix decode (kimodo_decode.h) are plain
# C++ that tools/motion_native shares.
set(_mb ${MOTION_GUEST_ROOT}/vendor/motion-bricks-ggml)
add_stage_elf(motion
	${MOTION_GUEST_ROOT}/guest/motion/main.cpp
	${MOTION_GUEST_ROOT}/guest/motion/motion_io.cpp
	${MOTION_GUEST_ROOT}/guest/motion/kimodo_weights.cpp
	${MOTION_GUEST_ROOT}/guest/motion/mb_runtime.cpp
	${MOTION_GUEST_ROOT}/guest/motion/retarget.cpp
	${KIMODO_GGML_ROOT}/src/denoiser.cpp
	${KIMODO_GGML_ROOT}/src/diffusion.cpp
	${KIMODO_GGML_ROOT}/src/motion_rep.cpp
	${_mb}/src/agent.cpp
	${_mb}/src/capi.cpp
	${_mb}/src/decoder.cpp
	${_mb}/src/error.cpp
	${_mb}/src/model.cpp
	${_mb}/src/motion_rep.cpp
	${_mb}/src/planner.cpp
	${_mb}/src/pose.cpp
	${_mb}/src/root.cpp
	${_mb}/src/style.cpp
)
target_include_directories(motion PRIVATE ${GUEST_RUNTIME_ROOT}/guest ${MOTION_GUEST_ROOT}/guest/motion
	${KIMODO_GGML_ROOT}/src ${_mb}/include ${_mb}/src)
target_compile_definitions(motion PRIVATE MOTIONBRICKS_HAVE_GGML=1 MOTIONBRICKS_GUEST_IO=1 MOTIONBRICKS_BUILD=1)
# The CPU-side glue (DDIM, CFG, decode, the agent's springs) rounds like the
# host oracle's build of the same sources (tools/motion_native): no contraction.
target_compile_options(motion PRIVATE -ffp-contract=off)
target_link_libraries(motion PRIVATE ggml_rd pump ggml ggml-base)

# Gate 6G.1: rd_worker.elf, GPU round trips from a vmcall on a worker Thread
# (gates/6g-polyfem-gpu/g1-rd-worker). rd_compute plus Lean's saxpby and df32
# dot_reduce, from ${CMAKE_BINARY_DIR}/drape_kernels.inc (kernels/drape/gen.sh).
add_stage_elf(rd_worker ${GUEST_RUNTIME_ROOT}/guest/rd_worker/main.cpp)
target_include_directories(rd_worker PRIVATE ${GUEST_RUNTIME_ROOT}/guest ${CMAKE_BINARY_DIR})

# RFD 2277 Phase A3: headfit.elf, the ANNY head fit and the unified-expression
# transfer (gates/11-headfit). Its kernels are Lean's (lean/HeadFit,
# kernels/headfit/cpp, committed emits); the solver is contract-lbfgsb's
# L-BFGS-B and the rotation fitter contract-sinew-align. Everything is compiled
# uncontracted, so the guest computes what tests/headfit's native runner computes.
add_stage_elf(headfit ${HEADFIT_ROOT}/guest/headfit/main.cpp ${HEADFIT_ROOT}/guest/headfit/hf_core.cpp
	${HEADFIT_ROOT}/guest/headfit/hf_geom.cpp ${HEADFIT_ROOT}/guest/headfit/hf_kernels.cpp
	${LBFGSB_ROOT}/guest/drape/lbfgsb.cpp ${LBFGSB_ROOT}/guest/drape/vec_cpu.cpp
	${SINEW_ALIGN_ROOT}/vendor/sinew-align/sinew_align.c)
set_source_files_properties(${HEADFIT_ROOT}/guest/headfit/hf_core.cpp ${HEADFIT_ROOT}/guest/headfit/hf_geom.cpp
	${HEADFIT_ROOT}/guest/headfit/hf_kernels.cpp ${SINEW_ALIGN_ROOT}/vendor/sinew-align/sinew_align.c
	PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
target_include_directories(headfit PRIVATE ${HEADFIT_ROOT}/guest/headfit ${LBFGSB_ROOT}/guest/drape
	${DRAPE_ROOT}/guest/drape ${GUEST_RUNTIME_ROOT}/guest/avbd/slang-rt ${SINEW_ALIGN_ROOT}/vendor/sinew-align)

# cage.elf (RFD 2277 Phase A): bhc13 (the (1,3) biharmonic bind, RFD 2279's
# method, guest/common/deform/bhc13), the in-motion cage fit on the drape's
# L-BFGS-B (guest/cage/fit_driver.h, the generic driver the head fit reuses)
# and curvenet patches to a closed cage (PMP's decimation, from the curvenet
# stage's libraries). Every kernel is Lean's: kernels/cage/cpp (the CPU path;
# kernels/cage/gen.sh also embeds their SPIR-V into
# ${CMAKE_BINARY_DIR}/cage_kernels.inc), plus anny_csr_gemv3 and saxpby.
# -ffp-contract=off throughout, so the guest rounds as tests/cage_native does.
if(DRESS_ON_WITH_CURVENET AND TARGET pmp_subset)
	add_library(bhc13 STATIC ${CAGE_ROOT}/guest/common/deform/bhc13/bhc13.cpp
		${CAGE_ROOT}/guest/common/deform/cage_kernels.cpp ${CAGE_ROOT}/guest/common/deform/skin_bake.cpp)
	target_include_directories(bhc13 PUBLIC ${CAGE_ROOT}/guest/common/deform ${GUEST_RUNTIME_ROOT}/guest/avbd/slang-rt
		${CAGE_ROOT}/kernels/cage/cpp ${ANNY_KERNELS_ROOT}/kernels/anny/cpp ${LBFGSB_ROOT}/kernels/drape/cpp)
	target_compile_options(bhc13 PRIVATE -ffp-contract=off)
	add_stage_elf(cage ${CAGE_ROOT}/guest/cage/main.cpp ${CAGE_ROOT}/guest/cage/cage_api.cpp
		${CAGE_ROOT}/guest/cage/cage_fit.cpp ${CAGE_ROOT}/guest/cage/cage_net.cpp ${CAGE_ROOT}/guest/cage/checks.cpp
		${CAGE_ROOT}/guest/cage/fit_driver.cpp ${CAGE_ROOT}/guest/cage/fixtures.cpp
		${LBFGSB_ROOT}/guest/drape/lbfgsb.cpp ${LBFGSB_ROOT}/guest/drape/vec_cpu.cpp)
	set_source_files_properties(${CAGE_ROOT}/guest/cage/cage_api.cpp ${CAGE_ROOT}/guest/cage/cage_fit.cpp
		${CAGE_ROOT}/guest/cage/cage_net.cpp ${CAGE_ROOT}/guest/cage/checks.cpp ${CAGE_ROOT}/guest/cage/fit_driver.cpp
		${CAGE_ROOT}/guest/cage/fixtures.cpp PROPERTIES COMPILE_OPTIONS "-ffp-contract=off")
	target_include_directories(cage PRIVATE ${GUEST_RUNTIME_ROOT}/guest ${GUEST_COMMON_ROOT}/guest ${CAGE_ROOT}/guest
		${CAGE_ROOT}/guest/cage ${LBFGSB_ROOT}/guest/drape ${DRAPE_ROOT}/guest/drape ${CAGE_ROOT}/guest/common/deform
		${GUEST_RUNTIME_ROOT}/guest/avbd/slang-rt)
	target_link_libraries(cage PRIVATE bhc13 pmp_subset)
endif()

# Gate 0G: usd_probe.elf, and Cut U: usd.elf -- OpenUSD 26.05 from bytes (gates/0g-openusd, gates/U-usd).
include(${USD_GUEST_ROOT}/cmake/usd.cmake)

# The fit stage (Cut 6): cloth-fit's garment solve (PolyFEM) with the
# Lean SDF sampler. Last, because it sets directory-wide guest numerics for
# the targets it creates. DRESS_ON_WITH_FIT=OFF (build.sh BUILD_FIT=0) skips it.
include(${GARMENT_FIT_ROOT}/cmake/fit.cmake)
