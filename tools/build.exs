# One step, the same on a desk and in CI: elixir tools/build.exs [options]
#
# It checks the tools, gets the riscv64 sysroot, cross-builds the rung's
# guest ELFs from the goal manifest's sibling checkouts into this project's
# root (build.sh), builds and runs the host harnesses (the ggml-rd kernel L2,
# the G3.graph oracle), and, when Godot is on the PATH, imports the project
# and runs the headless gates. Every step prints what it runs; the first
# failure stops the build with a non-zero exit. Plain Elixir, no Mix, no
# dependencies: what erlef/setup-beam gives a GitHub runner and `apt install
# elixir` a desk.
#
#   --targets=a,b     the ELF targets to build (default: all)
#   --no-elfs         skip the cross-build (use the committed ELFs)
#   --no-host         skip the host harnesses
#   --gates=a,b       headless gates to run: load,crossings (default: load)
#   --sysroot=<dir>   the riscv64 sysroot (else $RISCV64_SYSROOT, else fetched)
#   --jobs=N          build parallelism (default: the machine's cores)
#
# Environment it honours: WEFT_ROOT (the manifest checkout, default ../..),
# RISCV64_SYSROOT, BUILD_DIR (default build/rv64), SLANGC, SPIRV_VAL.
defmodule Build do
  @root Path.expand("..", __DIR__)
  # The stage code is in sibling checkouts of the goal manifest (contract-manifest-taskweft).
  @weft System.get_env("WEFT_ROOT") || Path.expand("../..", @root)
  @emit_repos ~w(2-contract/ggml-rd 3-interactor/curvenet)
  @sysroot_repo "https://github.com/V-Sekai-fire/interactor-mujoco-sandbox-demo"
  @sysroot_sub "third_party/riscv64-sysroot"
  @elfs ~w(dress_on curvenet probes ggml_test lasso motion)

  def main(argv) do
    opts = parse(argv)
    say("checkout #{@root}")
    tools(opts)
    sysroot = sysroot(opts)
    if opts.elfs, do: elfs(opts, sysroot)
    if opts.host, do: host(opts)
    if System.find_executable("godot") do
      import_project()
      gates(opts)
    else
      say("godot: not on PATH; the import, the translations and the gates are skipped")
    end
    say("done")
  end

  # --- options -----------------------------------------------------------------

  defp parse(argv) do
    {kv, _, _} =
      OptionParser.parse(argv,
        switches: [targets: :string, no_elfs: :boolean, no_host: :boolean,
                   gates: :string, sysroot: :string, jobs: :integer])
    targets = if kv[:targets], do: String.split(kv[:targets], ","), else: @elfs
    %{
      targets: targets,
      elfs: !kv[:no_elfs],
      host: !kv[:no_host],
      gates: String.split(kv[:gates] || "load", ",", trim: true),
      sysroot: kv[:sysroot] || System.get_env("RISCV64_SYSROOT"),
      jobs: kv[:jobs] || System.schedulers_online()
    }
  end

  # --- steps ---------------------------------------------------------------------

  defp tools(opts) do
    for t <- ~w(cmake ninja clang++ ld.lld python3 git), do: need(t)
    unless System.get_env("SLANGC"), do: need("slangc")
    unless System.get_env("SPIRV_VAL"), do: need("spirv-val")
    {targets, 0} = System.cmd("clang++", ["--print-targets"])
    unless targets =~ "riscv64", do: fail("clang++ has no riscv64 target")
    say("tools: ok (#{opts.jobs} jobs)")
  end

  defp sysroot(%{sysroot: dir}) when is_binary(dir) do
    unless File.exists?(Path.join(dir, "toolchain.cmake")), do: fail("no toolchain.cmake under #{dir}")
    say("sysroot: #{dir}")
    dir
  end

  defp sysroot(_) do
    dir = Path.join([@root, "build", "riscv64-sysroot-src"])
    unless File.exists?(Path.join([dir, @sysroot_sub, "toolchain.cmake"])) do
      File.mkdir_p!(Path.dirname(dir))
      File.rm_rf!(dir)
      run("git", ~w(clone -q --depth 1 --filter=blob:none --sparse #{@sysroot_repo} #{dir}))
      run("git", ~w(-C #{dir} sparse-checkout set #{@sysroot_sub}))
    end
    sysroot = Path.join(dir, @sysroot_sub)
    say("sysroot: #{sysroot} (fetched from the org's mujoco demo)")
    sysroot
  end

  defp elfs(opts, sysroot) do
    env = [
      {"RISCV64_SYSROOT", sysroot},
      {"BUILD_DIR", System.get_env("BUILD_DIR") || Path.join([@root, "build", "rv64"])},
      {"BUILD_TARGETS", Enum.join(opts.targets, " ")},
      {"BUILD_JOBS", to_string(opts.jobs)}
    ]
    run("bash", [Path.join(@root, "build.sh")], [{"WEFT_ROOT", @weft} | env])
    # This machine's slangc may have rewritten the cpp emits with an absolute
    # include of its prelude; put the inline form back (tools/inline_prelude.py).
    prelude = Path.join(@weft, "2-contract/guest-runtime/tools/inline_prelude.py")
    run("python3", [prelude | Enum.map(@emit_repos, &Path.join(@weft, &1))])
    for t <- opts.targets, do: File.exists?(Path.join(@root, "#{t}.elf")) || fail("no #{t}.elf")
    say("elfs: #{Enum.join(opts.targets, " ")}")
  end

  defp host(opts) do
    l2 = Path.join([@root, "build", "l2"])
    cmake(Path.join(@weft, "2-contract/ggml-rd/tests/ggml_rd_kernels"), l2, [], opts)
    run(Path.join(l2, "ggml_rd_l2"), [])
    run(Path.join(l2, "ggml_rd_l2"), ["--control=swap-nb"])
    oracle = Path.join([@root, "build", "oracle"])
    vulkan = if System.get_env("VULKAN_SDK") || System.find_executable("glslc"), do: "ON", else: "OFF"
    cmake(Path.join(@weft, "2-contract/ggml-rd/tests/ggml_graph_oracle"), oracle, ["-DORACLE_VULKAN=#{vulkan}"], opts)
    say("host: L2 and its control PASS; oracle built (ggml-vulkan #{vulkan})")
  end

  defp import_project do
    run("godot", ~w(--path #{@root} --headless --xr-mode off --import), [], allow_fail: true)
  end

  defp gates(opts) do
    for g <- opts.gates do
      script =
        case g do
          "load" -> "tools/probe_load.gd"
          "crossings" -> "tests/e2e_crossings.gd"
          other -> fail("unknown gate #{other}")
        end
      run("godot", ~w(--path #{@root} --headless --xr-mode off --script #{script}))
    end
  end

  # --- helpers -------------------------------------------------------------------

  defp cmake(src, dir, extra, opts) do
    unless File.exists?(Path.join(dir, "build.ninja")) do
      run("cmake", ~w(-S #{src} -B #{dir} -G Ninja -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++
                     -DCMAKE_BUILD_TYPE=Release) ++ extra)
    end
    run("cmake", ~w(--build #{dir} -- -j#{opts.jobs}))
  end

  defp run(cmd, args, env \\ [], o \\ []) do
    say("$ #{cmd} #{Enum.join(args, " ")}")
    {_, rc} = System.cmd(cmd, args, env: env, into: IO.stream(:stdio, :line), stderr_to_stdout: true, cd: @root)
    if rc != 0 and not Keyword.get(o, :allow_fail, false), do: fail("#{cmd} exited #{rc}")
    rc
  end

  defp need(tool), do: System.find_executable(tool) || fail("#{tool} is not on PATH")
  defp say(msg), do: IO.puts("== #{msg}")

  defp fail(msg) do
    IO.puts(:stderr, "build: #{msg}")
    System.halt(1)
  end
end

Build.main(System.argv())
