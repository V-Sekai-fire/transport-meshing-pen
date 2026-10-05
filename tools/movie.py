"""movie -- a Movie Maker recording onto the Desktop, named by the orbit-view standard.

  python tools/movie.py <description> [--fps=30] [--load=5] [--render=60] [--godot=<exe>] -- <gate script> [gate args]
  python tools/movie.py --self-test

Godot is stopped, asked first and then killed, when the gate's "cue: loaded" line has not
appeared --load seconds after launch, or the run has not ended --render seconds after it.
"""
import os
import re
import subprocess
import sys
import tempfile
import time
from datetime import date
from pathlib import Path



def desktop() -> Path:
    return Path(os.environ.get("USERPROFILE", str(Path.home()))) / "Desktop"


def next_name(folder: Path, day: str, description: str) -> Path:
    stem = f"{day}_meshing-pen_{description}_"
    taken = [int(m.group(1)) for p in folder.glob(stem + "*.avi") if (m := re.fullmatch(re.escape(stem) + r"(\d{4})\.avi", p.name))]
    return folder / f"{stem}{max(taken, default=0) + 1:04d}.avi"


def stop(proc: subprocess.Popen) -> None:
    if os.name == "nt":
        subprocess.run(["taskkill", "/T", "/PID", str(proc.pid)], capture_output=True)
    else:
        proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], capture_output=True)
        else:
            proc.kill()
        proc.wait()


def watch(proc: subprocess.Popen, log: Path, load_s: float, render_s: float):
    t0 = time.monotonic()
    loaded = None
    while proc.poll() is None:
        now = time.monotonic()
        if loaded is None and log.exists() and "cue: loaded" in log.read_text(encoding="utf-8", errors="replace"):
            loaded = now
            print(f"loaded in {now - t0:.1f} s")
        if loaded is None and now - t0 > load_s:
            stop(proc)
            print(f"FAIL not loaded {load_s:g} s after launch")
            return None
        if loaded is not None and now - loaded > render_s:
            stop(proc)
            print(f"FAIL rendering passed {render_s:g} s after load")
            return None
        time.sleep(0.1)
    return proc.returncode


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
    with tempfile.TemporaryDirectory() as t:
        log = Path(t) / "gate.txt"
        hang = [sys.executable, "-c", "import time; time.sleep(30)"]
        if watch(subprocess.Popen(hang), log, 0.5, 60) is not None:
            fails += 1
            print("FAIL a run that never loads is not stopped")
        cue = [sys.executable, "-c", f"import time; open(r'{log}','w').write('cue: loaded'); time.sleep(30)"]
        if watch(subprocess.Popen(cue), log, 5, 0.5) is not None:
            fails += 1
            print("FAIL a render past its cap is not stopped")
        log.unlink(missing_ok=True)
        quick = [sys.executable, "-c", f"open(r'{log}','w').write('cue: loaded')"]
        if watch(subprocess.Popen(quick), log, 5, 5) != 0:
            fails += 1
            print("FAIL a run within both caps is stopped")
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
    log = Path(tempfile.gettempdir()) / (raw.stem + ".gate.txt")
    cmd += [f"--out={log}"]
    code = watch(subprocess.Popen(cmd), log, float(opts.get("load", "5")), float(opts.get("render", "60")))
    if code is None:
        for _ in range(50):
            try:
                raw.unlink(missing_ok=True)
                break
            except PermissionError:
                time.sleep(0.1)
        print(f"gate log: {log}")
        return 1
    log.unlink(missing_ok=True)
    if not raw.exists() or raw.stat().st_size == 0:
        print(f"FAIL no recording at {raw}")
        return 1
    raw.rename(out)
    print(f"{out} (exit {code})")
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
