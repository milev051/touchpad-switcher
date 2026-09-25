#!/usr/bin/env python3
"""
Touchpad Switcher (Adaptivna Python verzija)
Kompaktna širina tastera (--slot-width, default 0.12), pozicioniranje
klastera (--align center|right|left|full), Dock redosled i zaključavanje
kursora miša u gornjoj zoni (Y >= 0.90).

Autor: Gemini (AI Pair Programmer)
Datum: 2026-09-25
"""

import sys
import os
import time
import signal
import threading
import subprocess
import ctypes
from ctypes import c_void_p, c_int, c_uint32, c_float, c_double, Structure, POINTER, CFUNCTYPE

MTS_PATH = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
CF_PATH = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
AS_PATH = "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"

try:
    mts = ctypes.CDLL(MTS_PATH)
    cf = ctypes.CDLL(CF_PATH)
    cg = ctypes.CDLL(AS_PATH)
except OSError as e:
    print(f"[GREŠKA] Nije moguće učitati sistemski framework: {e}", file=sys.stderr)
    sys.exit(1)

class CGPoint(Structure):
    _fields_ = [
        ("x", c_double),
        ("y", c_double)
    ]

cg.CGEventCreate.argtypes = [c_void_p]
cg.CGEventCreate.restype = c_void_p

cg.CGEventGetLocation.argtypes = [c_void_p]
cg.CGEventGetLocation.restype = CGPoint

cg.CGWarpMouseCursorPosition.argtypes = [CGPoint]
cg.CGWarpMouseCursorPosition.restype = c_int

class MTPoint(Structure):
    _fields_ = [
        ("x", c_float),
        ("y", c_float)
    ]

class MTVector(Structure):
    _fields_ = [
        ("position", MTPoint),
        ("velocity", MTPoint)
    ]

class MTTouch(Structure):
    _fields_ = [
        ("frame", c_int),
        ("timestamp", c_double),
        ("pathIndex", c_int),
        ("state", c_uint32),
        ("fingerID", c_int),
        ("handID", c_int),
        ("normalizedVector", MTVector),
        ("zTotal", c_float),
        ("field9", c_int),
        ("angle", c_float),
        ("majorAxis", c_float),
        ("minorAxis", c_float),
        ("absoluteVector", MTVector),
        ("field14", c_int),
        ("field15", c_int),
        ("zDensity", c_float)
    ]

MTContactCallback = CFUNCTYPE(c_int, c_void_p, POINTER(MTTouch), c_int, c_double, c_int)

cf.CFArrayGetCount.argtypes = [c_void_p]
cf.CFArrayGetCount.restype = c_int

cf.CFArrayGetValueAtIndex.argtypes = [c_void_p, c_int]
cf.CFArrayGetValueAtIndex.restype = c_void_p

cf.CFRunLoopRun.argtypes = []
cf.CFRunLoopRun.restype = None

cf.CFRelease.argtypes = [c_void_p]
cf.CFRelease.restype = None

mts.MTDeviceCreateList.argtypes = []
mts.MTDeviceCreateList.restype = c_void_p

mts.MTRegisterContactFrameCallback.argtypes = [c_void_p, MTContactCallback]
mts.MTRegisterContactFrameCallback.restype = None

mts.MTDeviceStart.argtypes = [c_void_p, c_int]
mts.MTDeviceStart.restype = None

mts.MTDeviceStop.argtypes = [c_void_p]
mts.MTDeviceStop.restype = None

TOUCH_STATE_TOUCHING = 4
TOUCH_STATE_MAKE_TOUCH = 3

config = {
    "top_zone_threshold": 0.90,
    "cooldown_seconds": 0.0,
    "slot_width": 0.12,
    "align": "center",
    "debug": False,
    "static_mode": False,
    "static_apps": ["Finder", "Terminal", "Google Chrome"]
}

state = {
    "running_apps": [],
    "apps_lock": threading.Lock(),
    "last_activation_time": 0.0,
    "last_zone": -1,
    "active_finger_id": -1,
    "is_mouse_locked": False,
    "saved_cursor_pos": CGPoint(0, 0),
    "devices": None,
    "stop_monitor": False
}

def calculate_layout(count):
    if count == 0:
        return 0.0, 0.0, 0.0, 0.0

    if config["align"] == "full":
        slot_w = 1.0 / count
        return 0.0, 1.0, slot_w, 1.0

    total_w = count * config["slot_width"]
    if total_w >= 1.0:
        slot_w = 1.0 / count
        return 0.0, 1.0, slot_w, 1.0

    slot_w = config["slot_width"]
    if config["align"] == "left":
        x_start = 0.0
    elif config["align"] == "right":
        x_start = 1.0 - total_w
    else:
        x_start = (1.0 - total_w) / 2.0

    x_end = x_start + total_w
    return x_start, x_end, slot_w, total_w

def get_dock_apps():
    try:
        cmd = ['osascript', '-e', 'tell application "System Events" to tell process "Dock" to get name of UI elements of list 1 whose subrole is "AXApplicationDockItem"']
        res = subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode('utf-8').strip()
        if not res:
            return []
        return [a.strip() for a in res.split(',') if a.strip()]
    except Exception:
        return []

def get_running_gui_apps_in_dock_order():
    try:
        cmd = ['osascript', '-e', 'tell application "System Events" to get name of every process whose background only is false']
        res = subprocess.check_output(cmd, stderr=subprocess.DEVNULL).decode('utf-8').strip()
        if not res:
            return []
        running = [a.strip() for a in res.split(',') if a.strip()]
    except Exception:
        return []

    dock_items = get_dock_apps()

    def dock_key(name):
        for idx, d in enumerate(dock_items):
            if d.lower() == name.lower() or d.lower() in name.lower() or name.lower() in d.lower():
                return (0, idx)
        return (1, name.lower())

    running.sort(key=dock_key)
    return running

def print_zones_table(apps):
    n = len(apps)
    x_start, x_end, slot_w, total_w = calculate_layout(n)

    print("\n╔════════════════════════════════════════════════════════════════════════════════════╗")
    print(f"║ ADAPTIVNI KLASTER TASTERA (N = {n}, Širina tastera = {slot_w*100:.0f}%, Pozicija: {config['align'].upper()}) ║")
    print("╠════════════════════════════════════════════════════════════════════════════════════╣")

    # ASCII traka
    bar = ['.'] * 80
    b_start = max(0, min(80, int(x_start * 80)))
    b_end = max(0, min(80, int(x_end * 80)))
    for i in range(b_start, b_end):
        bar[i] = '#'
    print(f"║ Trackpad: [{''.join(bar)}] ║")
    print(f"║ Klaster:  Od X={x_start:.2f} do X={x_end:.2f} (Ukupna širina: {total_w*100:.0f}% trackpada)                       ║")
    print("╠════════════════════════════════════════════════════════════════════════════════════╣")

    if n == 0:
        print("║ (Nema detektovanih aplikacija)                                                     ║")
    else:
        for i, app_name in enumerate(apps):
            z_s = x_start + i * slot_w
            z_e = z_s + slot_w
            print(f"║ Taster {i:2d} [{z_s:.2f} - {z_e:.2f}]  ->  {app_name:<50} ║")
    print("╚════════════════════════════════════════════════════════════════════════════════════╝")
    print(f"Prag gornje zone : Y >= {config['top_zone_threshold']:.2f} (gornjih {int((1.0 - config['top_zone_threshold']) * 100)}% trackpada)")
    print("Kursor miša je zaključan dok je prst u gornjoj zoni.")
    print("Spustite ili prevucite prst preko označenog klastera za aktivaciju.\n")
    sys.stdout.flush()

def monitor_apps_background():
    while not state["stop_monitor"]:
        time.sleep(2.0)
        if config["static_mode"]:
            continue
        new_apps = get_running_gui_apps_in_dock_order()
        with state["apps_lock"]:
            if new_apps != state["running_apps"]:
                state["running_apps"] = new_apps
                print("\n🔔 [PROMENA POKRENUTIH APLIKACIJA] Ažuriram tastere...")
                print_zones_table(new_apps)

def activate_app(app_name):
    if not app_name:
        return
    script = f'tell application "{app_name}" to activate'
    try:
        subprocess.Popen(
            ["/usr/bin/osascript", "-e", script],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as e:
        print(f"[GREŠKA] Ne mogu da aktiviram {app_name}: {e}", file=sys.stderr)

@MTContactCallback
def on_touch_frame(device, touches_ptr, num_touches, timestamp, frame):
    now = time.time()
    any_in_top_zone = False
    top_touch = None

    for i in range(num_touches):
        t = touches_ptr[i]
        if t.state not in (TOUCH_STATE_TOUCHING, TOUCH_STATE_MAKE_TOUCH):
            if t.fingerID == state["active_finger_id"]:
                state["active_finger_id"] = -1
                state["last_zone"] = -1
            continue

        if t.normalizedVector.position.y >= config["top_zone_threshold"]:
            any_in_top_zone = True
            if top_touch is None:
                top_touch = t

    if any_in_top_zone:
        if not state["is_mouse_locked"]:
            ev = cg.CGEventCreate(None)
            if ev:
                state["saved_cursor_pos"] = cg.CGEventGetLocation(ev)
                cf.CFRelease(ev)
            state["is_mouse_locked"] = True
        cg.CGWarpMouseCursorPosition(state["saved_cursor_pos"])
    else:
        if state["is_mouse_locked"]:
            state["is_mouse_locked"] = False
            cg.CGWarpMouseCursorPosition(state["saved_cursor_pos"])

    if top_touch:
        x = top_touch.normalizedVector.position.x
        y = top_touch.normalizedVector.position.y

        if config["debug"]:
            print(f"[DEBUG] Prst #{top_touch.fingerID} | X={x:.3f} | Y={y:.3f} | MouseLocked={state['is_mouse_locked']}")

        current_zone = -1
        target_app = None

        with state["apps_lock"]:
            apps = list(state["running_apps"])

        n = len(apps)
        if n > 0:
            x_start, x_end, slot_w, total_w = calculate_layout(n)
            if x >= x_start and x < x_end and slot_w > 0:
                zone_idx = int((x - x_start) / slot_w)
                if zone_idx >= n:
                    zone_idx = n - 1
                if zone_idx < 0:
                    zone_idx = 0
                current_zone = zone_idx
                target_app = apps[zone_idx]

        if current_zone != -1:
            zone_changed = (current_zone != state["last_zone"])
            cooldown_passed = (now - state["last_activation_time"] >= config["cooldown_seconds"])
            crossed_boundary = True
            if zone_changed and state["last_zone"] >= 0:
                boundary_zone = state["last_zone"] + 1 if current_zone > state["last_zone"] else state["last_zone"]
                boundary = x_start + boundary_zone * slot_w
                hysteresis = 0.008
                crossed_boundary = (
                    x >= boundary + hysteresis
                    if current_zone > state["last_zone"]
                    else x < boundary - hysteresis
                )

            if zone_changed and cooldown_passed and crossed_boundary:
                state["last_zone"] = current_zone
                state["active_finger_id"] = top_touch.fingerID
                state["last_activation_time"] = now

                print(f"\n⚡ [DETEKTOVAN TASTER]")
                print(f"   Taster     : Taster {current_zone} (X={x:.3f}, Y={y:.3f})")
                print(f"   Aplikacija : Fokusiram -> [{target_app}] (Kursor zaključan)")
                sys.stdout.flush()

                activate_app(target_app)
        else:
            state["last_zone"] = -1
    else:
        if state["active_finger_id"] != -1:
            state["active_finger_id"] = -1
            state["last_zone"] = -1

    return 0

def cleanup(sig=None, frame_obj=None):
    state["stop_monitor"] = True
    state["is_mouse_locked"] = False
    print("\nZaustavljam Touchpad Switcher (Python)...")
    if state["devices"]:
        count = cf.CFArrayGetCount(state["devices"])
        for i in range(count):
            dev = cf.CFArrayGetValueAtIndex(state["devices"], i)
            mts.MTDeviceStop(dev)
    sys.exit(0)

def main():
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == "--slot-width" and i + 1 < len(args):
            config["slot_width"] = float(args[i + 1])
            i += 1
        elif arg == "--align" and i + 1 < len(args):
            config["align"] = args[i + 1].lower()
            i += 1
        elif arg == "--threshold" and i + 1 < len(args):
            config["top_zone_threshold"] = float(args[i + 1])
            i += 1
        elif arg == "--cooldown" and i + 1 < len(args):
            config["cooldown_seconds"] = float(args[i + 1])
            i += 1
        elif arg == "--debug":
            config["debug"] = True
        elif arg == "--list-apps":
            apps = get_running_gui_apps_in_dock_order()
            x_s, x_e, s_w, t_w = calculate_layout(len(apps))
            print(f"\n=== TRENUTNO POKRENUTE REGULARNE GUI APLIKACIJE (DOCK REDOSLED) ===")
            print(f"Konfiguracija klastera: Pozicija={config['align'].upper()}, Širina tastera={s_w*100:.0f}%\n")
            for idx, a in enumerate(apps):
                print(f"Taster {idx:2d} [{x_s + idx*s_w:.2f} - {x_s + (idx+1)*s_w:.2f}] -> {a}")
            print()
            return
        elif arg in ("--help", "-h"):
            print("Korišćenje: python3 touchpad_switcher.py [opcije]")
            print("  --slot-width <float>  Širina tastera (default: 0.12)")
            print("  --align <pozicija>    center, right, left, full (default: center)")
            print("  --threshold <float>   Prag gornje zone (default: 0.90)")
            print("  --cooldown <float>    Opcioni minimalni razmak u s (default: 0)")
            print("  --list-apps           Prikaz tastera u Dock redosledu")
            return
        i += 1

    signal.signal(signal.SIGINT, cleanup)
    signal.signal(signal.SIGTERM, cleanup)

    print("======================================================================")
    print("  TOUCHPAD SWITCHER (PYTHON) - KOMPAKTNI TASTERI & POZICIONIRANJE     ")
    print("======================================================================")

    initial_apps = get_running_gui_apps_in_dock_order()
    state["running_apps"] = initial_apps
    print_zones_table(initial_apps)

    monitor_thread = threading.Thread(target=monitor_apps_background, daemon=True)
    monitor_thread.start()

    devices = mts.MTDeviceCreateList()
    if not devices:
        print("[GREŠKA] Nije pronađena lista Multitouch uređaja.", file=sys.stderr)
        sys.exit(1)

    count = cf.CFArrayGetCount(devices)
    if count == 0:
        print("[GREŠKA] Nijedan trackpad uređaj nije pronađen.", file=sys.stderr)
        sys.exit(1)

    state["devices"] = devices
    for i in range(count):
        dev = cf.CFArrayGetValueAtIndex(devices, i)
        mts.MTRegisterContactFrameCallback(dev, on_touch_frame)
        mts.MTDeviceStart(dev, 0)

    try:
        cf.CFRunLoopRun()
    except KeyboardInterrupt:
        cleanup()

if __name__ == "__main__":
    main()
