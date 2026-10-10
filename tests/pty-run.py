#!/usr/bin/env python3
"""Run a command under a pty so its \r-animated progress bar output is
captured, and print everything it wrote. This is how the ingot gate proves
the pacman-style download bar renders: a plain pipe would never see it.

Usage: pty-run.py CMD [ARGS...]
"""
import fcntl
import os
import pty
import select
import subprocess
import sys
import time

cmd = sys.argv[1:]
master, slave = pty.openpty()
p = subprocess.Popen(cmd, stdin=slave, stdout=slave, stderr=slave, close_fds=True)
os.close(slave)
fcntl.fcntl(master, fcntl.F_SETFL, os.O_NONBLOCK)

out = b""
deadline = time.time() + 60
last_alive = time.time()
while time.time() < deadline:
    if p.poll() is not None:
        if time.time() - last_alive > 0.1:
            break
    else:
        last_alive = time.time()
    try:
        chunk = os.read(master, 65536)
    except (BlockingIOError, InterruptedError):
        time.sleep(0.05)
        continue
    except OSError:
        break
    if not chunk:
        time.sleep(0.05)
        continue
    out += chunk

try:
    p.kill()
except OSError:
    pass
try:
    p.wait(timeout=5)
except subprocess.TimeoutExpired:
    pass
sys.stdout.buffer.write(out)