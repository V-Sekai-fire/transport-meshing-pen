#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Walk a persona through the pen in OXRSys as a Touch-class controller pair would.

    python3 tools/walk_oxrsys.py [--beats beats.json] [--host 127.0.0.1] [--hz 90] [--beat-file path]
    python3 tools/walk_oxrsys.py --self-test

Sends ClientConnect, then TrackingPackets (Protocol.h, UDP 9945, 1008 bytes) carrying thumbsticks and
face buttons, which the macOS simulator app does not send. The device name maps to the runtime's
oculus/touch_controller profile. A beat is {"say", "seconds", "left": [x, y], "right": [x, y],
"buttons": [names]}; the default visit is below. Packets keep to a monotonic schedule, so a beat
lasts its seconds; --beat-file holds "<index>\t<say>" for the running beat, then "<count>\tdone".
"""
import argparse
import datetime
import json
import os
import socket
import struct
import sys
import time

TRACKING_PORT = 9945
CONTROL_PORT = 9946
HAND_JOINT_COUNT = 26
FLAGS = 0x0004 | 0x0008
BUTTONS = {"A": 0x0001, "B": 0x0002, "X": 0x0004, "Y": 0x0008, "MENU": 0x0010,
           "LEFT_THUMBSTICK": 0x0020, "RIGHT_THUMBSTICK": 0x0040,
           "LEFT_TRIGGER": 0x0080, "RIGHT_TRIGGER": 0x0100, "LEFT_GRIP": 0x0200, "RIGHT_GRIP": 0x0400}
IDENTITY = (0.0, 0.0, 0.0, 1.0)
HEAD = (0.0, 1.6, 0.0)
LEFT = (-0.25, 1.1, -0.3)
RIGHT = (0.25, 1.1, -0.3)
FMT = '<qI' + 'f' * (7 * 3) + 'I' + 'f' * (4 + 2 + 2 + 1 + 4 + 3 + 3 + HAND_JOINT_COUNT * 4 * 2)
THUMBSTICK_OFFSET = 8 + 4 + 21 * 4 + 4 + 4 * 4
CLIENT_CONNECT_FMT = '<BBBBIII64s'
MESSAGE_TYPE_CLIENT_CONNECT = 0x02
VISIT = [
    {"say": "arrive and settle on the plaza", "seconds": 2.0},
    {"say": "walk toward the station", "seconds": 4.0, "left": [0.0, 0.9]},
    {"say": "stop and look", "seconds": 1.0},
    {"say": "snap turn right", "seconds": 0.25, "right": [0.9, 0.0]},
    {"say": "release the stick", "seconds": 0.5},
    {"say": "snap turn back left", "seconds": 0.25, "right": [-0.9, 0.0]},
    {"say": "release the stick", "seconds": 0.5},
    {"say": "aim a teleport ahead", "seconds": 1.0, "right": [0.0, 0.9]},
    {"say": "release to teleport", "seconds": 1.0},
    {"say": "walk up to the forecourt stairs", "seconds": 4.0, "left": [0.0, 0.9]},
    {"say": "stand on the forecourt", "seconds": 2.0},
]


def client_connect_packet() -> bytes:
    return struct.pack(CLIENT_CONNECT_FMT, MESSAGE_TYPE_CLIENT_CONNECT, 1, 0, 0, 0, 0, 90,
                       b'gate_replay'.ljust(64, b'\x00'))


def packet(left=(0.0, 0.0), right=(0.0, 0.0), buttons=0, t_ns=None) -> bytes:
    vals = [time.monotonic_ns() if t_ns is None else t_ns, FLAGS]
    vals += list(HEAD) + list(IDENTITY) + list(LEFT) + list(IDENTITY) + list(RIGHT) + list(IDENTITY)
    vals += [buttons, 0.0, 0.0, 0.0, 0.0]
    vals += [float(left[0]), float(left[1]), float(right[0]), float(right[1])]
    vals += [0.0] * (1 + 4 + 6 + HAND_JOINT_COUNT * 4 * 2)
    return struct.pack(FMT, *vals)


def write_beat(path, index, say):
    if path:
        with open(path + '.tmp', 'w') as f:
            f.write(f"{index}\t{say}\n")
        os.replace(path + '.tmp', path)


def self_test() -> int:
    checks = [
        ("TrackingPacket is 1008 bytes", struct.calcsize(FMT) == 1008),
        ("ClientConnect is 80 bytes", struct.calcsize(CLIENT_CONNECT_FMT) == 80),
    ]
    p = packet((0.25, -0.5), (0.75, 1.0), BUTTONS["A"] | BUTTONS["Y"], t_ns=7)
    sticks = struct.unpack_from('<4f', p, THUMBSTICK_OFFSET)
    buttons = struct.unpack_from('<I', p, THUMBSTICK_OFFSET - 4 * 4 - 4)[0]
    checks.append(("thumbsticks sit at Protocol.h's offset", sticks == (0.25, -0.5, 0.75, 1.0)))
    checks.append(("buttons sit before the triggers", buttons == BUTTONS["A"] | BUTTONS["Y"]))
    shifted = struct.unpack_from('<4f', p, THUMBSTICK_OFFSET + 4)
    checks.append(("control: one field later does not read the sticks", shifted != sticks))
    beat = f"/tmp/walk_oxrsys_selftest_{os.getpid()}"
    write_beat(beat, 3, "Hana climbs")
    checks.append(("the beat file holds index and say", open(beat).read() == "3\tHana climbs\n"))
    checks.append(("control: the beat file is not left half-written", not os.path.exists(beat + '.tmp')))
    write_beat(None, 4, "ignored")
    checks.append(("control: no path writes nothing", open(beat).read() == "3\tHana climbs\n"))
    os.remove(beat)
    failed = 0
    for name, ok in checks:
        print(f"{'PASS' if ok else 'FAIL'} {name}")
        failed += 0 if ok else 1
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--beats')
    ap.add_argument('--host', default='127.0.0.1')
    ap.add_argument('--hz', type=float, default=90.0)
    ap.add_argument('--beat-file')
    ap.add_argument('--self-test', action='store_true')
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    beats = json.load(open(a.beats)) if a.beats else VISIT
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    dt = 1.0 / a.hz
    for _ in range(3):
        sock.sendto(client_connect_packet(), (a.host, CONTROL_PORT))
        time.sleep(0.2)
    sent = 0
    due = time.monotonic()
    for i, b in enumerate(beats):
        mask = 0
        for name in b.get("buttons", []):
            mask |= BUTTONS[name]
        write_beat(a.beat_file, i, b['say'])
        print(f"walk: {datetime.datetime.now().strftime('%H:%M:%S.%f')[:-3]} beat {i} {b['say']} ({b['seconds']:.2f} s)",
              flush=True)
        for _ in range(max(1, int(round(b["seconds"] * a.hz)))):
            sock.sendto(packet(b.get("left", (0.0, 0.0)), b.get("right", (0.0, 0.0)), mask), (a.host, TRACKING_PORT))
            sent += 1
            due += dt
            time.sleep(max(0.0, due - time.monotonic()))
    write_beat(a.beat_file, len(beats), "done")
    print(f"walk: {datetime.datetime.now().strftime('%H:%M:%S.%f')[:-3]} done, {sent} packets")
    return 0


if __name__ == '__main__':
    sys.exit(main())
