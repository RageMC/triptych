#!/usr/bin/env python3
"""Log in to a live Alpine x86_64 guest over a QEMU TCP serial port and run small CPU/memory benchmarks.
usage: guest-bench.py <port> [timeout_s]   -> prints one JSON line (seconds per test + boot-to-login time)
The guest must use -serial tcp:127.0.0.1:<port>,server,nowait (Alpine's live ISO starts a getty on ttyS0, root has
no password). NET=1: also bring up eth0 with DHCP (slirp, -nic user) and wget (a) a 1 MiB file from the host over
slirp's 10.0.2.2 (served by this script on NET_PORT, default 44446) and (b) a small file from the internet
(http://dl-cdn.alpinelinux.org/alpine/MIRRORS.txt); reports seconds and bytes."""
import json, os, re, socket, sys, threading, time
port = int(sys.argv[1]); limit = float(sys.argv[2]) if len(sys.argv) > 2 else 900
NET = os.environ.get("NET") == "1"; NET_PORT = int(os.environ.get("NET_PORT", "44446"))
if NET:   # tiny HTTP server: any path -> 1 MiB of zeros
    import http.server
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200); self.send_header("Content-Length", str(1 << 20)); self.end_headers()
            self.wfile.write(b"\0" * (1 << 20))
        def log_message(self, *a): pass
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", NET_PORT), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
t0 = time.time(); s = None
while s is None and time.time() - t0 < limit:
    try: s = socket.create_connection(("127.0.0.1", port), timeout=2)
    except OSError: time.sleep(0.5)
s.settimeout(1); buf = b""
def until(pat, tmo, poke=None):
    global buf
    end = time.time() + tmo; last = 0
    while time.time() < end:
        try:
            d = s.recv(65536)
            if d: buf += d
        except socket.timeout: pass
        m = re.search(pat, buf)
        if m: r = buf[:m.end()]; buf = buf[m.end():]; return r
        if poke and time.time() - last > 5: s.sendall(poke); last = time.time()
    raise SystemExit("timeout waiting for %r; tail %r" % (pat, buf[-300:]))
until(rb"login: ", limit, poke=b"\n"); login = time.time() - t0
s.sendall(b"root\n"); until(rb"# ", 120)
s.sendall(b"stty -echo; PS1='GB# '\n"); until(rb"GB# ", 60)
tests = {
  "shell_loop_200k": "i=0; while [ $i -lt 200000 ]; do i=$((i+1)); done",
  "md5_64MiB": "dd if=/dev/zero bs=1M count=64 2>/dev/null | md5sum >/dev/null",
  "urandom_gzip_8MiB": "dd if=/dev/urandom bs=1M count=8 2>/dev/null | gzip -1 >/dev/null",
}
out = {"boot_to_login_s": round(login, 1)}
for k, cmd in tests.items():
    # busybox date has no %N: time with /proc/uptime (10 ms resolution)
    s.sendall(("a=$(cut -d' ' -f1 /proc/uptime); %s; b=$(cut -d' ' -f1 /proc/uptime); echo RES $a $b\n" % cmd).encode())
    m = re.search(rb"RES ([\d.]+) ([\d.]+)", until(rb"RES [\d.]+ [\d.]+\r?\n", 900))
    out[k + "_s"] = round(float(m.group(2)) - float(m.group(1)), 2)
if NET:
    s.sendall(b"modprobe virtio_net 2>/dev/null; ip link set eth0 up; a=$(cut -d' ' -f1 /proc/uptime); udhcpc -i eth0 -n -q -t 10 >/dev/null 2>&1; "
              b"b=$(cut -d' ' -f1 /proc/uptime); echo DHCP $a $b $(ip -4 -o addr show eth0 | sed 's/.*inet \\([0-9.]*\\).*/\\1/')\n")
    m = re.search(rb"DHCP ([\d.]+) ([\d.]+) ?(\S*)", until(rb"DHCP [\d.]+ [\d.]+.*\r?\n", 120))
    out["dhcp_s"] = round(float(m.group(2)) - float(m.group(1)), 2); out["ip"] = m.group(3).decode()
    for k, url in {"wget_host_1MiB": "http://10.0.2.2:%d/f" % NET_PORT,
                   "wget_internet_mirrors": "http://dl-cdn.alpinelinux.org/alpine/MIRRORS.txt"}.items():
        s.sendall(("a=$(cut -d' ' -f1 /proc/uptime); wget -q -O /tmp/f '%s'; r=$?; b=$(cut -d' ' -f1 /proc/uptime); "
                   "echo RES $a $b $r $(stat -c %%s /tmp/f 2>/dev/null || echo 0)\n" % url).encode())
        m = re.search(rb"RES ([\d.]+) ([\d.]+) (\d+) (\d+)", until(rb"RES [\d.]+ [\d.]+ \d+ \d+\r?\n", 300))
        out[k + "_s"] = round(float(m.group(2)) - float(m.group(1)), 2); out[k + "_bytes"] = int(m.group(4)); out[k + "_rc"] = int(m.group(3))
s.sendall(b"poweroff\n"); s.close()
print(json.dumps(out))
