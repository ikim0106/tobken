#!/usr/bin/env python3
"""Sample macOS process CPU, physical footprint, wakeups and disk I/O.

Reads kernel counters only. Run release apps with menus closed, let startup
settle, and pass both PIDs to compare under the same machine load. The read
order alternates each round. This does not verify accounting correctness;
run --verify separately. CPU percent uses one core as 100%.
"""

import argparse
import ctypes
import json
import os
import statistics
import sys
import time


class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (field, ctypes.c_uint64)
        for field in (
            "user_time", "system_time", "idle_wakeups", "interrupt_wakeups",
            "pageins", "wired_size", "resident_size", "footprint",
            "start_time", "exit_time", "child_user_time", "child_system_time",
            "child_idle_wakeups", "child_interrupt_wakeups", "child_pageins",
            "child_elapsed_time", "disk_read", "disk_written",
        )
    ]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pid", type=int, nargs="+")
    parser.add_argument("--seconds", type=float, default=10)
    parser.add_argument("--rounds", type=int, default=5)
    args = parser.parse_args()
    if sys.platform != "darwin" or not 0 < args.seconds <= 60 or args.rounds < 1:
        parser.error("requires macOS, 0 < seconds <= 60, and rounds >= 1")

    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
    libproc.proc_pid_rusage.restype = ctypes.c_int

    def read(pid):
        value = Usage()
        if libproc.proc_pid_rusage(pid, 2, ctypes.byref(value)) != 0:
            raise OSError(ctypes.get_errno(), f"proc_pid_rusage failed for {pid}")
        if value.exit_time:
            raise RuntimeError(f"process {pid} exited")
        return time.monotonic_ns(), value

    report = {"logical_cpus": os.cpu_count(), "load": os.getloadavg(), "samples": []}
    for round_index in range(args.rounds):
        order = args.pid if round_index % 2 == 0 else list(reversed(args.pid))
        before = {pid: read(pid) for pid in order}
        time.sleep(args.seconds)
        for pid in order:
            end, value = read(pid)
            start, previous = before[pid]
            if value.start_time != previous.start_time:
                raise RuntimeError(f"process {pid} was replaced")
            elapsed_ns = end - start
            report["samples"].append({
                "pid": pid, "round": round_index + 1,
                "seconds": elapsed_ns / 1e9,
                "cpu_percent": 100 * (
                    value.user_time + value.system_time
                    - previous.user_time - previous.system_time
                ) / elapsed_ns,
                "footprint_mib": value.footprint / 2**20,
                "idle_wakeups_per_second": (
                    value.idle_wakeups - previous.idle_wakeups
                ) * 1e9 / elapsed_ns,
                "disk_read_bytes": value.disk_read - previous.disk_read,
                "disk_written_bytes": value.disk_written - previous.disk_written,
            })
    report["summary"] = {}
    for pid in args.pid:
        samples = [row for row in report["samples"] if row["pid"] == pid]
        report["summary"][pid] = {}
        for metric in ("cpu_percent", "footprint_mib", "idle_wakeups_per_second"):
            values = [row[metric] for row in samples]
            report["summary"][pid][metric] = {
                "median": statistics.median(values), "min": min(values), "max": max(values)
            }
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
