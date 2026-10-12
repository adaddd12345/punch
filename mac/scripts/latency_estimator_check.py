#!/usr/bin/env python3
"""Checks the Latency Lab delay estimator maths without a Mac.

This mirrors mac/Sources/BassShake/LatencyLab.swift line for line. It covers
the log chirp, the dftLength rule, FFT cross-correlation on zero-padded
complex DFTs, parabolic peak refinement, the peak-to-sidelobe ratio, and the
"latency = (lag - residual) / rate" step that turns host times into frames.
It simulates echoes at known fractional delays, adds the neighbouring
opposite-direction chirp and noise, flips polarity, and asserts the
estimate is within 0.1 samples.

    python3 mac/scripts/latency_estimator_check.py      (needs numpy)
"""
import math
import sys

import numpy as np

LOW, HIGH, DUR, FADE, LEVEL = 700.0, 5000.0, 0.08, 0.005, -18.0
MAX_LATENCY, INTERVAL, MIN_PSR_DB = 0.95, 0.5, 8.0


def log_chirp(sr, up):
    count = int(round(DUR * sr))
    f0, f1 = (LOW, HIGH) if up else (HIGH, LOW)
    k = math.log(f1 / f0)
    amp = 10 ** (LEVEL / 20)
    fade = max(1, int(FADE * sr))
    out = np.empty(count, dtype=np.float32)
    for i in range(count):
        t = i / sr
        phase = 2 * math.pi * f0 * DUR / k * (math.exp(t / DUR * k) - 1)
        w = 1.0
        if i < fade:
            w = 0.5 - 0.5 * math.cos(math.pi * i / fade)
        tail = count - 1 - i
        if tail < fade:
            w = 0.5 - 0.5 * math.cos(math.pi * tail / fade)
        out[i] = amp * w * math.sin(phase)
    return out


def dft_length(minimum):
    best = sys.maxsize
    for f in (1, 3, 5, 15):
        p = 8
        while f * p < minimum:
            p *= 2
        best = min(best, f * p)
    return best


def correlate(x, r, max_lag):
    n = dft_length(max(len(x), len(r) + 8))
    assert max_lag + len(r) <= n
    X = np.fft.fft(np.pad(x, (0, n - len(x))).astype(np.complex64))
    R = np.fft.fft(np.pad(r, (0, n - len(r))).astype(np.complex64))
    c = np.fft.ifft(X * np.conj(R)).real  # numpy's ifft already divides by n
    return c[: max_lag + 1]


def pick_peak(c, exclusion):
    a = np.abs(c)
    best = int(np.argmax(a))
    y0 = a[best]
    ym = a[best - 1] if best > 0 else y0
    yp = a[best + 1] if best < len(a) - 1 else y0
    den = ym - 2 * y0 + yp
    delta = 0.5 * (ym - yp) / den if den != 0 else 0.0
    delta = min(0.5, max(-0.5, delta))
    idx = np.arange(len(a))
    side = a[np.abs(idx - best) > exclusion].max()
    psr_db = 20 * math.log10(y0 / side) if side > 0 else 99.0
    return best + delta, psr_db


def delayed(sig, delay, total):
    """`sig` delayed by a fractional number of samples (band-limited shift)."""
    n = 1 << int(math.ceil(math.log2(total * 2)))
    x = np.zeros(n)
    x[: len(sig)] = sig
    f = np.fft.fftfreq(n)
    return np.fft.ifft(np.fft.fft(x) * np.exp(-2j * math.pi * f * delay)).real[:total]


def main():
    rng = np.random.default_rng(7)
    failures = 0
    for sr in (44_100.0, 48_000.0, 96_000.0):
        up = log_chirp(sr, True)
        max_lag = int(MAX_LATENCY * sr)
        window = max_lag + len(up)
        excl = int(0.002 * sr)
        for true_ms in (3.7, 41.2, 187.55, 312.9, 640.0, 930.1):
            # The play time lands `residual` frames after the window start.
            residual = rng.uniform(0, 1)
            echo_at = residual + true_ms / 1000 * sr
            gain = rng.uniform(0.05, 0.5) * rng.choice([-1, 1])
            x = gain * delayed(up, echo_at, window)
            # Next chirp (down-sweep) 0.5 s later, if it falls in the window.
            nxt = echo_at + INTERVAL * sr
            if nxt < window:
                x += 0.8 * gain * delayed(log_chirp(sr, False), nxt, window)
            x += 0.004 * rng.standard_normal(window)
            lag, psr = pick_peak(correlate(x.astype(np.float32), up, max_lag), excl)
            est_ms = (lag - residual) / sr * 1000
            err = abs(est_ms - true_ms) * sr / 1000
            ok = err < 0.1 and psr >= MIN_PSR_DB
            failures += not ok
            print(f"{'ok  ' if ok else 'FAIL'} {sr/1000:5.1f} kHz  true {true_ms:7.2f} ms  "
                  f"est {est_ms:8.3f} ms  err {err:.3f} smp  PSR {psr:4.1f} dB")
    # Pure noise must not pass the confidence gate.
    sr = 48_000.0
    up = log_chirp(sr, True)
    max_lag = int(MAX_LATENCY * sr)
    noise = rng.standard_normal(max_lag + len(up)).astype(np.float32) * 0.01
    _, psr = pick_peak(correlate(noise, up, max_lag), int(0.002 * sr))
    noise_ok = psr < MIN_PSR_DB
    failures += not noise_ok
    print(f"{'ok  ' if noise_ok else 'FAIL'} noise only: PSR {psr:.1f} dB (gate {MIN_PSR_DB} dB)")
    print("all good" if failures == 0 else f"{failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
