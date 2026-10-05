"""movie -- a Movie Maker recording onto the Desktop, named by the orbit-view standard.

  python tools/movie.py <description> [--fps=30] [--godot=<exe>] -- <gate script> [gate args]
  python tools/movie.py --self-test
"""
import os
import re
import subprocess
import sys
import tempfile
from datetime import date
from pathlib import Path



def desktop() -> Path:
    return Path(os.environ.get("USERPROFILE", str(Path.home()))) / "Desktop"


def next_name(folder: Path, day: str, description: str) -> Path:
    stem = f"{day}_meshing-pen_{description}_"
    taken = [int(m.group(1)) for p in folder.glob(stem + "*.avi") if (m := re.fullmatch(re.escape(stem) + r"(\d{4})\.avi", p.name))]
    return folder / f"{stem}{max(taken, default=0) + 1:04d}.avi"


def self_test() -> int:
    fails = 0
    with tempfile.TemporaryDirectory() as t:
        d = Path(t)
        if next_name(d, "20261004", "orbit").name != "20261004_meshing-pen_orbit_0001.avi":
            fails += 1
            print("FAIL empty folder does not start at 0001")
        (d / "20261004_meshing-pen_orbit_0001.avi").write_bytes(b"")
        (d / "20261004_meshing-pen_orbit_0007.avi").write_bytes(b"")
        if next_name(d, "20261004", "orbit").name != "20261004_meshing-pen_orbit_0008.avi":
            fails += 1
            print("FAIL an existing recording would be overwritten")
    print("ok" if fails == 0 else f"{fails} control(s) failed")
    return 1 if fails else 0


def main(argv: list) -> int:
    if argv == ["--self-test"]:
        return self_test()
    if "--" not in argv or not argv or argv[0].startswith("--"):
        print(__doc__)
        return 2
    cut = argv.index("--")
    own, gate = argv[:cut], argv[cut + 1:]
    opts = dict(a[2:].split("=", 1) if "=" in a else (a[2:], "1") for a in own[1:])
    if not re.fullmatch(r"[a-z0-9-]+", own[0]):
        print("description is lowercase ASCII with hyphens")
        return 2
    root = Path(__file__).resolve().parent.parent
    if not any((root / "addons/cineform/bin").glob("libgodot_cineform.*")):
        print("FAIL no CineForm writer in addons/cineform/bin; unpack the nightly of V-Sekai-fire/entities-godot-cineform there")
        return 1
    out = next_name(desktop(), date.today().strftime("%Y%m%d"), own[0])
    raw = out.with_suffix(".cfhd")
    cmd = [opts.get("godot", "godot"), "--path", str(root), "--xr-mode", "off",
           "--write-movie", str(raw), "--fixed-fps", opts.get("fps", "30"),
           "--script", gate[0], "--", *gate[1:]]
    print(" ".join(cmd))
    code = subprocess.run(cmd).returncode
    if not raw.exists() or raw.stat().st_size == 0:
        print(f"FAIL no recording at {raw}")
        return 1
    raw.rename(out)
    print(f"{out} (exit {code})")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
