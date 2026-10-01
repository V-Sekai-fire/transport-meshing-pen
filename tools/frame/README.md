# Headset harness

Scripts that run the pen on the standalone headset and capture what it shows. `push.sh` puts
them in `~/rfd2287` on the headset. They expect the pen at `~/rfd2287/pen`, the Windows
double-precision engine at `~/rfd2287/godot-dbl`, a compat-layer copy at `~/rfd2287/proton-xrfix`
with its prefix at `~/rfd2287/compat-xrfix`, and they write logs to `~/rfd2287/logs`.

- `push.sh <engine-tag> <addon-tag> [git-ref]`, run on the desk: the pen as `git archive` of the
  ref, the engine and addon from `service-godot-build`'s releases checked against their
  `SHA256SUMS`, and `~/rfd2287/PUSHED` naming all three.
- `proton-xrfix.sh`, run on the headset: makes `proton-xrfix` from stock Proton 11.0 (ARM64),
  `proton-11.0-2c-arm64`, by its one-byte `win32u.so` patch, refusing any other stock build.
- `run-xr.sh <tag> xr|hidden|flat`: the scripted-pen gate in headset mode; `hidden` and `flat`
  are its negative controls.
- `still.sh <out.png>` and `clip.sh <out.avi> <seconds>`: capture the compositor's mirror.
- `run-pen-openvr.sh` and `run-pen-movie.sh`: the pen with the companion pens, live or to a movie.
- `caffeine-setup.sh`: installs `~/rfd2287/caffeine.sh on|off|status`, a sleep inhibitor, so a
  long run keeps its SSH session.
