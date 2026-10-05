cmake_minimum_required(VERSION 3.16)
project(transport_meshing_pen C CXX)

# The stage code lives in its own repositories, placed by the goal manifest;
# WEFT_ROOT is the root of that checkout.
set(WEFT_ROOT "${CMAKE_SOURCE_DIR}/../.." CACHE PATH "Root of the manifest checkout")
get_filename_component(WEFT_ROOT "${WEFT_ROOT}" ABSOLUTE)
set(GUEST_RUNTIME_ROOT ${WEFT_ROOT}/2-contract/guest-runtime)
set(GUEST_COMMON_ROOT ${WEFT_ROOT}/2-contract/guest-common)
set(GGML_RD_ROOT ${WEFT_ROOT}/2-contract/ggml-rd)
set(CURVENET_ROOT ${WEFT_ROOT}/3-interactor/curvenet)
set(LASSO_ROOT ${WEFT_ROOT}/3-interactor/lasso)
set(USD_GUEST_ROOT ${WEFT_ROOT}/3-interactor/usd-guest)
set(GGML_ROOT ${WEFT_ROOT}/2-contract/ggml)

# __FILE__ (ggml's asserts) and debug info name sources relative to their
# repository, so a committed ELF names neither the machine nor the checkout it
# was built in. guest_runtime.cmake maps this project and the roots it builds.
foreach(root GUEST_COMMON_ROOT CURVENET_ROOT LASSO_ROOT USD_GUEST_ROOT)
	add_compile_options("-ffile-prefix-map=${${root}}/=")
endforeach()

# sandbox_api, rd_compute, pump, ggml, ggml_rd and add_stage_elf come from
# contract-guest-runtime; the riscv64 sysroot comes in through the toolchain
# file that build.sh passes.
set(GUEST_RUNTIME_GGML ON)
include(${GUEST_RUNTIME_ROOT}/cmake/guest_runtime.cmake)

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

# Gate 0G: usd_probe.elf, and Cut U: usd.elf -- OpenUSD 26.05 from bytes (gates/0g-openusd, gates/U-usd).
include(${USD_GUEST_ROOT}/cmake/usd.cmake)
