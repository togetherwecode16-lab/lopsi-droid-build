#!/usr/bin/env python3
"""Run shell commands on rosy over the gsi-init USB ACM busybox shell.

usage: rosy-serial.py [--wait SECS] [--timeout SECS] [--log FILE] 'cmd1' 'cmd2' ...
Waits for the port, asserts DTR, pings until the shell answers, then runs cmds.
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
TIOCM_DTR = 0x002
TIOCM_RTS = 0x004


def open_port(deadline):
    while time.time() < deadline:
        ports = sorted(glob.glob("/dev/cu.usbmodem*"))
        if ports:
            try:
                fd = os.open(ports[0], os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
            except OSError:
                time.sleep(1)
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
                fcntl.ioctl(fd, TIOCMBIS, struct.pack("I", TIOCM_DTR | TIOCM_RTS))
            except OSError:
                pass
            return ports[0], fd
        time.sleep(1)
    return None, None


def read_until(fd, token, limit):
    buf = b""
    end = time.time() + limit
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.3)
        if r:
            try:
                chunk = os.read(fd, 65536)
            except BlockingIOError:
                continue
            except OSError:
                break
            buf += chunk
            if token and token in buf:
                break
    return buf


def main():
    args = sys.argv[1:]
    wait, timeout, log = 0, 20, None
    while args and args[0].startswith("--"):
        if args[0] == "--wait":
            wait = int(args[1])
        elif args[0] == "--timeout":
            timeout = int(args[1])
        elif args[0] == "--log":
            log = args[1]
        else:
            break
        args = args[2:]
    deadline = time.time() + max(wait, 1)
    port, fd = open_port(deadline)
    if fd is None:
        print("NO_SERIAL_PORT")
        return 2
    print("PORT", port)
    alive = False
    while time.time() < deadline + 5:
        try:
            os.write(fd, b"echo PING_$((40+2))\r\n")
        except OSError:
            pass
        if b"PING_42" in read_until(fd, b"PING_42", 2):
            alive = True
            break
    if not alive:
        print("SHELL_NOT_ANSWERING")
        return 3
    print("SHELL_ALIVE")
    out = open(log, "ab") if log else None
    for cmd in args:
        k = int(time.time() * 1000) % 1000000
        marker = "__DONE_%d__" % (k + 1)
        os.write(fd, (cmd + "; echo __DONE_$((%d+1))__\r\n" % k).encode())
        buf = read_until(fd, (marker + "\r\n").encode(), timeout)
        sys.stdout.write(buf.decode("utf-8", "replace"))
        sys.stdout.flush()
        if out:
            out.write(buf)
    if out:
        out.close()
    os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main())
