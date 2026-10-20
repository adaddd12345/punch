#!/usr/bin/env python3
"""Validate units, PID identity checks, bounded input, and owned-child cleanup."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT = Path(__file__).with_name("profile-process.py")
spec = importlib.util.spec_from_file_location("profile_process", SCRIPT)
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


class ProfileCheck(unittest.TestCase):
    def sample(self, **values):
        row = dict.fromkeys(profile.RUSAGE_FIELDS, 0)
        row.update(uuid="fixture", proc_start_abstime=42, monotonic=1)
        row.update(values)
        return row

    def test_mach_units_and_rates(self):
        a = self.sample()
        b = self.sample(monotonic=3, user_time=24_000_000, system_time=12_000_000,
                        interrupt_wkups=20, pkg_idle_wkups=4, resident_size=100,
                        phys_footprint=80, diskio_byteswritten=12)
        result = profile.interval(a, b, 1 / 24_000_000)
        self.assertAlmostEqual(result["cpu_percent_one_core"], 75)
        self.assertEqual(result["interrupt_wakeups_per_second"], 10)
        self.assertEqual(result["package_idle_wakeups_per_second"], 2)
        self.assertEqual(result["disk_write_bytes"], 12)

    def test_reused_pid_and_reset_counters_fail(self):
        a = self.sample(user_time=100)
        for b in [self.sample(monotonic=2, proc_start_abstime=43),
                  self.sample(monotonic=2, uuid="new-executable"),
                  self.sample(monotonic=2, user_time=50)]:
            with self.assertRaises(RuntimeError):
                profile.interval(a, b, 1)

    def test_live_cpu_time_units(self):
        reader = profile.Reader(os.getpid())
        before, begin = reader.read(), time.process_time()
        while time.process_time() - begin < .05:
            pass
        cpu = time.process_time() - begin
        after = reader.read()
        measured = ((after["user_time"] + after["system_time"])
                    - (before["user_time"] + before["system_time"])) * reader.seconds_per_tick
        self.assertAlmostEqual(measured, cpu, delta=.02)

    def test_invalid_inputs_never_create_output(self):
        with tempfile.TemporaryDirectory(prefix="punch-profile-check-") as tmp:
            output = Path(tmp) / "output"
            for flag, value in [("--pid", "0"), ("--duration", "nan"),
                                ("--duration", "inf"), ("--interval", "0"),
                                ("--duration", "601")]:
                args = [sys.executable, str(SCRIPT), "--pid", str(os.getpid()),
                        "--label", "invalid", "--output", str(output), flag, value]
                result = subprocess.run(args, capture_output=True, timeout=5)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(output.exists())

    def test_target_exit_is_partial_failure(self):
        with tempfile.TemporaryDirectory(prefix="punch-profile-check-") as tmp:
            child = subprocess.Popen([sys.executable, "-c", "import sys; sys.stdin.read()"], stdin=subprocess.PIPE)
            sampler = None
            try:
                output = Path(tmp) / "output"
                sampler = subprocess.Popen([sys.executable, str(SCRIPT), "--pid", str(child.pid),
                                            "--duration", "3", "--interval", ".1", "--label", "owned-child",
                                            "--output", str(output)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                deadline = time.monotonic() + 2
                while not (output / "raw.jsonl").exists() and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue((output / "raw.jsonl").exists())
                time.sleep(.15)
                child.stdin.close()
                child.wait(timeout=2)
                sampler.communicate(timeout=5)
                self.assertNotEqual(sampler.returncode, 0)
                summary = json.loads((Path(tmp) / "output/summary.json").read_text())
                self.assertEqual(summary["status"], "failed")
                self.assertLess(summary["sample_count"], 30)
            finally:
                if sampler:
                    if sampler.poll() is None:
                        sampler.kill()
                    sampler.communicate(timeout=2)
                if child.stdin and not child.stdin.closed:
                    child.stdin.close()
                if child.poll() is None:
                    child.terminate()
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=2)
                self.assertIsNotNone(child.returncode)

    def test_sampler_signal_leaves_target_alive(self):
        original = profile.Reader(os.getpid())
        target_identity, target_path = profile.identity(original.read()), original.path()
        with tempfile.TemporaryDirectory(prefix="punch-profile-check-") as tmp:
            output = Path(tmp) / "output"
            sampler = subprocess.Popen([sys.executable, str(SCRIPT), "--pid", str(os.getpid()),
                                        "--duration", "10", "--interval", ".1", "--label", "signal-check",
                                        "--output", str(output)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 3
                while not (output / "raw.jsonl").exists() and time.monotonic() < deadline:
                    time.sleep(.01)
                self.assertTrue((output / "raw.jsonl").exists())
                time.sleep(.15)
                sampler.terminate()
                sampler.communicate(timeout=3)
                self.assertEqual(sampler.returncode, 130)
                summary = json.loads((output / "summary.json").read_text())
                self.assertEqual(summary["status"], "interrupted")
                self.assertEqual(profile.identity(original.read()), target_identity)
                self.assertEqual(original.path(), target_path)
            finally:
                if sampler.poll() is None:
                    sampler.kill()
                sampler.communicate(timeout=3)


if __name__ == "__main__":
    unittest.main()
