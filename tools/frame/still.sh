#!/bin/bash
# A still from the compositor's recording device, the way the headset's own capture tool takes
# one but with v4l2-ctl in place of its video tool: enable local recording,
# read frames, disable it, keep the last frame as PNG.
#   still.sh <out.png>
out=$1
vrcmd=$(steamvr path)/bin/linuxarm64/vrcmd
raw=$(mktemp /tmp/still.XXXXXX.raw)
$vrcmd --mailboxcmd vrcompositor_systemlayer 'set_local_video_record?enabled=true'
sleep 1
timeout 10 v4l2-ctl -d /dev/video99 --stream-mmap --stream-count=12 --stream-to=$raw
rc=$?
$vrcmd --mailboxcmd vrcompositor_systemlayer 'set_local_video_record?enabled=false'
python3 - "$raw" "$out" <<'EOF'
import struct, sys, zlib
raw, out = sys.argv[1], sys.argv[2]
w, h = 1920, 1080
fs = w * h * 3
data = open(raw, "rb").read()
n = len(data) // fs
if n == 0:
    sys.exit("no full frame in %d bytes" % len(data))
f = data[(n - 1) * fs:n * fs]
nonzero = sum(1 for i in range(0, fs, 997) if f[i])
rows = b"".join(b"\x00" + f[y * w * 3:(y + 1) * w * 3] for y in range(h))
def chunk(t, d):
    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) \
    + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b"")
open(out, "wb").write(png)
print("still: %d frames read, last saved to %s, %d of %d sampled bytes nonzero" % (n, out, nonzero, len(range(0, fs, 997))))
EOF
rm -f $raw
echo "v4l2 rc=$rc"
