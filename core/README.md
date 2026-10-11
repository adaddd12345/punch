# punch_core — real-time DSP engine

Portable C++20 library that runs inside the Core Audio IOProc. It has no
platform dependencies, so it builds and is fully tested on Linux CI as well
as macOS. The Swift app links it through `include/punch/punch_c.h`.

```
in → EQ (auto-headroom preamp, ≤24 bands) → bass enhancer → stereo width
   → crossfeed → output gain ("boost") → look-ahead limiter → out
```

| Piece | File | Notes |
|---|---|---|
| Filters | `svf.hpp` | Simper/Cytomic trapezoidal SVF. Response is identical to the RBJ cookbook, with an exact analytic magnitude for UI curves. Safe to modulate every sample. |
| Parametric EQ | `parametric_eq.*` | Frequency and Q glide geometrically and gain linearly (~20 ms), with coefficients recomputed every 32 frames while gliding. Enabling or disabling a band fades it in or out. |
| Auto headroom | `Engine::publish` | `preamp = min(user, −peak(EQ response))` on a 1024-point log grid. A full-scale sine can never be pushed over 0 dBFS by the EQ. AutoEq profiles' own preamp is not double-counted. |
| Bass enhancer | `enhancers.*` | Missing-fundamental harmonics from band-limited (<fc, 24 dB/oct) content, so no oversampling is needed. |
| Stereo width | `enhancers.*` | M/S. The side signal is high-passed before boosting, so the low end stays mono-safe. |
| Crossfeed | `enhancers.*` | Bauer-style: low-passed, 0.3 ms delayed cross-mix for headphones. |
| Limiter | `limiter.*` | Sliding-min + release + box-filter gain computer. Output provably ≤ ceiling, 1.5 ms look-ahead. |
| Plumbing | `lockfree.hpp`, `dsp_util.hpp` | Triple buffer for parameter snapshots, SPSC ring for analyzer/meter feeds, FTZ/DAZ guard (ARM FPCR / x86 MXCSR). |
| Profiles | `autoeq.*` | Equalizer APO / AutoEq `ParametricEQ.txt` import and export (PK/LS/HS/LSC/HSC/LP/HP/BP/NO, `BW Oct`). |

Real-time guarantees, all enforced by tests:
- `process*()` never allocates (a counting `operator new` in the tests proves it), never locks, and never makes syscalls.
- NaN or Inf input is detected per block: that block is muted and all filter states are reset, instead of latching silence or noise forever.
- Bypass glides every stage to neutral rather than switching paths. Latency stays constant and the output is click-free.

## Build & test

```sh
cmake -S core -B core/build && cmake --build core/build -j
ctest --test-dir core/build --output-on-failure
core/build/punch_bench                       # CPU cost of the full chain
core/build/punch_render in.wav out.wav --apo profile.txt --bass 0.6 --width 1.3 --gain 6
cmake -S core -B core/build-asan -DPUNCH_SANITIZE=ON -DCMAKE_BUILD_TYPE=Debug   # ASan/UBSan
```

Measured on the Linux x86 CI container: 16-band EQ + bass + width + crossfeed
+ limiter, stereo 48 kHz, 512-frame blocks = **~1.2 % of one core** (126 µs
per 10.7 ms block). Apple Silicon P-cores are expected to be faster but have not
been measured yet.
