#!/usr/bin/env python3
"""In-guest XTest input daemon bridging host pointer/key JSON commands to X11.

Listens on 127.0.0.1:<port> (default 5950) inside the LinuxRunner guest and
drives DISPLAY=:0 via libX11 + libXtst with zero per-event fork overhead.
"""

import ctypes
import ctypes.util
import json
import os
import signal
import socket
import sys

PORT = int(os.environ.get("TRIPTYCH_INPUT_PORT", "5950"))
DISPLAY = os.environ.get("DISPLAY", ":0").encode()

libx11 = ctypes.CDLL("libX11.so.6")
libxtst = ctypes.CDLL("libXtst.so.6")

libx11.XOpenDisplay.argtypes = [ctypes.c_char_p]
libx11.XOpenDisplay.restype = ctypes.c_void_p
libx11.XStringToKeysym.argtypes = [ctypes.c_char_p]
libx11.XStringToKeysym.restype = ctypes.c_ulong
libx11.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
libx11.XKeysymToKeycode.restype = ctypes.c_ubyte
libx11.XFlush.argtypes = [ctypes.c_void_p]

libxtst.XTestFakeMotionEvent.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_ulong]
libxtst.XTestFakeButtonEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
libxtst.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]

SPECIAL_KEYSYMS = {
    "\n": ("Return", False),
    "\r": ("Return", False),
    "\t": ("Tab", False),
    " ": ("space", False),
    "-": ("minus", False),
    "_": ("underscore", True),
    "=": ("equal", False),
    "+": ("plus", True),
    "/": ("slash", False),
    ".": ("period", False),
    ",": ("comma", False),
    ":": ("colon", True),
    ";": ("semicolon", False),
    "'": ("apostrophe", False),
    '"': ("quotedbl", True),
    "|": ("bar", True),
    "&": ("ampersand", True),
    "(": ("parenleft", True),
    ")": ("parenright", True),
    "[": ("bracketleft", False),
    "]": ("bracketright", False),
    "{": ("braceleft", True),
    "}": ("braceright", True),
    "<": ("less", False),
    ">": ("greater", True),
    "$": ("dollar", True),
    "#": ("numbersign", True),
    "~": ("asciitilde", True),
    "\\": ("backslash", False),
    "!": ("exclam", True),
    "?": ("question", True),
    "*": ("asterisk", True),
}

dpy = libx11.XOpenDisplay(DISPLAY)
if not dpy:
    sys.stderr.write("guest_input_agent: failed to open X display\n")
    sys.exit(1)

shift_kc = libx11.XKeysymToKeycode(dpy, libx11.XStringToKeysym(b"Shift_L"))


def send_key(keysym_name: str, down: bool) -> bool:
    ks = libx11.XStringToKeysym(keysym_name.encode())
    if not ks:
        return False
    kc = libx11.XKeysymToKeycode(dpy, ks)
    if not kc:
        return False
    libxtst.XTestFakeKeyEvent(dpy, kc, 1 if down else 0, 0)
    return True


def type_text(text: str) -> None:
    for ch in text:
        need_shift = False
        if ch in SPECIAL_KEYSYMS:
            name, need_shift = SPECIAL_KEYSYMS[ch]
        elif "A" <= ch <= "Z":
            name, need_shift = ch, True
        elif "a" <= ch <= "z" or "0" <= ch <= "9":
            name, need_shift = ch, False
        else:
            continue
        if need_shift and shift_kc:
            libxtst.XTestFakeKeyEvent(dpy, shift_kc, 1, 0)
        send_key(name, True)
        send_key(name, False)
        if need_shift and shift_kc:
            libxtst.XTestFakeKeyEvent(dpy, shift_kc, 0, 0)


def handle_cmd(msg: dict) -> tuple[dict, bool]:
    kind = msg.get("type")
    if kind == "ping":
        return {"ok": True}, False
    if kind == "shutdown":
        return {"ok": True}, True
    if kind == "move":
        libxtst.XTestFakeMotionEvent(dpy, -1, int(msg["x"]), int(msg["y"]), 0)
    elif kind == "button":
        btn = int(msg.get("button", 1))
        down = 1 if msg.get("down", True) else 0
        if "x" in msg and "y" in msg:
            libxtst.XTestFakeMotionEvent(dpy, -1, int(msg["x"]), int(msg["y"]), 0)
        libxtst.XTestFakeButtonEvent(dpy, btn, down, 0)
    elif kind == "click":
        btn = int(msg.get("button", 1))
        if "x" in msg and "y" in msg:
            libxtst.XTestFakeMotionEvent(dpy, -1, int(msg["x"]), int(msg["y"]), 0)
        libxtst.XTestFakeButtonEvent(dpy, btn, 1, 0)
        libxtst.XTestFakeButtonEvent(dpy, btn, 0, 0)
    elif kind == "key":
        ok = send_key(str(msg["keysym"]), bool(msg.get("down", True)))
        if not ok:
            return {"ok": False, "error": f"unknown keysym {msg.get('keysym')}"}, False
    elif kind == "key_combo":
        mods = [str(m) for m in msg.get("mods", [])]
        for m in mods:
            send_key(m, True)
        send_key(str(msg["keysym"]), True)
        send_key(str(msg["keysym"]), False)
        for m in reversed(mods):
            send_key(m, False)
    elif kind == "text":
        type_text(str(msg["text"]))
    else:
        return {"ok": False, "error": f"unknown command {kind}"}, False
    libx11.XFlush(dpy)
    return {"ok": True}, False


running = True
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))

srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", PORT))
srv.listen(8)

if os.environ.get("TRIPTYCH_INPUT_READY_FILE"):
    with open(os.environ["TRIPTYCH_INPUT_READY_FILE"], "w") as f:
        f.write(f"{PORT}\n")

while running:
    conn, _ = srv.accept()
    with conn:
        buf = b""
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    msg = json.loads(line.decode())
                    if not isinstance(msg, dict):
                        raise ValueError("expected JSON object")
                    resp, should_stop = handle_cmd(msg)
                except (UnicodeDecodeError, json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
                    resp, should_stop = {"ok": False, "error": str(exc)}, False
                conn.sendall((json.dumps(resp) + "\n").encode())
                if should_stop:
                    running = False
                    break
