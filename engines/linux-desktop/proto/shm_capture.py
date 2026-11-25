#!/usr/bin/env python3
"""Host-side shared-memory XWD reader, PNG encoder, and input injector.

Maps the guest Xvfb framebuffer directly from <rootfs>/data/dev/shm/Xvfb_screen0
using mmap (zero X11 client calls and zero RFB/VNC), validates the XWD header
geometry/pixel layout (BGRX8888), and sends JSON pointer/keyboard events to the
in-guest XTest agent over 127.0.0.1.
"""

import argparse
import hashlib
import json
import mmap
import os
import socket
import struct
import sys
import time
import zlib

XWD_HEADER_STRUCT = struct.Struct(">25I")


def parse_xwd(mm: mmap.mmap):
    vals = XWD_HEADER_STRUCT.unpack_from(mm, 0)
    hdr_size, ver, fmt, depth, w, h = vals[0], vals[1], vals[2], vals[3], vals[4], vals[5]
    byte_order, bpp, bpl = vals[7], vals[11], vals[12]
    rmask, gmask, bmask, ncolors = vals[14], vals[15], vals[16], vals[19]
    if ver != 7 or fmt != 2 or bpp != 32:
        raise RuntimeError(f"Unsupported XWD format ver={ver} fmt={fmt} bpp={bpp}")
    if (rmask, gmask, bmask) != (0xFF0000, 0x00FF00, 0x0000FF):
        raise RuntimeError(f"Unexpected masks r={rmask:#x} g={gmask:#x} b={bmask:#x}")
    if byte_order != 0:
        raise RuntimeError(f"Unexpected XWD byte_order={byte_order} (expected LSBFirst=0)")
    pixel_offset = hdr_size + ncolors * 12
    expected_end = pixel_offset + bpl * h
    if len(mm) < expected_end:
        raise RuntimeError(f"Truncated SHM framebuffer {len(mm)} < {expected_end}")
    return w, h, bpl, pixel_offset


def write_png_from_bgrx(out_path: str, buf: bytes, w: int, h: int, bpl: int):
    # Xvfb depth-24 32bpp stores B,G,R,X per pixel on little-endian ARM64.
    # Convert each scanline directly to PNG filter-0 RGB24 (3 bytes/px) for compact lossless proof.
    rows = bytearray()
    row_bytes = w * 4
    for y in range(h):
        start = y * bpl
        row = buf[start : start + row_bytes]
        rows.append(0)
        # Reorder BGRX -> RGB in slice operations (fast in CPython).
        rgb = bytearray(w * 3)
        rgb[0::3] = row[2::4]
        rgb[1::3] = row[1::4]
        rgb[2::3] = row[0::4]
        rows.extend(rgb)

    def chunk(tag: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(tag + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", crc)

    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    idat = zlib.compress(bytes(rows), level=6)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "wb") as f:
        f.write(png)


def send_input(port: int, cmds: list[dict]):
    with socket.create_connection(("127.0.0.1", port), timeout=5) as s:
        f = s.makefile("rw", encoding="utf-8", newline="\n")
        for c in cmds:
            f.write(json.dumps(c) + "\n")
            f.flush()
            reply = json.loads(f.readline())
            if not reply.get("ok"):
                raise RuntimeError(f"Input command {c} failed: {reply}")


def read_stable_pixels(mm: mmap.mmap, w: int, h: int, bpl: int, offset: int, settle_s: float = 0.6) -> tuple[bytes, str]:
    size = bpl * h
    prev = mm[offset : offset + size]
    prev_hash = hashlib.sha256(prev).hexdigest()
    stable_since = time.monotonic()
    while True:
        time.sleep(0.15)
        cur = mm[offset : offset + size]
        cur_hash = hashlib.sha256(cur).hexdigest()
        if cur_hash != prev_hash:
            prev = cur
            prev_hash = cur_hash
            stable_since = time.monotonic()
        elif time.monotonic() - stable_since >= settle_s:
            return cur, cur_hash


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shm", required=True, help="Host path to Xvfb_screen0 in /dev/shm")
    ap.add_argument("--out", help="Output PNG path")
    ap.add_argument("--port", type=int, default=5950)
    ap.add_argument("--input-json", help="JSON file or inline array of input commands to execute")
    ap.add_argument("--settle", type=float, default=0.6)
    args = ap.parse_args()

    if args.input_json:
        raw = open(args.input_json).read() if os.path.exists(args.input_json) else args.input_json
        cmds = json.loads(raw)
        t0 = time.monotonic()
        send_input(args.port, cmds)
        print(f"INPUT_OK cmds={len(cmds)} elapsed_ms={(time.monotonic()-t0)*1000:.1f}")

    if args.out:
        with open(args.shm, "rb") as f:
            with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:
                w, h, bpl, offset = parse_xwd(mm)
                pixels, sha = read_stable_pixels(mm, w, h, bpl, offset, settle_s=args.settle)
                non_black = sum(1 for i in range(0, len(pixels), 4096) if pixels[i : i + 3] != b"\x00\x00\x00")
                write_png_from_bgrx(args.out, pixels, w, h, bpl)
                print(f"CAPTURE_OK path={args.out} w={w} h={h} bpl={bpl} offset={offset} sha256={sha[:16]} non_black_samples={non_black}")


if __name__ == "__main__":
    main()
