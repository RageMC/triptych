#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Rewrites PNGs in place without metadata: text (tEXt/zTXt/iTXt), EXIF (eXIf) and time (tIME) chunks go; image data,
colour (sRGB/gAMA/cHRM/iCCP) and transparency stay. Used for docs/screenshots (tools/export-public.py checks it).

    python3 tools/screenshots/strip-png-metadata.py FILE.png...
"""
import sys

DROP = {b"tEXt", b"zTXt", b"iTXt", b"eXIf", b"tIME"}


def strip(path):
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", f"{path}: not a PNG"
    out, i, dropped = [data[:8]], 8, []
    while i < len(data):
        n = int.from_bytes(data[i:i + 4], "big")
        kind = data[i + 4:i + 8]
        chunk = data[i:i + 12 + n]
        (dropped.append(kind.decode()) if kind in DROP else out.append(chunk))
        i += 12 + n
        if kind == b"IEND":
            break
    open(path, "wb").write(b"".join(out))
    return dropped


if __name__ == "__main__":
    for p in sys.argv[1:]:
        d = strip(p)
        print(f"{p}: removed {', '.join(d) if d else 'nothing'}")
