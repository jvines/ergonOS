#!/usr/bin/env python3
"""A virtual multitouch touchpad, for the gestures the VM has no hardware to make.

Creates a uinput device shaped like a real laptop touchpad (INPUT_PROP_POINTER,
INPUT_PROP_BUTTONPAD, protocol-B multitouch slots, BTN_TOOL_FINGER..QUADTAP,
a resolution in units/mm) so libinput classifies it as a touchpad and the
compositor takes its swipes through the real gesture path, not a shortcut.

Prints READY once it exists, then reads one command per line from stdin:

    swipe N DX DY [MM]    N fingers move MM millimetres (default 60) along the
                          unit direction (DX, DY): left is -1 0, down is 0 1
    quit

Run as root (uinput). Used by guest-hw.sh (ERGON-137).
"""
import sys
import time

from evdev import AbsInfo, UInput, ecodes as e

W, H, RES = 2000, 1400, 20          # 100 x 70 mm at 20 units/mm
NAME = "ERGON-TEST Virtual Touchpad"
SLOTS = 5

caps = {
    e.EV_KEY: [e.BTN_LEFT, e.BTN_TOUCH, e.BTN_TOOL_FINGER, e.BTN_TOOL_DOUBLETAP,
               e.BTN_TOOL_TRIPLETAP, e.BTN_TOOL_QUADTAP],
    e.EV_ABS: [
        (e.ABS_X, AbsInfo(0, 0, W, 0, 0, RES)),
        (e.ABS_Y, AbsInfo(0, 0, H, 0, 0, RES)),
        (e.ABS_MT_SLOT, AbsInfo(0, 0, SLOTS - 1, 0, 0, 0)),
        (e.ABS_MT_POSITION_X, AbsInfo(0, 0, W, 0, 0, RES)),
        (e.ABS_MT_POSITION_Y, AbsInfo(0, 0, H, 0, 0, RES)),
        (e.ABS_MT_TRACKING_ID, AbsInfo(0, 0, 65535, 0, 0, 0)),
    ],
}
ui = UInput(caps, name=NAME, vendor=0x1234, product=0x5678, version=1,
            input_props=[e.INPUT_PROP_POINTER, e.INPUT_PROP_BUTTONPAD])

TOOL = {1: e.BTN_TOOL_FINGER, 2: e.BTN_TOOL_DOUBLETAP, 3: e.BTN_TOOL_TRIPLETAP,
        4: e.BTN_TOOL_QUADTAP}
_tid = [100]


def tool(n, v):
    for k, c in TOOL.items():
        ui.write(e.EV_KEY, c, v if k == n else 0)


def swipe(n, dx, dy, mm=60.0, steps=40, dt=0.012):
    d = (dx * dx + dy * dy) ** 0.5
    ux, uy = dx / d, dy / d
    dist = mm * RES
    # Fingers side by side across the middle, centred so the whole stroke stays
    # on the pad and out of the palm-rejection edges.
    pad = 260 if n > 3 else 330
    cx, cy = W // 2 - ux * dist / 2, H // 2 - uy * dist / 2
    start = [(cx + (i - (n - 1) / 2) * pad * abs(uy) if uy else cx,
              cy + (i - (n - 1) / 2) * pad * abs(ux) if ux else cy) for i in range(n)]
    ids = []
    for i, (x, y) in enumerate(start):
        _tid[0] += 1
        ids.append(_tid[0])
        ui.write(e.EV_ABS, e.ABS_MT_SLOT, i)
        ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, ids[i])
        ui.write(e.EV_ABS, e.ABS_MT_POSITION_X, int(x))
        ui.write(e.EV_ABS, e.ABS_MT_POSITION_Y, int(y))
    ui.write(e.EV_ABS, e.ABS_X, int(start[0][0]))
    ui.write(e.EV_ABS, e.ABS_Y, int(start[0][1]))
    ui.write(e.EV_KEY, e.BTN_TOUCH, 1)
    tool(n, 1)
    ui.syn()
    time.sleep(0.08)
    for s in range(1, steps + 1):
        f = s / steps
        for i, (x, y) in enumerate(start):
            ui.write(e.EV_ABS, e.ABS_MT_SLOT, i)
            ui.write(e.EV_ABS, e.ABS_MT_POSITION_X, int(x + ux * dist * f))
            ui.write(e.EV_ABS, e.ABS_MT_POSITION_Y, int(y + uy * dist * f))
        ui.write(e.EV_ABS, e.ABS_X, int(start[0][0] + ux * dist * f))
        ui.write(e.EV_ABS, e.ABS_Y, int(start[0][1] + uy * dist * f))
        ui.syn()
        time.sleep(dt)
    time.sleep(0.05)
    for i in range(n):
        ui.write(e.EV_ABS, e.ABS_MT_SLOT, i)
        ui.write(e.EV_ABS, e.ABS_MT_TRACKING_ID, -1)
    ui.write(e.EV_KEY, e.BTN_TOUCH, 0)
    tool(n, 0)
    ui.syn()


print("READY", flush=True)
for line in sys.stdin:
    a = line.split()
    if not a:
        continue
    if a[0] == "quit":
        break
    if a[0] == "swipe" and len(a) >= 4:
        swipe(int(a[1]), float(a[2]), float(a[3]), float(a[4]) if len(a) > 4 else 60.0)
        print("DONE", line.strip(), flush=True)
ui.close()
