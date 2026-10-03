# Launches the exported macOS app until it quits and checks that its guests loaded from the embedded pack.
# The control runs a copy with the pack removed, which must FAIL. Each run is cut off after @limit_s.
#   elixir tools/smoke_export.exs build/export/meshing-pen.app
defmodule SmokeExport do
  @guests ~w(dress_on curvenet usd mujoco)
  @limit_s 60

  def main([app]) do
    case missing(run(app)) do
      [] -> IO.puts("PASS smoke: #{Enum.join(@guests, " ")} loaded")
      gone -> fail("smoke: #{Enum.join(gone, " ")} not loaded")
    end

    bare = Path.join(System.tmp_dir!(), "smoke-#{System.unique_integer([:positive])}/meshing-pen.app")
    File.mkdir_p!(Path.dirname(bare))
    File.cp_r!(app, bare)
    Enum.each(Path.wildcard(Path.join(bare, "Contents/Resources/*.pck")), &File.rm!/1)

    case missing(run(bare)) do
      [] -> fail("control: the app with no pack still reported its guests")
      _ -> IO.puts("PASS control: the app with no pack loads no guest")
    end

    File.rm_rf!(Path.dirname(bare))
  end

  def main(_), do: fail("usage: elixir tools/smoke_export.exs <exported .app>")

  defp run(app) do
    exe = Path.join(app, "Contents/MacOS/meshing-pen")
    port = Port.open({:spawn_executable, exe}, [:binary, :exit_status, :stderr_to_stdout, args: ["--xr-mode", "off", "--quit"]])
    {:os_pid, pid} = Port.info(port, :os_pid)
    collect(port, pid, "", System.monotonic_time(:millisecond) + @limit_s * 1000)
  end

  defp collect(port, pid, acc, deadline) do
    wait = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, d}} -> collect(port, pid, acc <> d, deadline)
      {^port, {:exit_status, _}} -> acc
    after
      wait ->
        System.cmd("kill", ["-9", to_string(pid)])
        acc <> "\n(cut off after #{@limit_s} s)\n"
    end
  end

  defp missing(log), do: Enum.reject(@guests, &String.contains?(log, "sandbox loaded #{&1}.elf"))

  defp fail(msg) do
    IO.puts("FAIL #{msg}")
    System.halt(1)
  end
end

SmokeExport.main(System.argv())
