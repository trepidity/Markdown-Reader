#!/usr/bin/env python3
"""Poll current macOS physical footprint for a reader and its parser children.

Start before opening a file through the native UI. This measures simultaneous
footprints, not a sum of unrelated historical peaks. Sampling can miss spikes
between observations. Does not drive the UI or force garbage collection.
"""
import argparse
import csv
import ctypes as c
import time


class Usage(c.Structure):
    _fields_ = [("uuid", c.c_ubyte * 16)] + [
        (name, c.c_uint64) for name in (
            "user", "system", "idle", "interrupt", "pageins", "wired",
            "resident", "footprint", "start", "exit", "child_user",
            "child_system", "child_idle", "child_interrupt", "child_pageins",
            "child_elapsed", "disk_read", "disk_write")]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pid", type=int)
    parser.add_argument("output")
    parser.add_argument("--seconds", type=float, default=60)
    args = parser.parse_args()
    lib = c.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_pid_rusage.argtypes = [c.c_int, c.c_int, c.c_void_p]
    lib.proc_listchildpids.argtypes = [c.c_int, c.c_void_p, c.c_int]

    def footprint(pid):
        usage = Usage()
        if lib.proc_pid_rusage(pid, 2, c.byref(usage)) != 0:
            return None
        return usage.footprint

    if footprint(args.pid) is None:
        raise SystemExit("Cannot read reader process footprint")
    start = time.monotonic()
    peak = 0
    observations = 0
    helper_observations = 0
    with open(args.output, "w") as f:
        writer = csv.writer(f)
        writer.writerow(["elapsed_seconds", "epoch_seconds", "reader_bytes", "helpers_bytes", "helper_pids", "total_bytes"])
        while time.monotonic() - start < args.seconds:
            main_bytes = footprint(args.pid)
            if main_bytes is None:
                break
            children = (c.c_int * 64)()
            length = lib.proc_listchildpids(args.pid, children, c.sizeof(children))
            # Unlike proc_listpids, proc_listchildpids returns a PID count.
            pids = list(children)[:max(0, min(length, 64))]
            readings = [(pid, footprint(pid)) for pid in pids if pid > 0]
            live = [(pid, value) for pid, value in readings if value is not None]
            helper_bytes = sum(value for _, value in live)
            total = main_bytes + helper_bytes
            writer.writerow([round(time.monotonic()-start, 4), round(time.time(), 4), main_bytes, helper_bytes, ";".join(str(pid) for pid, _ in live), total])
            f.flush()
            peak = max(peak, total)
            observations += 1
            helper_observations += bool(live)
            time.sleep(.02)
    print(f"Observed peak {peak / 2**20:.2f} MiB; {observations} observations; {helper_observations} with parser children")


if __name__ == "__main__":
    main()
