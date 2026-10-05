# Startup load, measured 2026-10-04 (WIP, parked)

Flat gate on feat/dress-on 7ea09a3, `godot.windows.editor.double.x86_64.llvm.console.exe --path . --xr-mode off
--script tools/gate_xr_scripted.gd -- --expect=flat`, RTX 4090 desk. Baseline: `view: flat` at 55.4 s, PASS at
59.5 s, process wall 61.4 s.

| phase (Time.get_ticks_usec, engine clock) | s | share of 56.7 s to frame 5 |
|---|---|---|
| engine start to gate `_initialize` | 0.99 | 2% |
| `load(xr_main.tscn)` + instantiate | 0.58 | 1% |
| station `environment` build (terrain kernel in interpreted RISC-V, far, levee, river, park, flora) | 19.29 | 34% |
| station `station` + `plaza` builds | 2.37 | 4% |
| station `sakura` build | 20.16 | 36% |
| station realize (synchronous part) | 3.30 | 6% |
| stage guests dress_on, curvenet, usd, mujoco | 0.85 | 1% |
| first frame (CSG union, pipelines) | 6.21 | 11% |
| realize `finish()` after two frames, station_physics guest | 2.86 | 5% |
| frames 3 to 5 | 0.02 | 0% |

samply 0.13.1 (ETW), main thread, 62.5 s, 1 ms samples: CPU-bound throughout. Self time: godot exe 66.4%,
libgodot_riscv 16.4% (concentrated at 5 to 20 s, the environment build's terrain kernel, guests
`is_binary_translated=false`), ntdll 9.0%, ntoskrnl 3.6%, nvoglv64 1.5%. The editor build ships no PDB or
DWARF, so native frames are unnamed addresses; GDScript compile vs. execution cannot be split from it. Script
load per module is 0.09 to 0.32 s, so compile is not the cost: building is.

Next: run the station's `build(ctx)` (pure RefCounted scene graph) on WorkerThreadPool and realize after
it lands, with a cancel flag checked between modules and in sakura's tree loop so quit does not wait out
the build. Expected first frame near 3 s; the station then streams in, still with a ~9 s main-thread hitch
in realize + CSG that a cached `.scn` keyed by source hash would remove.
