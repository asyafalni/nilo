#!/usr/bin/env python3
"""Does a save the build never reads restart the server? It must not.

`zig build dev` watches the binary and nothing else (ADR 0259): the build
system reacts to the files the compiler read to make it, and `nilo-dev`
restarts the server when the file it writes changes. So in a repository
holding a front end beside its server, a save under the front end moves
nothing, and a save to any `.zig` the binary is built from rebuilds and
restarts it. This is the check that it stays that way, the way `shutdown.py`
is ADR 0098's and `burst.py` is ADR 0271's.

    python3 bench/devloop.py --step dev-spa \\
        --outside examples/spa/public/app.js --inside examples/spa/main.zig

    python3 bench/devloop.py --step dev-spa -Dtarget=x86_64-linux-gnu ...  # on a GCC 16 glibc

Before the loop starts it appends a comment to `--inside`, so the binary in
`zig-out` is older than its sources, and checks that the server the loop
starts is the one those sources describe: one start and no restart after it.
The binary left over from the last run must never be served, because it can
do things the new one would not, like seed a database with the old schema.

It starts the step, waits for the server, then appends a line to `--outside`
and watches for `--quiet` seconds: a restart is the failure, and a build step
that ran is reported, because a `build.zig` that installs the front end's
directory copies it on a save there without touching the binary. Then it
appends a comment to `--inside` and waits up to `--patience` seconds for the
restart that must come. Both files are put back byte for byte, whatever
happened, and the loop is stopped the way Ctrl-C would.

`--cmd` replaces the whole `zig build <step>` line for a dependent's own
loop. `-D` options go to both `zig build`s, the outer one and the one
`nilo-dev` keeps running.
"""

import argparse
import os
import signal
import subprocess
import sys
import threading
import time

STARTED = "nilo-dev: started"
RESTARTED = "changed; restarted"
BUILT = "Build Summary:"


class Loop:
    """The dev loop as a child in a session of its own, its output kept."""

    def __init__(self, argv, verbose):
        self.lines = []
        self.verbose = verbose
        self.child = subprocess.Popen(
            argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            start_new_session=True,
        )
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        for line in self.child.stdout:
            self.lines.append(line.rstrip("\n"))
            if self.verbose:
                print("    | " + line, end="", flush=True)

    def seen(self, needle, since=0):
        """Whether a line holding `needle` arrived at index `since` or later."""
        return any(needle in line for line in self.lines[since:])

    def wait_for(self, needle, seconds, since=0):
        """True once such a line arrives, False after `seconds` without one."""
        deadline = time.time() + seconds
        while time.time() < deadline:
            if self.seen(needle, since):
                return True
            if self.child.poll() is not None:
                return False
            time.sleep(0.2)
        return False

    def quiet_for(self, seconds, timeout):
        """Wait until no build and no restart has been seen for `seconds`."""
        deadline = time.time() + timeout
        mark = len(self.lines)
        last = time.time()
        while time.time() < deadline:
            if self.seen(BUILT, mark) or self.seen(RESTARTED, mark):
                mark = len(self.lines)
                last = time.time()
            elif time.time() - last >= seconds:
                return True
            time.sleep(0.2)
        return False

    def stop(self):
        """Ctrl-C: SIGINT to the session, which nilo-dev answers by draining
        its server and stopping its build; SIGKILL if that takes too long."""
        if self.child.poll() is None:
            os.killpg(self.child.pid, signal.SIGINT)
            deadline = time.time() + 15
            while self.child.poll() is None and time.time() < deadline:
                time.sleep(0.2)
            if self.child.poll() is None:
                os.killpg(self.child.pid, signal.SIGKILL)
                self.child.wait()
        self.reader.join(timeout=5)


class Probe:
    """One file with a line appended, and the bytes to put it back."""

    def __init__(self, path, tail):
        self.path = path
        self.tail = tail
        with open(path, "rb") as f:
            self.original = f.read()

    def touch(self):
        with open(self.path, "ab") as f:
            f.write(self.tail)

    def restore(self):
        with open(self.path, "wb") as f:
            f.write(self.original)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--step", default="dev-spa", help="the build step that runs nilo-dev")
    p.add_argument("--cmd", help="the whole command instead, for a dependent's loop")
    p.add_argument("--outside", default="examples/spa/public/app.js", help="a file the build never reads")
    p.add_argument("--inside", default="examples/spa/main.zig", help="a .zig file the binary is built from")
    p.add_argument("--quiet", type=float, default=10.0, help="seconds a save outside must leave the loop alone")
    p.add_argument("--patience", type=float, default=180.0, help="seconds to wait for a start or a restart")
    p.add_argument("--settle", type=float, default=6.0, help="seconds of no build before the first probe")
    p.add_argument("--verbose", action="store_true", help="print the loop's own output as it comes")
    args, extra = p.parse_known_args()
    options = [a for a in extra if a.startswith("-D")]
    if len(options) != len(extra):
        p.error("unknown arguments: " + " ".join(a for a in extra if not a.startswith("-D")))

    if args.cmd:
        argv = args.cmd.split()
    else:
        argv = ["zig", "build", args.step, *options, "--", *options]

    outside = Probe(args.outside, b"\n")
    inside = Probe(args.inside, b"\n// devloop probe\n")
    failures = []
    stale = Probe(args.inside, b"\n// devloop stale binary\n")
    stale.touch()
    print(f"saved {args.inside} with the loop stopped, so zig-out is stale")
    print(f"running `{' '.join(argv)}`")
    loop = Loop(argv, args.verbose)
    try:
        if not loop.wait_for(STARTED, args.patience):
            print("\n".join(loop.lines[-20:]))
            sys.exit(f"the server never started within {args.patience:.0f}s")
        if not loop.quiet_for(args.settle, args.patience):
            sys.exit("the loop never went quiet after starting")
        if loop.seen(RESTARTED):
            failures.append("the loop served the stale binary first, then restarted into the new one")
            print("  RESTARTED: the first server was the binary left over from the last run")
        else:
            print(f"started once, from the sources as saved; quiet for {args.settle:.0f}s")
        mark = len(loop.lines)
        stale.restore()
        if not loop.wait_for(RESTARTED, args.patience, mark):
            failures.append(f"putting {args.inside} back did not restart the server")
        if not loop.quiet_for(args.settle, args.patience):
            sys.exit("the loop never went quiet after the put-back")

        mark = len(loop.lines)
        outside.touch()
        print(f"saved {args.outside}; watching {args.quiet:.0f}s")
        time.sleep(args.quiet)
        built = sum(1 for line in loop.lines[mark:] if BUILT in line)
        if loop.seen(RESTARTED, mark):
            failures.append(f"a save to {args.outside} restarted the server")
            print("  RESTARTED: the loop reacted to a file the build does not read")
        elif built:
            print(f"  the build ran {built} time(s) and the server stayed up: a step in build.zig reads it, the binary did not change")
        else:
            print("  nothing moved")
        outside.restore()
        time.sleep(1.0)

        mark = len(loop.lines)
        inside.touch()
        t0 = time.time()
        print(f"saved {args.inside}; waiting for the restart")
        if loop.wait_for(RESTARTED, args.patience, mark):
            print(f"  restarted after {time.time() - t0:.1f}s")
        else:
            failures.append(f"a save to {args.inside} did not restart the server in {args.patience:.0f}s")
            print("  NO RESTART")
            print("\n".join(loop.lines[mark:][-20:]))
        mark = len(loop.lines)
        inside.restore()
        # The put-back is a save too; let its build land, so the binary on
        # disk is the one the sources describe.
        loop.wait_for(RESTARTED, args.patience, mark)
    finally:
        stale.restore()
        outside.restore()
        inside.restore()
        loop.stop()

    for f in failures:
        print("FAIL: " + f)
    print("ok: the first server is the current one; a save the build does not read leaves it alone; a save it reads restarts it" if not failures else f"{len(failures)} failure(s)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
