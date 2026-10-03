# Launches the exported Windows game until it quits and checks that its guests loaded from the embedded pack.
# The control runs the bare template, which carries no pack, beside the same .dll and must FAIL. Runs on the Windows desk.
#   elixir tools/smoke_export.exs build/export/meshing-pen-windows.exe <godot.windows.template_release.double.x86_64.llvm.exe>
defmodule SmokeExport do
  @guests ~w(dress_on curvenet usd mujoco)
  @dll "libgodot_riscv.windows.template_release.double.x86_64.dll"
  @limit_s 120

  def main([exe, template]) do
    case missing(run(exe)) do
      [] -> IO.puts("PASS smoke: #{Enum.join(@guests, " ")} loaded")
      gone -> fail("smoke: #{Enum.join(gone, " ")} not loaded")
    end

    dir = Path.join(System.tmp_dir!(), "smoke-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    bare = Path.join(dir, "meshing-pen-windows.exe")
    File.cp!(template, bare)
    File.cp!(Path.join(Path.dirname(exe), @dll), Path.join(dir, @dll))

    case missing(run(bare)) do
      [] -> fail("control: the template with no pack still reported its guests")
      _ -> IO.puts("PASS control: the template with no pack loads no guest")
    end

    File.rm_rf!(dir)
  end

  def main(_), do: fail("usage: elixir tools/smoke_export.exs <exported .exe> <bare template .exe>")

  defp run(exe) do
    port = Port.open({:spawn_executable, Path.expand(exe)}, [:binary, :exit_status, :stderr_to_stdout, args: ["--xr-mode", "off", "--quit"]])
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
        System.cmd("taskkill", ["/F", "/T", "/PID", to_string(pid)])
        receive do: ({^port, {:exit_status, _}} -> :ok), after: (5000 -> :ok)
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
