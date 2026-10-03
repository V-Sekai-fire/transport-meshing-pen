# The game: meshing-pen-windows.exe with its pack embedded, and the addon .dll beside it, exported headless.
#   GODOT=<double editor> TEMPLATES=<dir holding ENGINE_TAG's templates> elixir tools/export_dev3.exs
defmodule ExportDev3 do
  @root Path.expand("..", __DIR__)
  @win_bin "godot.windows.template_release.double.x86_64.llvm.exe"
  @outputs ~w(meshing-pen-windows.exe libgodot_riscv.windows.template_release.double.x86_64.dll)
  @limit_s 240

  def main do
    godot = env!("GODOT")
    templates = env!("TEMPLATES")
    File.cd!(@root)
    File.rm_rf!("build/templates")
    File.rm_rf!("build/export")
    File.mkdir_p!("build/export")
    File.mkdir_p!("build/templates")
    File.cp!(Path.join(templates, @win_bin), Path.join("build/templates", @win_bin))

    godot!(godot, ["--import"])
    godot!(godot, ["--export-release", "windows", "build/export/meshing-pen-windows.exe"])

    missing = Enum.reject(@outputs, &(File.regular?(Path.join("build/export", &1)) and File.stat!(Path.join("build/export", &1)).size > 0))
    if missing != [], do: fail("no #{Enum.join(missing, ", ")} in build/export")
    archives = Path.wildcard("build/export/*.{zip,dmg,pck}")
    if archives != [], do: fail("#{Enum.join(archives, ", ")} beside the game")
    IO.puts("exported: " <> Enum.join(@outputs, " "))
  end

  defp godot!(godot, args) do
    task = Task.async(fn -> System.cmd(godot, ["--headless", "--path", "." | args], into: IO.stream(), stderr_to_stdout: true) end)

    case Task.yield(task, @limit_s * 1000) || Task.shutdown(task, :brutal_kill) do
      {:ok, {_, 0}} -> :ok
      {:ok, {_, status}} -> fail("godot #{Enum.join(args, " ")} exited #{status}")
      nil -> fail("godot #{Enum.join(args, " ")} ran past #{@limit_s} s")
    end
  end

  defp env!(name), do: System.get_env(name) || fail("set #{name}")

  defp fail(msg) do
    IO.puts("FAIL #{msg}")
    System.halt(1)
  end
end

ExportDev3.main()
