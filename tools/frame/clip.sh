#!/bin/bash
# A clip from the HMD compositor mirror -- still.sh, but keeps every frame as a
# video instead of only the last. RGB24 1920x1080, the format still.sh reads.
#   clip.sh <out.avi> <seconds>
out=$1
secs=${2:-5}
vrcmd=$(steamvr path)/bin/linuxarm64/vrcmd
frames=$((secs * 30))
"$vrcmd" --mailboxcmd vrcompositor_systemlayer 'set_local_video_record?enabled=true' >/dev/null 2>&1
sleep 1
timeout $((secs + 12)) v4l2-ctl -d /dev/video99 --stream-mmap --stream-count=$frames --stream-to=- 2>/dev/null \
	| ffmpeg -y -f rawvideo -pix_fmt rgb24 -s 1920x1080 -r 30 -i - -c:v mjpeg -q:v 3 "$out" 2>/dev/null
"$vrcmd" --mailboxcmd vrcompositor_systemlayer 'set_local_video_record?enabled=false' >/dev/null 2>&1
ls -lh "$out" 2>/dev/null | awk '{print "clip:", $5, $NF}'
