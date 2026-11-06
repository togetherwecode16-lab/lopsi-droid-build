#!/usr/bin/env python3
"""Raw probe of the rosy USB ACM port: assert DTR, send lines, dump replies."""
import fcntl
import glob
import os
import select
import struct
import sys
import termios
import time

TIOCMBIS = 0x8004746C
TIOCM_DTR = 0x002
TIOCM_RTS = 0x004

ports = sorted(glob.glob("/dev/cu.usbmodem*"))
if not ports:
    print("NO_PORT")
    sys.exit(2)
fd = os.open(ports[0], os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
a = termios.tcgetattr(fd)
a[0] = 0
a[1] = 0
a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
a[3] = 0
a[6][termios.VMIN] = 0
a[6][termios.VTIME] = 0
termios.tcsetattr(fd, termios.TCSANOW, a)
try:
    fcntl.ioctl(fd, TIOCMBIS, struct.pack("I", TIOCM_DTR | TIOCM_RTS))
except OSError as e:
    print("dtr_err", e)

lines = sys.argv[1:] or ["", "echo HELLO_$((6*7))"]
wait = float(os.environ.get("PROBE_WAIT", "4"))
out = b""
for line in lines:
    try:
        os.write(fd, line.encode() + b"\r\n")
    except OSError as e:
        print("write_err", e)
    end = time.time() + wait
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.3)
        if r:
            try:
                out += os.read(fd, 65536)
            except BlockingIOError:
                pass
print("PORT", ports[0], "BYTES", len(out))
sys.stdout.write(out.decode("utf-8", "replace"))
print()
