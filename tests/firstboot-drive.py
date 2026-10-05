#!/usr/bin/env python3
"""
Drive the real first-boot wizard through a pty and answer every question.

Runs inside a mount namespace where /etc is a copy (see tests/account.sh), so the
account files it writes land somewhere disposable instead of on the build host's
real /etc. That isolation is not optional: the wizard writes /etc/passwd
directly, and on an ordinary CI runner or WSL account that file belongs to root.

Prompt-driven, not timer-driven. A timer-driven version sends an answer every
0.8 seconds regardless of what is on screen, so the first answer lands on the
splash animation and every later one shifts up a field: the run reports
"Your name = copperbox, Username = rootpw1", which looks exactly like a product
bug and is not one. It never reaches account creation, and the assertions then
"pass" against three empty files.

So: wait for the exact prompt, then answer it. The prompts are copied from the
FIELD table in iso/firstboot/copper-firstboot.c, not guessed.

Prints the whole transcript, because when this fails the reason is always in
what was asked and what it said back.
"""
import fcntl
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time

BIN = sys.argv[1]

# (prompt text as it appears on the status line, what to type)
STEPS = [
    ("What should Copper call you?", "Boot Tester"),
    ("Pick a login name",             "bo"),
    ("Name this machine",             "copperbox"),
    ("Set the root password",         "rootpw1"),
    ("Type it once more to be sure",  "rootpw1"),
    ("Set your own password",         "userpw1"),
    ("Type it once more to be sure",  "userpw1"),
    ("Timezone, e.g. Europe/London",  "UTC"),
]

master, slave = pty.openpty()

# 100x30: big enough that the wizard does not have to truncate anything, so a
# layout problem shows up as a prompt problem rather than as a wrapped screen.
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))

pid = os.fork()
if pid == 0:
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    os.dup2(slave, 0)
    os.dup2(slave, 1)
    os.dup2(slave, 2)
    os.close(master)
    os.close(slave)
    os.environ["TERM"] = "xterm"
    os.execv(BIN, [BIN])
    os._exit(127)

os.close(slave)

out = bytearray()
step = 0
search_from = 0
sent_at = 0.0
deadline = time.time() + 120
exited = False

while time.time() < deadline:
    r, _, _ = select.select([master], [], [], 0.2)
    if r:
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        out += chunk

    # Answer only when the prompt we are waiting for has appeared since the last
    # answer, and only once the wizard has been quiet, so a redraw in progress
    # cannot catch the answer mid-flight.
    if step < len(STEPS):
        want, answer = STEPS[step]
        window = out[search_from:].decode("utf-8", "replace")
        # strip escapes so a prompt broken across cursor moves still matches
        flat = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", " ", window)
        if want in flat and time.time() - sent_at > 0.35:
            try:
                os.write(master, answer.encode() + b"\r")
            except OSError:
                break
            step += 1
            search_from = len(out)
            sent_at = time.time()
            continue

    done, _ = os.waitpid(pid, os.WNOHANG)
    if done == pid:
        exited = True
        for _ in range(30):
            r, _, _ = select.select([master], [], [], 0.1)
            if not r:
                break
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
        break

if not exited:
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass

text = out.decode("utf-8", "replace")

print("=== transcript ===")
for line in text.splitlines():
    clean = line.rstrip()
    if clean:
        print(f"  | {clean}")

print()
print(f"=== answered {step} of {len(STEPS)} prompts"
      f"{'' if exited else '  (process still running at timeout)'}")

if step < len(STEPS):
    print(f"=== NEVER SAW: {STEPS[step][0]!r}")
    sys.exit(2)
sys.exit(0)