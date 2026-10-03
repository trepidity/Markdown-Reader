#!/usr/bin/env python3
"""Poll current macOS physical footprint for a reader and its parser children.

Start before opening a file through the native UI. This measures simultaneous
footprints, not a sum of unrelated historical peaks. Sampling can miss spikes
between observations. Does not drive the UI or force garbage collection.
"""
import argparse
import csv
import ctypes as c
import json
from pathlib import Path
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
    parser.add_argument("--include-new-webkit", action="store_true", help="Include newly appearing WebKit XPC helpers; run without launching unrelated WebKit apps")
    args = parser.parse_args()
    lib = c.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    lib.proc_pid_rusage.argtypes = [c.c_int, c.c_int, c.c_void_p]
    lib.proc_listchildpids.argtypes = [c.c_int, c.c_void_p, c.c_int]
    lib.proc_listallpids.argtypes = [c.c_void_p, c.c_int]
    lib.proc_pidpath.argtypes = [c.c_int, c.c_void_p, c.c_uint32]

    def all_pids():
        values = (c.c_int * 32768)()
        count = lib.proc_listallpids(values, c.sizeof(values))
        return set(list(values)[:max(0, min(count, 32768))]) - {0}

    def name(pid):
        path = c.create_string_buffer(4096)
        if lib.proc_pidpath(pid, path, len(path)) <= 0:
            return ""
        return Path(path.value.decode(errors="replace")).name

    baseline = all_pids() if args.include_new_webkit else set()
    discovered = {}
    baseline_webkit = {pid: name(pid) for pid in baseline if name(pid).startswith("com.apple.WebKit.")}
    Path(args.output + ".context.json").write_text(json.dumps(dict(
        reader_pid=args.pid, started_epoch_seconds=time.time(), baseline_webkit=baseline_webkit,
        include_new_webkit=args.include_new_webkit,
        attribution="Recursive reader descendants plus, when enabled, WebKit processes absent at capture start; verify no unrelated WebKit app launches during capture."), indent=2)+"\n")

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
        writer.writerow(["elapsed_seconds", "epoch_seconds", "reader_bytes", "helpers_bytes", "helper_pids", "total_bytes", "helper_names"])
        while time.monotonic() - start < args.seconds:
            main_bytes = footprint(args.pid)
            if main_bytes is None:
                break
            pending, pids = [args.pid], set()
            while pending:
                children = (c.c_int * 64)()
                length = lib.proc_listchildpids(pending.pop(), children, c.sizeof(children))
                # Unlike proc_listpids, proc_listchildpids returns a PID count.
                for pid in list(children)[:max(0, min(length, 64))]:
                    if pid > 0 and pid not in pids and pid != args.pid:
                        pids.add(pid)
                        pending.append(pid)
            if args.include_new_webkit:
                current = all_pids()
                for pid in current - baseline - discovered.keys():
                    discovered[pid] = name(pid)
                pids.update(pid for pid in current if discovered.get(pid, "").startswith("com.apple.WebKit."))
            readings = [(pid, footprint(pid)) for pid in pids if pid > 0]
            live = [(pid, value) for pid, value in readings if value is not None]
            helper_bytes = sum(value for _, value in live)
            total = main_bytes + helper_bytes
            writer.writerow([round(time.monotonic()-start, 4), round(time.time(), 4), main_bytes, helper_bytes, ";".join(str(pid) for pid, _ in live), total, ";".join(f"{pid}:{discovered.get(pid) or name(pid)}" for pid, _ in live)])
            f.flush()
            peak = max(peak, total)
            observations += 1
            helper_observations += bool(live)
            time.sleep(.02)
    print(f"Observed peak {peak / 2**20:.2f} MiB; {observations} observations; {helper_observations} with parser children")


if __name__ == "__main__":
    main()
