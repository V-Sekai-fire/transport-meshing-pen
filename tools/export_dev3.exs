# The game per platform: meshing-pen.dmg (macOS arm64) and meshing-pen-windows.zip (the .exe with its pack, and the addon .dll).
#   GODOT=<double editor> TEMPLATES=<dir holding ENGINE_TAG's templates> elixir tools/export_dev3.exs [--rendering-driver=opengl3]
defmodule ExportDev3 do
  @root Path.expand("..", __DIR__)
  @mac_bin "godot.macos.template_release.double.arm64"
  @win_bin "godot.windows.template_release.double.x86_64.llvm.exe"
  @outputs ~w(meshing-pen.app/Contents/MacOS/meshing-pen meshing-pen.dmg meshing-pen-windows.zip)

  def main(argv) do
    driver = for "--rendering-driver=" <> d <- argv, do: ["--rendering-driver", d]
    Process.put(:driver, List.flatten(driver))
    godot = env!("GODOT")
    templates = env!("TEMPLATES")
    File.cd!(@root)
    File.rm_rf!("build/templates")
    File.rm_rf!("build/export")
    File.mkdir_p!("build/export")
    mac_template(templates)
    File.cp!(Path.join(templates, @win_bin), Path.join("build/templates", @win_bin))

    godot!(godot, ["--import"])
    godot!(godot, ["--export-release", "macos", "build/export/meshing-pen.app"])
    godot!(godot, ["--export-release", "macos", "build/export/meshing-pen.dmg"])
    godot!(godot, ["--export-release", "windows", "build/export/meshing-pen-windows.zip"])

    missing = Enum.reject(@outputs, &(File.regular?(Path.join("build/export", &1)) and File.stat!(Path.join("build/export", &1)).size > 0))
    if missing != [], do: fail("no #{Enum.join(missing, ", ")} in build/export")
    IO.puts("exported: " <> Enum.join(@outputs, " "))
  end

  defp mac_template(templates) do
    stage = Path.join(System.tmp_dir!(), "macos-template-#{System.unique_integer([:positive])}")
    app = Path.join(stage, "macos_template.app")
    File.mkdir_p!(stage)
    File.cp_r!("tools/macos_template/macos_template.app", app)
    bin = Path.join(app, "Contents/MacOS/godot_macos_release.arm64")
    File.mkdir_p!(Path.dirname(bin))
    File.cp!(Path.join(templates, @mac_bin), bin)
    File.chmod!(bin, 0o755)
    files = for f <- Path.wildcard(Path.join(app, "**"), match_dot: true), File.regular?(f), do: String.to_charlist(Path.relative_to(f, stage))
    File.mkdir_p!("build/templates")
    {:ok, _} = :zip.create(String.to_charlist(Path.expand("build/templates/macos.zip")), files, cwd: String.to_charlist(stage))
    File.rm_rf!(stage)
  end

  defp godot!(godot, args) do
    {_, status} = System.cmd(godot, ["--path", "." | Process.get(:driver, [])] ++ args, into: IO.stream(), stderr_to_stdout: true)
    if status != 0, do: fail("godot #{Enum.join(args, " ")} exited #{status}")
  end

  defp env!(name), do: System.get_env(name) || fail("set #{name}")

  defp fail(msg) do
    IO.puts("FAIL #{msg}")
    System.halt(1)
  end
end

ExportDev3.main(System.argv())
