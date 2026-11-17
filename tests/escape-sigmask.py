#!/usr/bin/env python3
"""Run a command from hpnssh's ~C command line and print the signals blocked in the process it starts.

usage: tests/escape-sigmask.py <out-file> <hpnssh command and arguments...>

The client is run on a pseudo terminal. The command line is entered with ~C and "!cmd" (PermitLocalCommand and
EnableEscapeCommandline must be on), and cmd writes the SigBlk line of /proc/self/status to <out-file>. Linux only.
The client loop blocks HUP, INT, QUIT and TERM, and a child must not inherit that.
"""
import os, pty, select, sys, time

out, argv = sys.argv[1], sys.argv[2:]
pid, fd = pty.fork()
if pid == 0:
    os.execv(argv[0], argv)

def read_until(text, timeout=10):
    buf = b""
    end = time.time() + timeout
    while text not in buf and time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            try:
                data = os.read(fd, 4096)
            except OSError:
                break
            if not data:
                break
            buf += data
    return buf

read_until(b"ready", 15)
os.write(fd, b"\r")
time.sleep(0.3)
os.write(fd, b"~C")
got = read_until(b"ssh>")
if b"ssh>" not in got:
    print(got, file=sys.stderr)
    print("no ssh> prompt", file=sys.stderr)
    sys.exit(1)
os.write(fd, ("!grep SigBlk /proc/self/status > %s\r" % out).encode())
time.sleep(1)
os.write(fd, b"\r~.")
read_until(b"closed", 5)
try:
    os.waitpid(pid, 0)
except ChildProcessError:
    pass
sys.exit(0 if os.path.exists(out) else 1)
