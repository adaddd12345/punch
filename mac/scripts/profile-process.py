#!/usr/bin/env python3
"""Bounded, read-only macOS process sampling. Never launches/signals the target.

Uses the public SDK's libproc rusage_info_v4 layout. CPU times are Mach ticks,
converted with mach_timebase_info (not assumed to be nanoseconds). CPU percent
uses 100% for one fully occupied core. Wakeups are counters, not energy/watts.
"""
import argparse
import ctypes as C
import csv
import datetime
import json
import math
import os
from pathlib import Path
import platform
import signal
import sys
import time

RUSAGE_FIELDS = """user_time system_time pkg_idle_wkups interrupt_wkups pageins
wired_size resident_size phys_footprint proc_start_abstime proc_exit_abstime
child_user_time child_system_time child_pkg_idle_wkups child_interrupt_wkups
child_pageins child_elapsed_abstime diskio_bytesread diskio_byteswritten
cpu_time_qos_default cpu_time_qos_maintenance cpu_time_qos_background
cpu_time_qos_utility cpu_time_qos_legacy cpu_time_qos_user_initiated
cpu_time_qos_user_interactive billed_system_time serviced_system_time
logical_writes lifetime_max_phys_footprint instructions cycles billed_energy
serviced_energy interval_max_phys_footprint runnable_time""".split()


class RUsage(C.Structure):
    _fields_ = [("uuid", C.c_ubyte * 16)] + [(name, C.c_uint64) for name in RUSAGE_FIELDS]


class Timebase(C.Structure):
    _fields_ = [("numer", C.c_uint32), ("denom", C.c_uint32)]


class Reader:
    def __init__(self, pid):
        self.pid = pid
        self.lib = C.CDLL("/usr/lib/libproc.dylib", use_errno=True)
        self.lib.proc_pid_rusage.argtypes = [C.c_int, C.c_int, C.c_void_p]
        self.lib.proc_pid_rusage.restype = C.c_int
        self.lib.proc_pidpath.argtypes = [C.c_int, C.c_void_p, C.c_uint32]
        self.lib.proc_pidpath.restype = C.c_int
        system = C.CDLL("/usr/lib/libSystem.B.dylib")
        system.mach_timebase_info.argtypes = [C.POINTER(Timebase)]
        base = Timebase()
        if system.mach_timebase_info(C.byref(base)) != 0 or not base.denom:
            raise RuntimeError("Cannot read Mach timebase")
        self.seconds_per_tick = base.numer / base.denom / 1e9

    def path(self):
        buf = C.create_string_buffer(4096)
        if self.lib.proc_pidpath(self.pid, buf, len(buf)) <= 0:
            raise OSError(C.get_errno(), "Cannot read target executable path")
        return os.fsdecode(buf.value)

    def read(self):
        info = RUsage()
        if self.lib.proc_pid_rusage(self.pid, 4, C.byref(info)) != 0:
            raise OSError(C.get_errno(), "proc_pid_rusage failed")
        result = {key: getattr(info, key) for key in RUSAGE_FIELDS}
        result["uuid"] = bytes(info.uuid).hex()
        result["monotonic"] = time.monotonic()
        return result


def identity(row):
    return row["proc_start_abstime"], row["uuid"]


def interval(previous, current, seconds_per_tick):
    if identity(previous) != identity(current):
        raise RuntimeError("PID was reused or executable changed; refusing mixed-process samples")
    elapsed = current["monotonic"] - previous["monotonic"]
    if elapsed <= 0:
        raise RuntimeError("Nonpositive sample interval")
    def delta(key):
        value = current[key] - previous[key]
        if value < 0:
            raise RuntimeError(f"Counter moved backwards: {key}")
        return value
    cpu = (delta("user_time") + delta("system_time")) * seconds_per_tick
    return {
        "interval_seconds": elapsed, "cpu_percent_one_core": cpu / elapsed * 100,
        "rss_bytes": current["resident_size"], "footprint_bytes": current["phys_footprint"],
        "interrupt_wakeups_per_second": delta("interrupt_wkups") / elapsed,
        "package_idle_wakeups_per_second": delta("pkg_idle_wkups") / elapsed,
        "disk_read_bytes": delta("diskio_bytesread"),
        "disk_write_bytes": delta("diskio_byteswritten"),
        "pageins": delta("pageins"), "instructions": delta("instructions"),
        "cycles": delta("cycles"),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--duration", type=float, default=30)
    parser.add_argument("--interval", type=float, default=1)
    parser.add_argument("--label", required=True, help="Human description of controlled workload")
    parser.add_argument("--output", type=Path, required=True, help="New directory; existing paths rejected")
    parser.add_argument("--expect-path", help="Require this exact executable path")
    args = parser.parse_args()
    if args.pid <= 0 or args.pid > 2_147_483_647:
        parser.error("PID must be a positive 32-bit integer")
    if not math.isfinite(args.duration) or not 1 <= args.duration <= 600:
        parser.error("duration must be finite and between 1 and 600 seconds")
    if not math.isfinite(args.interval) or not .1 <= args.interval <= min(60, args.duration):
        parser.error("interval must be finite and between 0.1 and min(60, duration) seconds")
    if platform.system() != "Darwin":
        parser.error("This sampler requires macOS")
    reader = Reader(args.pid)
    first = reader.read()
    path = reader.path()
    if args.expect_path and path != args.expect_path:
        parser.error(f"Target path mismatch: {path}")
    if first["proc_exit_abstime"]:
        parser.error("Target has already exited")
    # A second identity read closes the initial read/path lookup race.
    if identity(reader.read()) != identity(first):
        parser.error("Target changed while validating identity")
    args.output.mkdir(parents=True, exist_ok=False)
    metadata = {"pid": args.pid, "path": path, "label": args.label,
                "executable_uuid": first["uuid"], "process_start_mach_ticks": first["proc_start_abstime"],
                "started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "requested_seconds": args.duration, "interval_seconds": args.interval,
                "macos": platform.mac_ver()[0], "machine": platform.machine(),
                "seconds_per_mach_tick": reader.seconds_per_tick,
                "notes": "Read-only target-process counters; excludes helper processes. Wakeups are not watts. Zero counters may be unsupported. No GPU/frame-time measurement."}
    (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    rows, status, error = [], "complete", None
    start, previous = first["monotonic"], first
    def stop(signum, frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    with (args.output / "raw.jsonl").open("w") as raw:
        raw.write(json.dumps(first) + "\n")
        raw.flush()
        try:
            tick = 1
            while previous["monotonic"] - start < args.duration:
                deadline = start + min(args.duration, tick * args.interval)
                time.sleep(max(0, deadline - time.monotonic()))
                current = reader.read()
                if current["proc_exit_abstime"]:
                    raise RuntimeError("Target exited during measurement")
                derived = interval(previous, current, reader.seconds_per_tick)
                derived["elapsed_seconds"] = current["monotonic"] - start
                rows.append(derived)
                raw.write(json.dumps(current) + "\n")
                raw.flush()
                previous = current
                tick = max(tick + 1, int((time.monotonic() - start) / args.interval) + 1)
        except KeyboardInterrupt:
            status = "interrupted"
        except (OSError, RuntimeError) as exc:
            status, error = "failed", str(exc)
    if rows:
        with (args.output / "samples.csv").open("w", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]))
            writer.writeheader()
            writer.writerows(rows)
        total = interval(first, previous, reader.seconds_per_tick)
        summary = {"status": status, "error": error, "sample_count": len(rows), **total,
                   "peak_rss_bytes": max(first["resident_size"], *(r["rss_bytes"] for r in rows)),
                   "peak_footprint_bytes": max(first["phys_footprint"], *(r["footprint_bytes"] for r in rows)),
                   "peak_interval_cpu_percent": max(r["cpu_percent_one_core"] for r in rows)}
    else:
        summary = {"status": status, "error": error, "sample_count": 0}
    (args.output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({"output": str(args.output), **summary}, indent=2))
    return 0 if status == "complete" else 130 if status == "interrupted" else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError) as exc:
        sys.exit(f"Profile failed: {exc}")
