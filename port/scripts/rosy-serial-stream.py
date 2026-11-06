#!/usr/bin/env python3
"""Stream rosy kernel log (cat /dev/kmsg) over the gsi-init USB ACM shell.

usage: rosy-serial-stream.py LOGFILE [SECONDS]
Waits for the port and shell, starts `cat /dev/kmsg`, appends everything to
LOGFILE until SECONDS elapse or the port goes away.
"""
import fcntl
import glob
import os
import select
import struct
import sys
import termios
import time

TIOCMBIS = 0x8004746C
V30 = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   "../vndk30/out/com.android.vndk.v30.apex.xz")


def push_v30(fd, out, wait):
    """Answer prep.sh's READY (sent before the shell starts) with the xz'd VNDK v30 APEX."""
    if not os.path.exists(V30):
        return
    buf = b""
    end = time.time() + wait
    while time.time() < end and b"READY" not in buf:
        r, _, _ = select.select([fd], [], [], 0.3)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except BlockingIOError:
                continue
            except OSError:
                return
            buf += chunk
            out.write(chunk)
    if b"READY" not in buf:
        print("V30_PUSH no READY (shell already up?)", flush=True)
        return
    data = open(V30, "rb").read()
    t = time.time()
    mv = memoryview(b"V30 %d\n" % len(data) + data)
    while mv:
        select.select([], [fd], [], 5)
        try:
            n = os.write(fd, mv[:16384])
        except BlockingIOError:
            continue
        mv = mv[n:]
    buf = b""
    end = time.time() + 120
    while time.time() < end and b"DONE" not in buf and b"FAIL" not in buf:
        r, _, _ = select.select([fd], [], [], 0.5)
        if r:
            try:
                buf += os.read(fd, 65536)
            except BlockingIOError:
                continue
            except OSError:
                break
    print("V30_PUSH %d bytes in %.1fs: %s" % (len(data), time.time() - t,
          "DONE" if b"DONE" in buf else "FAIL" if b"FAIL" in buf else "no-ack"), flush=True)


def open_port(deadline):
    while time.time() < deadline:
        ports = sorted(glob.glob("/dev/cu.usbmodem*"))
        if ports:
            try:
                fd = os.open(ports[0], os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
            except OSError:
                time.sleep(0.5)
                continue
            a = termios.tcgetattr(fd)
            a[0] = 0
            a[1] = 0
            a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
            a[3] = 0
            a[6][termios.VMIN] = 0
            a[6][termios.VTIME] = 0
            termios.tcsetattr(fd, termios.TCSANOW, a)
            try:
                fcntl.ioctl(fd, TIOCMBIS, struct.pack("I", 0x006))
            except OSError:
                pass
            return fd
        time.sleep(0.5)
    return None


def main():
    log = sys.argv[1]
    total = int(sys.argv[2]) if len(sys.argv) > 2 else 300
    start = time.time()
    fd = open_port(start + 120)
    if fd is None:
        print("NO_SERIAL_PORT")
        return 2
    out = open(log, "ab", buffering=0)
    alive = False
    buf = b""
    while time.time() < start + 120 and not alive:
        try:
            os.write(fd, b"echo PING_$((40+2))\r\n")
        except OSError:
            pass
        end = time.time() + 1.5
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.2)
            if r:
                try:
                    buf += os.read(fd, 65536)
                except (BlockingIOError, OSError):
                    pass
        if b"PING_42" in buf:
            alive = True
    if not alive:
        print("SHELL_NOT_ANSWERING")
        return 3
    print("SHELL_ALIVE", flush=True)
    for cmd in sys.argv[3:]:
        os.write(fd, cmd.encode() + b"\r\n")
        end = time.time() + 4
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.3)
            if r:
                try:
                    chunk = os.read(fd, 65536)
                except (BlockingIOError, OSError):
                    continue
                out.write(chunk)
                sys.stdout.write(chunk.decode("utf-8", "replace"))
                sys.stdout.flush()
    print("\nstreaming /dev/kmsg", flush=True)
    os.write(fd, b"cat /dev/kmsg\r\n")
    last = time.time()
    while time.time() < start + total:
        r, _, _ = select.select([fd], [], [], 1.0)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except BlockingIOError:
                continue
            except OSError:
                print("PORT_GONE", flush=True)
                break
            if chunk:
                out.write(chunk)
                last = time.time()
        elif time.time() - last > 5 and not glob.glob("/dev/cu.usbmodem*"):
            print("PORT_GONE", flush=True)
            break
    print("STREAM_END silent_for=%.0fs" % (time.time() - last), flush=True)
    out.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
