# 04 — DSP Algorithms for a System-Wide macOS Audio Enhancer (State of the Art, Oct 2026)

Author: DSP research pass, 2026-10-11
Scope: EQ, headphone correction, loudness/dynamics, enhancement effects, spatial audio, MacBook speakers, analysis, real-time engineering, ML.
Competitors referenced: Boom 2 / Boom 3D (Global Delight), FxSound (open source since Nov 2023), SoundSource (Rogue Amoeba), DFX.

**Verification legend.** Statements are verified against the cited source unless they carry a tag:
- **[UNVERIFIED]**: from memory or secondary or forum sources that I could not check against a primary source in this pass.
- **[ESTIMATE]**: my own engineering estimate, not a measurement.
- **[FROM MEMORY: FORMULA]**: standard formula written from memory because the primary PDF was unreachable from this sandbox, where DNS failed for w3.org, vicanek.de, cytomic.com and zenodo.org. These formulas are widely reproduced, but check them against the primary source before shipping.

---

## 0. Executive summary

1. **EQ core.** Use RBJ cookbook formulas for coefficient design, with Vicanek matched or Orfanidis Nyquist-gain correction for bands above ~0.25·fs. Run them in a TPT/SVF (Simper) topology in **double precision** so that modulating parameters (sliders, preset morphs) produces no zipper noise. Static, vectorized paths can use vDSP biquads.
2. **Graphic EQ.** Use ISO 10- or 31-band centres with an **interaction-matrix gain solver** (Välimäki & Liski "Accurate Cascade Graphic Equalizer", 2017). This keeps the curve the user drew within about ±1 dB of what they hear. Naïve cascaded peaks overshoot badly.
3. **Headphone correction.** AutoEq (MIT-licensed code) supplies parametric presets per model in a simple `Preamp + Filter N: ON PK Fc … Gain … Q …` format. Ship a compact JSON derived from it. Auto-select it through the CoreAudio transport type plus the device name, falling back to user confirmation.
4. **Loudness.** "Boost" is pre-gain, then a 4×-oversampled **true-peak look-ahead limiter** at −1 dBTP, then a soft-clip safety stage. Auto-leveling and night mode use BS.1770-5 K-weighted short-term loudness with gating and slow gain riding.
5. **Enhancement.** Use psychoacoustic (virtual) bass instead of raw low-end boost, which matters most on MacBook speakers. Use M/S widening, which is mono-safe, instead of Haas delays. Use bs2b crossfeed for headphones. Build "3D" from HRIR virtual speakers using CC-BY or Apache-licensed SOFA data such as HUTUBS or SADIE.
6. **Real time.** Nothing that can block runs on the IO thread. Parameters travel through atomics or SPSC rings, coefficient sets are double-buffered, and every switch crossfades. Nonlinear stages run 2–4× oversampled through polyphase IIR halfbands. Total added latency is about 3–6 ms without the ML stage. CPU use for the full chain should stay well under 5% of one performance core at 48 kHz stereo **[ESTIMATE]**.
7. **ML.** Content classification at ~1 Hz with crossfaded preset switching is cheap and safe. Real-time dialogue separation is feasible at ~20–40 ms latency (HS-TasNet at 23 ms, DeepFilterNet-class models at 20–40 ms) but must run on a worker thread, never inside the IO callback. ANE scheduling is not callback-safe.

---

## 1. Equalization

### 1.1 RBJ Audio EQ Cookbook (W3C Working Group Note, 8 June 2021)

The W3C published Robert Bristow-Johnson's cookbook as a Working Group Note dated **08 June 2021**, adapted with his permission. All of its filters are bilinear-transform (BLT) digitizations of analog prototypes ([W3C TR](https://www.w3.org/TR/audio-eq-cookbook), [mailing-list discussion](https://lists.w3.org/Archives/Public/public-audio/2021AprJun/0038.html)). The legacy W3C copy is at [w3.org/2011/audio/audio-eq-cookbook.html](https://w3.org/2011/audio/audio-eq-cookbook.html).

**Common intermediates [FROM MEMORY: FORMULA, matches the cookbook as widely reproduced]:**

```
A      = 10^(dBgain/40)            // peaking and shelving only
w0     = 2*pi*f0/Fs
cw     = cos(w0),  sw = sin(w0)
alpha  = sw/(2*Q)                                         // Q form
       = sw*sinh( ln(2)/2 * BW * w0/sw )                  // bandwidth in octaves (BLT-compensated)
       = sw/2 * sqrt( (A + 1/A)*(1/S - 1) + 2 )           // shelf-slope form (S = 1: steepest monotonic)
H(z)   = (b0 + b1 z^-1 + b2 z^-2) / (a0 + a1 z^-1 + a2 z^-2)   -> divide all by a0
```

| Type | b0 | b1 | b2 | a0 | a1 | a2 |
|---|---|---|---|---|---|---|
| LPF | (1−cw)/2 | 1−cw | (1−cw)/2 | 1+α | −2cw | 1−α |
| HPF | (1+cw)/2 | −(1+cw) | (1+cw)/2 | 1+α | −2cw | 1−α |
| Peaking | 1+α·A | −2cw | 1−α·A | 1+α/A | −2cw | 1−α/A |
| Low shelf | A[(A+1)−(A−1)cw+2√A·α] | 2A[(A−1)−(A+1)cw] | A[(A+1)−(A−1)cw−2√A·α] | (A+1)+(A−1)cw+2√A·α | −2[(A−1)+(A+1)cw] | (A+1)+(A−1)cw−2√A·α |
| High shelf | A[(A+1)+(A−1)cw+2√A·α] | −2A[(A−1)+(A+1)cw] | A[(A+1)+(A−1)cw−2√A·α] | (A+1)−(A−1)cw+2√A·α | 2[(A−1)−(A+1)cw] | (A+1)−(A−1)cw−2√A·α |

Notes:
- The peaking EQ is symmetric: a cut of −G dB exactly inverts a boost of +G dB. That makes it the natural primitive for graphic EQ and for AutoEq's `PK` filters.
- AutoEq's `LSC`/`HSC` shelves are defined with Q. Use the cookbook Q-form alpha for them, not the S-form.

### 1.2 Bilinear-transform warping near Nyquist, and the fixes

The BLT maps the analog frequency axis onto the digital one through `Ω = (2/T)·tan(ω/2)`. Pre-warping pins the centre frequency f0, but the bandwidth is compressed near Nyquist. Every BLT peaking or shelving filter is also forced to unity gain (0 dB) at exactly fs/2, and some designs force a zero there. A 1/3-octave +6 dB bell at 16 kHz with fs = 44.1/48 kHz is therefore visibly narrower and asymmetric. This matters for the top bands of a 31-band graphic EQ and for AutoEq treble filters.

Two fixes:

1. **Orfanidis, "Digital Parametric Equalizer Design With Prescribed Nyquist-Frequency Gain"** (JAES 45(6):444–455, June 1997). The digital filter is constrained to match the analog prototype's gain at DC, at f0 and **at Nyquist**, instead of 0 dB at Nyquist. Closed-form coefficients exist. MATLAB's `designParamEQ` and community `peq.m` implement the method ([AES e-lib](https://aes2.org/publications/elibrary-page/?id=13397), [MathWorks parametricEqualizerDesign](https://www.mathworks.com/help/audio/ref/parametricequalizerdesign.html), [comp.dsp thread](https://www.dsprelated.com/showthread/comp.dsp/154018-1.php)).
2. **Vicanek, "Matched Second Order Digital Filters"** (14 Feb 2016) ([PDF](https://www.vicanek.de/articles/BiquadFits.pdf)). Poles come from impulse invariance (the matched-Z pole positions). The numerator is solved in closed form so that |H| matches the analog magnitude at DC, at Nyquist and at a third point (f0 for peaking). The formulas are cheap enough to recompute at near audio rate. Outline of the lowpass case **[FROM MEMORY: FORMULA, verify against the PDF]**:

```
zeta = 1/(2Q)
a1 = -2*exp(-zeta*w0)*cos(w0*sqrt(1-zeta^2))  (zeta <= 1; cosh branch otherwise)
a2 = exp(-2*zeta*w0)
phi0 = 1 - sin^2(w/2), phi1 = sin^2(w/2), phi2 = 4*phi0*phi1    // evaluated at the match frequency
A0 = (1+a1+a2)^2, A1 = (1-a1+a2)^2, A2 = -4*a2
... solve B0,B1,B2 from target |H|^2 at the match points; b0,b1,b2 from sqrt(B) terms
```

**Recommendation.** Use RBJ for bands with f0 < fs/8. Use Vicanek (or Orfanidis) for bands at or above fs/8, or for every band. The cost is a handful of `exp`/`cos` calls per coefficient update, which is negligible off the audio thread or at a sub-block update rate. At 96 kHz the warping problem largely disappears for audible bands.

### 1.3 Topology: DF1, TDF2, or TPT state-variable filter

| Topology | Pros | Cons |
|---|---|---|
| **Direct Form I** | Fixed-point friendly, with no internal overflow apart from the accumulator. Tolerates coefficient changes reasonably, because state equals the past inputs and outputs. | 4 state variables per section. In float32, low-frequency/high-Q sections suffer quantization noise and coefficient sensitivity, because poles sit near z = 1. |
| **Transposed DF2** | 2 states, the best float behaviour of the direct forms, and what vDSP_biquad-style code typically uses. | States are not physical signals. Changing coefficients abruptly can cause transients or clicks, and per-sample interpolation of b and a is not guaranteed stable. |
| **TPT / ZDF SVF** (Zavalishin; Simper/Cytomic) | States are integrator "capacitor" values, so they stay meaningful under modulation. Parameters (g, k) can be smoothed per sample with no zipper noise and **no instability**. One structure gives LP, BP, HP, bell and shelves by output mixing. Good numerics at low fc/fs. | Slightly more operations (~3 multiplies more than TDF2). It is not a cookbook coefficient set, so you map RBJ-style parameters (f0, Q, gain) onto g, k and the mix coefficients. |

Sources: Zavalishin, *The Art of VA Filter Design* rev. 2.1.0 (free to copy, unmodified) ([NI PDF](https://www.native-instruments.com/fileadmin/ni_media/downloads/pdf/VAFilterDesign_2.1.0.pdf)). Simper, "SvfLinearTrapOptimised2" (cytomic.com/files/dsp/SvfLinearTrapOptimised2.pdf, cited by [Unreal Engine docs](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/SignalProcessing/FDynamicStateVariableFilter/FSVFCoefficients) and [chowdsp](https://ccrma.stanford.edu/~jatin/chowdsp/chowdsp_utils/classchowdsp_1_1StateVariableFilter.html); the PDF itself could not be fetched here).

**Simper linear-trapezoidal SVF [FROM MEMORY: FORMULA; the coefficient setup g = tan(π·fc/fs), k = 1/Q, a1 = 1/(1+g(g+k)) is confirmed by secondary sources]:**

```
// coefficients
g  = tan(pi*fc/fs);  k = 1/Q
a1 = 1/(1 + g*(g + k));  a2 = g*a1;  a3 = g*a2
// per-sample tick (v0 = input), state ic1eq, ic2eq
v3 = v0 - ic2eq
v1 = a1*ic1eq + a2*v3          // band
v2 = ic2eq + a2*ic1eq + a3*v3  // low
ic1eq = 2*v1 - ic1eq
ic2eq = 2*v2 - ic2eq
out = m0*v0 + m1*v1 + m2*v2
// mixes (A = 10^(dB/40))
LP:    m0=0, m1=0,   m2=1
HP:    m0=1, m1=-k,  m2=-1
Bell:  k = 1/(Q*A);  m0=1, m1=k*(A*A-1), m2=0
LowSh: g = tan(pi*fc/fs)/sqrt(A); m0=1,   m1=k*(A-1),   m2=A*A-1
HighSh:g = tan(pi*fc/fs)*sqrt(A); m0=A*A, m1=k*(1-A)*A, m2=1-A*A
```

**Recommendation.** For any EQ band the user can move, and for preset morphing, use SVF/TPT with per-sample one-pole smoothing of g, k, m0, m1 and m2 (or of f0/Q/gain, recomputing g every 8–32 samples). For static correction stacks such as AutoEq or the speaker curve, cascaded TDF2 in double, or `vDSP_biquadD`/`vDSP_biquadm` (multichannel), is fine. Those coefficients only change on device switch, and the switch is crossfaded (§7.6) ([Apple vDSP_biquad](https://developer.apple.com/documentation/accelerate/vdsp_biquad.md), [vDSP_biquadD](https://developer.apple.com/documentation/accelerate/vdsp_biquadd.md), [vDSP_biquadm](https://developer.apple.com/documentation/accelerate/vdsp_biquadm.md)). vDSP biquad setups take 5 coefficients per section (b0, b1, b2, a1, a2, normalized). The delay array holds 2M+2 values.

### 1.4 Parameter smoothing

- One-pole smoother `y += (target − y)·c` with `c = 1 − exp(−1/(τ·fs))`, τ ≈ 20–50 ms for gains and 30–80 ms for frequencies. Smooth frequency in the **log domain** (smooth log2 f) so sweeps sound even.
- Linear ramps over N samples (vDSP_vrampmul) work for pure gains. They are exact and vectorizable.
- Gains are smoothed in linear amplitude for short ramps and in dB for long (>100 ms) fades.
- With TDF2 biquads, never interpolate raw coefficients over large jumps. Recompute from smoothed parameters per sub-block (e.g. every 32 samples) and limit the per-update change, or crossfade two filter instances.

### 1.5 Graphic EQ: ISO bands, interaction, and the accurate solver

**ISO 266 preferred centres.**
- 10-band, octave: 31.5, 63, 125, 250, 500, 1k, 2k, 4k, 8k, 16k Hz.
- 31-band, 1/3 octave: 20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1k, 1.25k, 1.6k, 2k, 2.5k, 3.15k, 4k, 5k, 6.3k, 8k, 10k, 12.5k, 16k, 20k Hz.
- Boom 3D ships a 31-band "Advanced Equalizer" ([9to5Mac review](https://9to5mac.com/?p=549661), [Hongkiat review](https://www.hongkiat.com/blog/boom3d-mac-review/)).

**The band-interaction problem.** With cascaded peaking filters whose bandwidths overlap enough to give a smooth curve, neighbouring bands add in dB. Raising three adjacent bands by +6 dB gives about +9 to +10 dB in the middle. "Proportional-Q" designs (where Q rises with |gain|, as in analog consoles) reduce the overlap but do not remove it.

**Accurate Cascade Graphic EQ (ACGE)** (Välimäki & Liski, IEEE SPL 24(2):176–180, 2017; extended to 1/3 octave in Liski & Välimäki, "The Quest for the Best Graphic Equalizer", DAFx-17) ([DBLP](https://dblp.uni-trier.de/pid/194/6504.html), [DAFx paper](https://dafx.de/paper-archive/details/Ycir51R86FWcfPNqrjV2kQ)):

```
// offline, once per (fs, band layout)
for each band k: design a peaking filter with prototype gain g_p (e.g. 17 dB) and fixed bandwidth
B[i][k] = |H_k(e^{j w_i})|_dB / g_p      // evaluated at centre AND midpoint frequencies w_i (2K-1 points)
// at runtime when the user moves sliders t (dB, at centre and interpolated midpoints)
g  = pinv(B) * t        // least squares (precomputed pseudo-inverse: a K x (2K-1) matrix-vector product)
// iterate once more: redesign with g (Q depends on gain), recompute B1, g = pinv(B1)*t
```

- The authors report a maximum error under about 1 dB for octave designs. A later third-octave refinement reaches **0.81 dB** maximum error ([Rämö, Liski, Välimäki 2020](https://research.aalto.fi/fi/publications/third-octave-and-bark-graphic-equalizer-design-with-symmetric-ban/)).
- "Neurally Controlled Graphic Equalizer" (IEEE/ACM TASLP 27(12), 2019) replaces the matrix solve with a 20-neuron MLP for a 10-band GEQ ([Aalto PDF](https://acris.aalto.fi/ws/portalfiles/portal/40860405/V_lim_ki_Neurally_Controlle_Graphic_Equalizer.08809819_1.pdf)). It is unnecessary for us, since a 31×61 matrix-vector product is trivial.

**Product guidance.** The slider value should be the gain the user hears. Solve with ACGE on the UI thread, push filter gains to the audio thread, and smooth them. Clamp each slider to ±12 dB. Show the realized composite curve, computed from the actual filters, behind the sliders.

### 1.6 Parametric EQ

Offer N bands (8–10) with types {bell, low/high shelf, LP/HP at 12/24 dB/oct (cascaded Butterworth Q values 0.541 and 1.307 for 4th order), notch}. Use the same SVF engine with matched or Orfanidis correction at high frequencies.

### 1.7 Linear-phase FIR versus minimum phase

- **Minimum-phase IIR**: zero latency and tiny CPU cost. Phase shift is concentrated near the EQ features, which is inaudible for typical consumer EQ. **This is the default.**
- **Linear-phase FIR**: pre-ringing on steep low-frequency boosts, and latency of N/2 samples. A 0.5 Hz-resolution low-frequency EQ needs ~8k–16k taps, which means 85–170 ms at 48 kHz. That is unacceptable for system-wide audio with video (lip sync) and games. Partitioned convolution reduces the computation, but **not** the inherent N/2 group delay.
- **Partitioned convolution** is still needed for HRIR/BRIR (§4.6) and for any long FIR. Uniformly partitioned overlap-save with a frequency-domain delay line (FDL) is the standard. Non-uniform schemes (Gardner 1995, and Garcia 2002 with one FDL per block size) give low latency with long IRs ([CNMAT 2010 survey](https://www.cnmat.berkeley.edu/sites/default/files/attachments/2010_advances-in-the-parallelization-of-music-and-audio.pdf), [Farina/Mohonk 2001](https://angelofarina.it/Public/papers/164-Mohonk2001.PDF)).
- Optional "linear phase" mode: offer it for music-only listening, with a latency warning. Low priority.

### 1.8 Precision: float versus double, and denormals

- **Low-frequency biquads at high fs.** At fs = 96 kHz and f0 = 20 Hz, w0 ≈ 0.0013 rad, so the poles sit within ~1e-3 of z = 1 and a1 ≈ −1.9987. A float32 mantissa (24 bits) gives coefficient quantization and roundoff noise amplified by ~1/(1−|p|)², which produces audible noise, gain error and limit cycles in DF1/TDF2 float. **Use double for coefficients and state**, or use the SVF, whose integrator form has much lower sensitivity. On Apple Silicon NEON, double SIMD is 2-wide versus 4-wide for float. The cost is small for 2 channels × ~30 sections **[ESTIMATE]**.
- **Denormals.** Decaying IIR or reverb tails produce subnormals. On AArch64, set **FPCR.FZ (bit 24)** on the audio thread. With FPCR.AH = 0, FZ flushes subnormal inputs and outputs for single and double precision ([Arm FPCR reference](https://df.lth.se/~getz/ARM/SysReg/AArch64-fpcr.html), [WebKit DenormalDisabler](https://crrev.com/4a8a7ad6155544b087fdedff4bcb4e4a5a35bbd1/third_party/WebKit/Source/platform/audio/DenormalDisabler.h), [Blender aarch64](https://developer.blender.org/rB4b5195a9d75ac1cef101f902c9866e07e75193bb)):

```c
static inline void enable_ftz(void) {
  uint64_t fpcr; __asm__ volatile("mrs %0, fpcr" : "=r"(fpcr));
  __asm__ volatile("msr fpcr, %0" :: "r"(fpcr | (1ull << 24)));
}
// call at the start of each render callback (cheap); restore the previous value if sharing threads with host code
```

- **[UNVERIFIED]** Whether macOS preserves a modified FPCR across context switches, and how large the subnormal penalty is on M-series cores, could not be confirmed in this pass. Setting FZ at the top of every callback is defensive and cheap. As belt-and-braces, add ~1e-20 of DC/noise injection in feedback loops (reverb, crossfeed).

---

## 2. Headphone correction (AutoEq)

### 2.1 The project

- **Repository:** [jaakkopasanen/AutoEq](https://github.com/jaakkopasanen/AutoEq), **MIT license**. It produces parametric, convolution (FIR) and fixed 10-band GEQ outputs (`--parametric-eq`, `--convolution-eq`, `--ten-band-eq`, with `--fs`, `--bit-depth`, `--f-res`).
- **Results layout:** `results/<source>/<form factor>/<Model>/`. Example: `results/oratory1990/over-ear/<Model>/`.
- **Measurement sources:** oratory1990, crinacle, Rtings, InnerFidelity, and legacy headphone.com data.
- **Milestones:** web app added 2022-05; PEQ optimizer rework adding shelves and Fc/Q/gain limits, 2022-09; PyPI packaging as `python -m autoeq`, 2022-10; v4.0.0 restructure, 2023-10-29.
- **Targets folder** (61 CSVs as of this pass) ([targets/](https://github.com/jaakkopasanen/AutoEq/tree/master/targets)):
  - Harman over-ear 2013, 2015 and 2018 (with and without bass)
  - Harman in-ear 2016, 2017-1, 2017-2 and 2019 (with and without bass)
  - AutoEq in-ear
  - Diffuse field: ISO 11904-1, GRAS KEMAR, B&K 5128, and 5128 −1 dB/oct
  - LMG 5128 0.6
  - oratory1990 in-ear and "optimum hifi over-ear"
  - JM-1 with Harman filters
  - rig-compensated variants (HMS II.3, Innerfidelity, Rtings, crinacle EARS+711)
  - Harman loudspeaker in-room flat 2013, and zero
- The Harman in-ear target research is Olive, Welti & Khonsaripour (AES 143, 2017): 71 listeners, 30 IEMs, with a preference-prediction model at r = 0.91 ([sportsvideo summary](https://www.sportsvideo.org/2017/09/21/best-paper-awards-announced-for-upcoming-aes-new-york-convention/), [AES e-lib](https://aes2.org/publications/elibrary-page/?id=19436)). The over-ear 2018 target comes from the same Harman program **[UNVERIFIED citation details]**.

### 2.2 Data format (ParametricEQ.txt)

This is the same format that Equalizer APO and PipeWire's `module-parametric-equalizer` consume ([PipeWire man page](https://man.archlinux.org/man/libpipewire-module-parametric-equalizer.7.en), [Equalizer APO reference](https://sourceforge.net/p/equalizerapo/wiki/Configuration%20reference/)):

```
Preamp: -6.8 dB
Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
Filter 2: ON PK Fc 21 Hz Gain 6.7 dB Q 1.100
...
Filter 10: ON HSC Fc 10000 Hz Gain -3.1 dB Q 0.70
```

The types are PK (peaking), LSC and HSC (shelves, defined with Q). The negative preamp is AutoEq's own anti-clip headroom.

### 2.3 Shipping presets

- **Build step.** Run a CI job that walks `results/**/ParametricEQ.txt`, picks one preferred source per model in priority order (oratory1990 > crinacle (GRAS/EARS) > Rtings > others), and emits:

```json
{"id":"sennheiser-hd-650","name":"Sennheiser HD 650","aliases":["HD650","HD 650"],
 "form":"over-ear","source":"oratory1990","target":"Harman over-ear 2018",
 "preamp_db":-6.3,"filters":[{"t":"LS","f":105,"g":5.5,"q":0.7},{"t":"PK","f":...}]}
```

  Several thousand models at ~10 filters each should compress to ≲1–2 MB **[ESTIMATE]**. Recompute biquads at the device's actual sample rate. Do not ship precomputed coefficients.
- **Licensing.** The AutoEq code is MIT. The **measurement data originates from third parties** (oratory1990, crinacle, Rtings). **[UNVERIFIED]** Whether each source permits commercial redistribution of derived EQ curves is not settled by the MIT license on the repo. Get legal review, credit each source in-app, and consider contacting oratory1990 and crinacle. Alternatively let users fetch AutoEq results at runtime.
- **Targets.** Offer "Harman 2018/2019" as the default. Offer "Harman without bass" for users who dislike the bass shelf, and a user bass/treble tilt on top: two shelves at 105 Hz and 2.5 kHz with Q = 0.7.

### 2.4 Detecting the headphone model on macOS

1. **CoreAudio first (public, no permissions needed).**
   - `kAudioDevicePropertyTransportType` gives BuiltIn, USB, Bluetooth, BluetoothLE, HDMI, DisplayPort, AirPlay, Virtual or Aggregate.
   - `kAudioObjectPropertyName` gives the user-visible name, often user-renamed (e.g. "Adam's AirPods Pro").
   - `kAudioObjectPropertyModelName` and `kAudioDevicePropertyModelUID` give a model string, when the driver provides one **[UNVERIFIED that BT devices populate it meaningfully]**.
   - On built-in output, the data source (`kAudioDevicePropertyDataSource`, 'ispk' vs 'hdpn') tells you headphones are on the 3.5 mm jack, but not which ones.
2. **Bluetooth metadata.**
   - Apple devices report Vendor ID 0x004C and a Product ID. Since 2021 Apple identifiers are `Device1,<PID decimal>`. Example: AirPods Pro 2 has PID 0x2014 = 8212 ([The Apple Wiki models](https://theapplewiki.com/wiki/Models)). The PID is visible in System Report → Bluetooth (`system_profiler SPBluetoothDataType`).
   - **[UNVERIFIED]** Public IOBluetooth (`IOBluetoothDevice.pairedDevices`, `addressString`, `name`, class of device) does not clearly expose the PID. Parsing `system_profiler -json SPBluetoothDataType` (out-of-process, slow, ~1 s) is a pragmatic fallback. Correlate it with the CoreAudio device by name or address. The BT CoreAudio device UID typically embeds the MAC address **[UNVERIFIED]**.
   - Caveat: Macs on older macOS have reportedly identified AirPods Pro 3 as AirPods Pro 2 ([MacRumors thread](https://forums.macrumors.com/threads/computer-identifies-airpod-pro-3-as-airpod-pro-2.2474638/)). Show the detected model and let the user correct it.
3. **USB.** Read the IOKit USB product and vendor strings, e.g. for dongle DACs. Most such DACs are not the transducer, so ask the user.
4. **Matching.** Normalize strings (lowercase, strip the possessive "'s", the brand and spaces), fuzzy-match against aliases, and require user confirmation the first time. Remember the choice per CoreAudio device UID.
5. **AirPods caveat.** AirPods and Beats apply their own (adaptive) EQ in-firmware or on the host. Stacking AutoEq on top is valid only if the measurement was taken in the same mode (ANC on/off/Transparency). If the user has macOS "Spatialize Stereo"/head tracking on, our HRTF virtualizer would double-process, so detect this where possible and warn.

---

## 3. Loudness and dynamics

### 3.1 BS.1770-5 / EBU R128 measurement

The current version is **ITU-R BS.1770-5 (11/2023)**, "Algorithms to measure audio programme loudness and true-peak audio level", a free download ([ITU](https://www.itu.int/rec/R-REC-BS.1770-5-202311-I)). WP6C has a preliminary draft revision as of 2026-08 that is not public. EBU Tech 3341 defines the meter modes ([EBU Tech 3341 PDF](https://tech.ebu.ch/docs/tech/tech3341.pdf), [Wikipedia R128](https://en.wikipedia.org/wiki/EBU_R_128)):

- **K-weighting** = high-shelf "pre-filter" + RLB high-pass. Coefficients at 48 kHz **[FROM MEMORY: FORMULA, from BS.1770 tables; recompute for other fs by BLT of the analog prototype]**:
  - Stage 1: b = [1.53512485958697, −2.69169618940638, 1.19839281085285], a = [1, −1.69065929318241, 0.73248077421585]
  - Stage 2: b = [1, −2, 1], a = [1, −1.99004745483398, 0.99007225036621]
- `L = −0.691 + 10·log10( Σ_c G_c · mean(y_c²) )`, with G = 1 for L and R.
- **Momentary** = 400 ms window. **Short-term** = 3 s window. **Integrated** = 400 ms blocks with 75% overlap, an **absolute gate at −70 LUFS**, then a **relative gate at −10 LU** below the absolute-gated mean ([Audacity manual](https://manual.audacityteam.org/man/perceived_loudness_ebu_r_128.html)).
- **True peak:** oversample at least 4× at 48 kHz (to ≥192 kHz) with the Annex 2 interpolating FIR, then take the absolute maximum. 4× leaves ~0.5–0.6 dB under-read worst case, which is why −1 dBTP ceilings exist ([ARIB TR-B32](https://arib.or.jp/english/std_tr/broadcasting/desc/tr-b32.html), [SOS Q&A](https://www.soundonsound.com/sound-advice/q-how-loud-should-master-tracks-intended-streaming)).

### 3.2 "Volume boost" without clipping

Signal flow (all float, so internal overs are harmless until the final stage):

```
x -> [Pre-gain +0..+12 dB, smoothed] -> ... effects ... -> [True-peak look-ahead limiter, ceiling -1 dBTP]
  -> [Soft clipper safety @ -0.3 dBFS, 2x OS] -> [Output gain / user volume] -> device
```

**Look-ahead limiter (guaranteed no overshoot) [design pattern well known; Signalsmith-style write-up not verified this pass]:**

```
L = lookahead samples (1.5–5 ms; 2 ms = 96 samples @48k)
p[n]  = max over channels of |x_tp[n]|           // x_tp: 4x-oversampled peak (polyphase, 12 taps/phase)
gT[n] = min(1, ceiling / p[n])                   // target gain
gH[n] = min(gT[n-L+1 .. n])                      // sliding-window minimum (monotonic deque, O(1))
gS[n] = boxcar_mean_L(gH)[n]                     // linear attack over L samples -> never exceeds gH at the peak
g[n]  = min(gS[n], release_smooth(g[n-1]))       // one-pole release, 50–200 ms (program-dependent: faster for transients)
y[n]  = x[n-L] * g[n]                            // delay the audio by L (plus the boxcar delay alignment)
```

- Stereo-link the gain (apply the same g to L and R) so the image does not shift.
- Use program-dependent release with two release time constants, fast and slow, to avoid pumping on dense music.
- **Soft clipper** as the last safety: `y = tanh(x)`, or a cubic `y = 1.5x − 0.5x³` for |x| ≤ 1, at 2× oversampling. It should almost never engage.
- **Auto pre-gain for EQ.** Do not use −Σ(max boosts). Evaluate the **composite** magnitude response |H_total(f)| on ~512 log-spaced points (20 Hz–20 kHz) whenever the EQ changes, and set `preGain = −max(0, max_f dB)`. Overlapping boosts sum, and cuts offset them. Option: apply only ~50–70% of that compensation and let the limiter handle rare peaks, because full compensation makes "EQ on" sound quieter and users read that as worse (the loudness bias).
- **Loudness-matched A/B.** When the user toggles bypass, match the short-term LUFS of the two paths, so the enhancement is not judged simply by being louder.

### 3.3 Automatic loudness normalization ("Volume leveler")

```
every 100 ms: S = short-term LUFS (3 s window, K-weighted) of the input
if S < -50 LUFS: hold gain (gate silence/noise floor; do not boost hiss)
err  = target(-16 LUFS default; -14 "loud"; -20 "quiet") - S
gain_target = clamp(err, -12 dB, +12 dB)
gain = slew(gain, gain_target, up: 1 dB/s, down: 3–6 dB/s)   // faster down than up
apply gain, then the true-peak limiter catches transients
```

Use momentary loudness (400 ms) only for fast downward protection, e.g. against an ad suddenly louder by more than 6 LU.

### 3.4 Multiband compression and night mode

- **Crossovers.** Use Linkwitz-Riley 4th order (two cascaded Butterworth 2nd-order sections) at ~120 Hz, 1 kHz and 6 kHz. The bands sum to an allpass with flat magnitude. For 3+ bands, add allpass phase compensation to the lower bands.
- **Per band.** Use an RMS or peak detector (log domain) and a soft-knee static curve:

```
x_dB = 20log10(env); over = x_dB - T
gr = over <= -W/2 ? 0 : over >= W/2 ? (1/R - 1)*over : (1/R - 1)*(over + W/2)^2/(2W)
gain_dB = smooth(gr, attack, release)    // in the dB domain
```

- **Night mode** = downward compression (T ≈ −30 dBFS, R = 3–4:1, attack 5–10 ms, release 150–400 ms) plus **upward** compression of quiet passages (raise everything below −45 dBFS by up to +10 dB), a mid-band (1–4 kHz) dialogue emphasis of +2–3 dB, and a sub-bass cut below 60 Hz (−6 dB). Finish with the leveler and limiter. This mirrors AV-receiver "midnight" modes. Apple's Enhance Dialogue on HomePod and Apple TV (tvOS 18 extended it to AirPods and BT devices) does something similar in a content-aware way ([TechCrunch](https://techcrunch.com/2024/06/10/apple-tv-insight-feature-wwdc-2024), [GSMArena](https://www.gsmarena.com/tvos_18_brings_insight_enhanced_dialogue_and_219_support-news-63228.php)).

---

## 4. "Enhancement" effects

### 4.1 Psychoacoustic bass (missing fundamental, MaxxBass-style)

Basis: Larsen & Aarts, "Reproducing Low-Pitched Signals through Small Loudspeakers", JAES 50(3), 2002, and the book *Audio Bandwidth Extension* (Wiley 2004). Harmonics of a fundamental the speaker cannot reproduce make the brain infer the fundamental ([TU/e](https://research.tue.nl/en/publications/reproducing-low-pitched-signals-through-small-loudspeakers/), [AES](https://aes2.org/publications/elibrary-page/?id=11088)). The DAFx-2020 virtual-bass work from Aalto notes that good quality remains hard to reach, mainly because of intermodulation and transient smearing ([Eloi et al. DAFx2020 PDF](https://acris.aalto.fi/ws/portalfiles/portal/51973173/Eloi2020_Virtual_bass_DAFx2020.pdf)).

```
fc   = speaker low cutoff (MacBook ~150–250 Hz [ESTIMATE]; headphones: effect off or subtle)
lo   = LR4_lowpass(x_mono, fc)  (band 40 Hz..fc via an extra HP at ~40 Hz)
env  = envelope(lo)
h    = NLD(lo / (env+eps)) * env         // normalize then re-scale -> harmonic levels track input dynamics
       NLD options: full-wave rectifier |x| (even), half-wave (even+odd),
       Chebyshev mix T2..T5 with weights ~[1, 0.6, 0.35, 0.2] (controlled spectrum, no aliasing above 5*fc)
h    = bandpass(h, fc .. 4*fc)           // drop DC and the original fundamental; keep 2nd–4th harmonics
y    = HP_LR4(x, fc)*(1) + lo*keep + h*g_vb    // keep = 0..1 of the real bass (0.3 on laptops)
```

- At fc ≤ 250 Hz, the 5th harmonic is ≤1.25 kHz, far below Nyquist. A Chebyshev polynomial NLD therefore **needs no oversampling**, whereas tanh or rectifier NLDs do produce aliasing tails, so use 2× oversampling for those.
- For transients (kick drums), the phase-vocoder virtual-bass hybrids in the literature are better, at higher cost. NLD is fine for v1.
- Use loudness-dependent amounts, more at low volume (Fletcher-Munson). Tie this to the user's volume.

### 4.2 Exciter / "fidelity" harmonics

```
hf = HP(x, 3–5 kHz)  ->  2x oversample  ->  y = tanh(drive*hf)/drive  (odd) or  hf + a*hf^2 (even, then DC-block)
     -> downsample -> HP again (remove intermod below the band) -> mix 5–15 %
```

Use dynamic drive, inversely proportional to the HF envelope, to restore the "air" of dull or lossy content without harshening bright tracks. FxSound's "Fidelity" and "Ambience" knobs are this family of effect, and its source is public (licensed GPL-3 or AGPL-3, sources disagree) at [fxsound2/fxsound-app](https://raw.githubusercontent.com/fxsound2/fxsound-app/main/README.md) ([FxSound blog](https://www.fxsound.com/blog)). **Do not read or copy that code if we ship closed source.** Copyleft contamination is a real risk.

### 4.3 Stereo widening

```
M = (L+R)/2,  S = (L-R)/2
S' = S * w            (w: 0..2; 1 = unchanged)   -> optionally only above 200–300 Hz: S' = S + (w-1)*HP(S, 250 Hz)
L' = M + S',  R' = M - S'
```

- **Mono compatibility.** The mono sum L'+R' = 2M is unchanged by any S processing, so M/S width is perfectly mono-safe. **Haas/delay widening** (delaying one channel by 5–30 ms, or a decorrelating allpass on S) creates comb filtering in mono and on MacBook speakers that sit close together, so avoid it or restrict it to S only.
- Keep the bass mono: high-pass S below ~120 Hz. Show a correlation meter (ρ = E[LR]/√(E[L²]E[R²])) and auto-limit w when ρ < 0.
- MacBook speakers sit ~25–30 cm apart, so widening helps there. Crosstalk cancellation is a better tool for that case (§4.6) but sweet-spot sensitive.

### 4.4 Crossfeed for headphones

- **bs2b** (Bauer stereophonic-to-binaural): a low-passed, attenuated copy of the opposite channel, plus a complementary high-shelf on the direct path to keep overall loudness flat. The default preset is **700 Hz / 4.5 dB**, the closest match to a virtual speaker at 30° and ~3 m. Chu Moy (700 Hz / 6 dB) and Jan Meier (650 Hz / 9.5 dB) variants also exist. The library is libbs2b, MIT per MacPorts ([bs2b.sourceforge.net](https://bs2b.sourceforge.net/), [MacPorts](https://ports.macports.org/port/libbs2b/), [Rust crate docs](https://docs.rs/crate/bs2b/0.2.0)). **[UNVERIFIED]** The Fedora listing shows a different license, so check the tarball.
- **Linkwitz 1971** ("Improved Headphone Listening", *Audio*, Dec 1971). Passive crossfeed with ~0.3 ms delay and lowpass ([Modified Linkwitz Crossfeed](https://tangentsoft.com/audio/mlxfeed.html)). Reimplementing the topology from published descriptions is straightforward.

```
cross_L = LP1(R, fc) * 10^(-feed/20)  // first order; its group delay ~ 1/(2*pi*fc) ≈ 0.23 ms at 700 Hz
direct_L = highshelf(L, fc, +comp)    // comp chosen so L_out has a flat response for a centred (L=R) source
L_out = direct_L + cross_L  (mirror for R)
```

### 4.5 Ambience

Use a short early-reflection tapped delay (6–12 taps, 5–40 ms, panned and lowpassed) plus a small FDN reverb (4×4 or 8×8 Householder, RT60 0.3–0.8 s, damping above 5 kHz). Feed it only above ~200 Hz and mix 5–15%. Its main use is adding externalization cues for the 3D mode.

### 4.6 3D / spatial virtualization

**HRTF virtual speakers from stereo.** Place virtual L and R speakers at ±30° (±45° for a "wide" setting):

```
yL = x_L * h_ipsi + x_R * h_contra
yR = x_R * h_ipsi + x_L * h_contra
```

Assuming head symmetry, the shuffler form needs only 2 convolutions:

```
S = (xL+xR) * (h_i + h_c)/2,  D = (xL-xR) * (h_i - h_c)/2,  yL = S + D,  yR = S - D
```

- **IR length.** Anechoic HRIRs are 128–512 taps at 48 kHz. Short IRs run by direct-form FIR with vDSP_conv, or by uniformly partitioned overlap-save at 64- or 128-sample blocks.
- **Externalization** improves greatly with a short BRIR or early reflections (§4.5) and with headphone EQ (§2). Without them, it sounds "inside the head".
- **5.1/7.1 virtualization.** Use 5–7 virtual sources × 2 ears. Exploit symmetry and the shuffler to cut the convolution count. LFE goes straight to both ears through a lowpass. This is the feature Boom 3D markets: toggling individual virtual speakers, plus an LFE gain ([Hongkiat](https://www.hongkiat.com/blog/boom3d-mac-review/)).

**Open HRTF datasets (SOFA / AES69):**

| Dataset | Contents | License (as found) |
|---|---|---|
| **HUTUBS** (TU Berlin) | HRTFs of 96 subjects, 3D head meshes, anthropometrics, headphone TFs | **CC BY 4.0** ([DepositOnce](https://depositonce.tu-berlin.de/items/dc2a3076-a291-417e-97f0-7697e332c960/full)). Commercial use OK with attribution. |
| **SADIE II** (Univ. of York) | HRTFs, BRIRs and headphone EQ; 44.1k/16, 48k/24 and 96k/24 WAV + SOFA; includes KU100/KEMAR dummy heads | The original SADIE is **Apache-2.0** ([York](https://www.york.ac.uk/sadie-project/database_old.html)). **[UNVERIFIED]** SADIE II's own license (Zenodo [record 10886409](https://zenodo.org/records/10886409) could not be fetched); it is believed to be Apache-2.0 as well. Check before shipping. |
| **MIT KEMAR** (Gardner & Martin 1994) | 710 directions on a KEMAR, Optimus Pro 7 speaker at 1.4 m | Freely available since 1994. **No formal license found** ([hrtfdoc.txt](https://sound.media.mit.edu/resources/KEMAR/hrtfdoc.txt), [KEMAR FAQ](https://sound.media.mit.edu/resources/KEMAR/KEMAR-FAQ.txt)). mplayer redistributed it under GPL "with authors' permission". Legally ambiguous for commercial use. |
| **FABIAN** (TU Berlin) | Head-and-torso simulator HRTFs | Listed CC BY-NC-SA, possibly moved to CC-BY in 2020 **[UNVERIFIED]**. Avoid unless confirmed. |

- **Format.** AES69 (SOFA, netCDF), last updated 2022 as SOFA 2.1 ([ÖAW SOFA page](https://www.oeaw.ac.at/isf/forschung/hoeren/laufende-projekte/sofa-spatially-oriented-format-for-acoustics), [IANA audio/sofa](https://iana.org/assignments/media-types/audio/sofa)).
- **Reader.** [libmysofa](https://github.com/hoene/libmysofa) (BSD-3 **[UNVERIFIED]**). Better still, preconvert the few needed directions offline into a compact binary bundled with the app, so no SOFA parsing happens at runtime.
- **Recommendation.** Ship a few HRTF sets: one dummy head (KU100 or KEMAR from SADIE II, if Apache) and a few "small / medium / large head" HUTUBS subjects. Let the user pick by A/B listening.

**Upmixing stereo to 5.1/7.1 (primary-ambient extraction).**
- Avendano & Jot use the STFT inter-channel coherence and a panning index to separate primary (panned) components from ambient (decorrelated) ones and re-pan them to more channels (AES 2004, "A Frequency-Domain Approach to Multichannel Upmix") ([AES](https://aes2.org/publications/elibrary-page/?id=13016)).
- The related Creative patents (Goodwin, Avendano, Jot) include US7412380 "Ambience extraction and modification…" ([Google Patents](https://patents.google.com/patent/US7412380)). **The patent landscape here is real.** Many of the patents are old enough to have expired (filed early 2000s, 20-year term), but get counsel to confirm.

PCA per time-frequency tile:

```
STFT, N=1024–2048, hop N/4, sqrt-Hann analysis/synthesis
for each bin k: smoothed covariance  r_LL, r_RR, r_LR  (one-pole over frames, tau ≈ 50–100 ms)
  principal direction theta = 0.5*atan2(2 r_LR, r_LL - r_RR)
  primary  P = (X_L cos theta + X_R sin theta)            // projection onto the eigenvector
  ambient  A_L = X_L - P cos theta,  A_R = X_R - P sin theta
  pan index from theta -> distribute P among C / L / R (constant-power), A -> Ls/Rs (+ decorrelation allpass, 10–20 ms delay)
```

- STFT latency is N − hop, about 32 ms at N = 2048 and 48 kHz. That is acceptable for "movie mode" but not for games, so offer a low-latency time-domain fallback: the passive matrix C = 0.707(L+R) and S = 0.707(L−R) with filtering.

**Speaker virtualization and crosstalk cancellation (MacBook).** Two-speaker crosstalk cancellation (a recursive "ambiophonic" RACE-style filter, or an inverse 2×2 HRTF matrix with regularization) can widen the image beyond the chassis. It is sweet-spot dependent, and Apple already does this when "Spatialize Stereo" is used on supported Macs **[UNVERIFIED for which models]**. Treat it as optional.

**Room correction basics.** It is out of scope for v1. The method:
1. Measure with an exponential sine sweep (Farina) using a calibrated microphone.
2. Apply fractional-octave smoothing (1/3–1/6 octave).
3. Correct mostly below the Schroeder frequency, ~200–300 Hz for rooms. Cut peaks and never fill nulls.
4. Average several listening positions and limit the correction to ±6 dB.

---

## 5. Small-speaker (MacBook) optimization

- **Apple already runs a per-model DSP chain** on built-in speakers. The Asahi Linux project reverse-engineered the per-machine EQ, the multiband processing and a **speaker protection** model, which reads V/I-sense data from TAS2764-class smart amplifiers. They reimplemented these as `asahi-audio` (PipeWire/LSP-plugin DSP configs plus the "Bankstown" virtual-bass plugin) and `speakersafetyd` (a Rust thermal and excursion protection daemon) ([Asahi audio docs](https://asahilinux.org/docs/sw/audio-userspace/), [asahi-audio](https://github.com/chadmed/asahi-audio), [speakersafetyd](https://github.com/chadmed/speakersafetyd), [HN discussion](https://hn.svelte.dev/item/42021237)). Asahi chose a **virtual-bass plugin (Bankstown)** for MacBook speakers rather than raw bass boost. That is a strong signal about what works.
- **Implication for us.** Our processing on macOS feeds the device *before* Apple's internal speaker DSP and protection, which runs below the HAL or in the driver **[UNVERIFIED exact location]**. So:
  1. **Headroom is limited.** At high volume the built-in chain already drives the drivers near their excursion and thermal limits. Added low-frequency boost mostly makes Apple's protection limiter pump, and the result sounds smaller rather than bigger.
  2. **Perceived loudness gains** come from: (a) mid-band multiband compression and upward compression (raising RMS in 300 Hz–4 kHz, where the drivers are efficient); (b) **virtual bass** (§4.1, harmonics at 150–600 Hz instead of energy at 50–100 Hz); (c) a true-peak limiter with modest pre-gain (+3 to +6 dB, not +12).
  3. **Protect.** On the built-in-speaker profile, high-pass at ~100–150 Hz before our own boosts (the drivers cannot reproduce below that anyway), cap the low-shelf boost at about +3 dB, and use a multiband limiter: a low band at a −6 dB lower ceiling than the mids.
- **Detection.** Built-in speakers have transport type BuiltIn with data source 'ispk'. Select the "MacBook Speakers" preset automatically. Per-model tuning (Air 13" vs Pro 14"/16") is a nice-to-have. The 16" has a much larger enclosure and woofers in force-cancelling pairs, so it should get less virtual bass and more real bass **[ESTIMATE]**.

---

## 6. Analysis and visualization

- **Tap point.** Take the signal post-chain, pre-device-volume. The audio thread only **copies samples** into an SPSC ring buffer (memcpy). It does no FFT.
- **Analysis thread** (normal priority, 30–60 Hz timer):

```
N = 4096 @48k (11.7 Hz bins; ~85 ms window) — or 8192 for better LF resolution in a "pro" view
pull newest N samples (mono sum or L/R) -> multiply by Hann (vDSP_hann_window, precomputed) -> vDSP_fft_zrip (real FFT, packed)
power = vDSP_zvmags -> scale by 2/(N * sum(w)^2) for window coherent gain -> vDSP_vdbcon to dB
log-frequency binning: ~1/6- or 1/12-octave bands from 20 Hz–20 kHz (precomputed bin ranges; average power, not dB)
octave smoothing: for each output frequency f, average power over [f*2^(-1/(2n)), f*2^(1/(2n))] (n = 3, 6, 12)
temporal ballistics in dB: attack instant (or 10 ms), release 300–1000 ms; optional peak-hold with 20 dB/s falloff
publish to UI: triple buffer (atomic index swap), so the UI always reads a complete frame
```

- Use 50–75% overlap so updates at 60 fps reuse the history. Sliding-window magnitudes are computed in µs: a 4096-point real FFT on M-series is ~5–15 µs **[ESTIMATE]**.
- Cheaper alternative for a "bar" visualizer: a bank of 31 band-pass biquads, or the graphic-EQ ISO bands with RMS detectors, run on the analysis thread.
- Apple FFT APIs: `vDSP_create_fftsetup`/`vDSP_fft_zrip` on `DSPSplitComplex` (split real and imaginary arrays), `vDSP_DFT_Execute`, and Swift `vDSP.FFT` ([Apple: Fourier transforms](https://developer.apple.com/documentation/accelerate/performing-fourier-transforms-on-interleaved-complex-data.md), [About vDSP](https://developer.apple.com/library/mac/documentation/Performance/Conceptual/vDSP_Programming_Guide/About_vDSP/About_vDSP.html)).
- Meters: true-peak (BS.1770 4× OS), short-term LUFS, M/S correlation, and gain reduction from the limiter, compressor and leveler. These are published as atomics (float bit-cast into `std::atomic<uint32_t>`) once per block.

---

## 7. Real-time engineering

### 7.1 Ground rules for the IO thread

Follow Ross Bencina, "Real-time audio programming 101: time waits for nothing" (rossbencina.com/code/real-time-audio-programming-101-time-waits-for-nothing, discussed on [LWN](https://lwn.net/Articles/453005/)). Inside the IO thread, never:
- call malloc/free or new/delete
- take locks (no `std::mutex`, `@synchronized` or `DispatchQueue.sync`)
- call Objective-C messaging or Swift ARC-heavy code
- do file or network I/O, logging (os_log is permissible only sparingly), or anything that can page-fault or priority-invert

Preallocate everything at the maximum block size (`kAudioDevicePropertyBufferFrameSize` upper bound, e.g. 4096) and the maximum channel count.

### 7.2 Thread communication

- **SPSC lock-free ring buffer** (power-of-two capacity, `std::atomic<size_t>` head and tail; release on publish, acquire on read). Use it for (a) parameter-change messages from UI to audio, (b) samples from audio to the analyzer, and (c) audio to an ML worker and back.
- **Atomics for scalar parameters.** The UI writes the target value. The audio thread reads it once per block and feeds the smoother.
- **Double-buffered coefficient or state sets** for large objects (an EQ preset, HRIR partitions or a new AutoEq stack). The UI or worker thread builds a new immutable `ChainConfig` and publishes its pointer through an atomic exchange. The audio thread picks it up at the block start and starts a **crossfade** from the old config to the new one. The old pointer goes back through a "garbage" SPSC queue to a non-RT thread, which frees it. Free nothing on the audio thread.
- **Audio workgroups.** Any helper real-time threads (ML, parallel convolution) should join the device's `os_workgroup` (`kAudioDevicePropertyIOThreadOSWorkgroup`) so that Apple Silicon schedules them on P-cores with the IO deadline ([Apple: workgroup management](https://developer.apple.com/documentation/audiotoolbox/workgroup-management.md), [Adding parallel RT threads](https://developer.apple.com/documentation/audiotoolbox/adding-parallel-real-time-threads-to-audio-workgroups.md), [Porting audio code to Apple silicon](https://developer.apple.com/documentation/apple-silicon/porting-your-audio-code-to-apple-silicon.md)). **[UNVERIFIED]** One forum report says joining fails with EINVAL unless `THREAD_TIME_CONSTRAINT_POLICY` is set first ([Apple forums](https://developer.apple.com/forums/thread/697874)).

### 7.3 SIMD and block processing

- Process stereo as a 2-lane vector (`simd_float2`/`float32x2_t`), or pack L/R × two filters into 4 lanes. Cascaded biquads are serial per channel, so the parallelism is **across channels and across independent bands of a parallel structure**, not within one section.
- **Block-based** for gains, mixing, M/S and metering (vDSP over the whole buffer). **Per-sample inner loops** for recursive filters, but with coefficients held constant within a sub-block of 16–32 samples when smoothing.
- Typical system output block sizes are 256–1024 frames at 48 kHz. Write the chain to handle any size up to the maximum, including odd sizes.

### 7.4 Oversampling nonlinear stages

- Nonlinearities (exciter, soft clipper, tanh NLD bass) need 2–4× oversampling to keep aliasing products (which reflect back from the upsampled Nyquist) below audibility.
- **Polyphase IIR halfband** filters (allpass-pair based, de Soras' **HIIR**, WTFPL **[UNVERIFIED license]**) give steep transitions, very low latency (a few samples, non-linear phase) and NEON-SIMD support ([unevens/hiir fork](https://github.com/unevens/hiir), [Rust halfband crate](https://docs.rs/halfband)).
- **Linear-phase FIR halfbands** have a latency of ~N/4 at the base rate per 2× stage (e.g. 31-tap → ~8 samples). Use them for true-peak detection (BS.1770 Annex 2 FIR) and wherever phase linearity matters.
- Cascade 2× stages for 4×. Oversample only the band that needs it (e.g. the exciter's HF band).

### 7.5 Latency and CPU budget (48 kHz stereo, Apple Silicon P-core)

CPU figures are **[ESTIMATE]**, scaled from op counts (one biquad ≈ 5 mul + 4 add per sample per channel) and an assumed few GFLOP/s of scalar-plus-NEON throughput per M-series P-core. Validate them with Instruments on M1 and M3 Air hardware.

| # | Stage | Added latency | CPU (% of one P-core) | Notes |
|---|---|---|---|---|
| 0 | Input capture (virtual device / process tap) | 1 IO buffer (5–20 ms) | — | The architecture choice dominates total latency (HAL plug-in vs Core Audio tap, macOS 14.2/14.4+ ([AudioCap](https://github.com/insidegui/AudioCap), [Recall.ai](https://www.recall.ai/blog/core-audio-taps))) |
| 1 | Input meter + content-classifier tap (copy to ring) | 0 | <0.05 | ML runs elsewhere |
| 2 | Pre-gain / auto EQ compensation (smoothed) | 0 | <0.02 | |
| 3 | Headphone correction: AutoEq ≤10 biquads, double TDF2 / vDSP_biquadm | 0 | ~0.1 | |
| 4 | User EQ: 31-band ACGE or 10-band PEQ, SVF double | 0 | 0.2–0.4 | 31 bands × 2 ch × 48k |
| 5 | Dialogue / night-mode multiband compressor (LR4 3-band) | 0 | 0.2–0.4 | |
| 6 | Virtual bass (LR4 split, Chebyshev NLD, BP) | 0 | ~0.1 | Oversampling only if tanh NLD |
| 7 | Exciter (HF band, 2× OS IIR halfband, tanh) | ~0.1 ms | ~0.1 | |
| 8 | Stereo width (M/S) | 0 | <0.02 | |
| 9a | Headphones: crossfeed (bs2b) **or** | ~0 | <0.05 | Mutually exclusive with 9b |
| 9b | 3D: HRIR virtual speakers, 2 conv × 256 taps (shuffler) | 0 (direct FIR) – 1.3 ms (64-sample partitions) | 0.5–1 | 7.1 virtualization ×3–4 |
| 9c | Upmix PAE (STFT 2048, PCA) — movie mode only | ~32 ms | 1–2 | Optional |
| 10 | Ambience (ER + small FDN) | 0 | 0.2–0.5 | |
| 11 | Auto-leveler (K-weight + short-term LUFS) | 0 | <0.1 | |
| 12 | True-peak look-ahead limiter (4× polyphase detector) | 1.5–2 ms | 0.3–0.5 | |
| 13 | Soft clip safety (2× OS) | ~0.1 ms | <0.1 | |
| 14 | Output meter + analyzer tap | 0 | <0.05 | FFT on a non-RT thread |
| | **Total DSP (excl. 9c, ML)** | **~2–3.5 ms** | **~2–4%** | |
| ML | Dialogue separation worker (optional) | +20–40 ms + 1 block | ANE/GPU/CPU varies | §8 |

**Recommended chain order** (rationale in brackets):

```
Capture -> [Classifier tap] -> Pre-gain/auto-EQ-compensation
-> Device correction (AutoEq headphones | MacBook speaker profile)  [fix the transducer first, so effects see "flat"]
-> User EQ (graphic/parametric)                                      [taste on top of a corrected baseline]
-> Dialogue/Night multiband compressor                               [before bass/exciter, so harmonics aren't compressed twice]
-> Virtual bass -> Exciter                                           [nonlinear; after EQ so user EQ shapes their input]
-> Stereo width (M/S)
-> Spatial: Crossfeed (headphones) | HRTF virtualizer (3D) | Upmix+virtualizer (movie)
-> Ambience (send/return)
-> Auto-leveler (gain riding)
-> True-peak look-ahead limiter (-1 dBTP) -> Soft-clip safety
-> Output, plus the meters/analyzer tap
```

### 7.6 Crossfading: presets, bypass, device and sample-rate changes

- **Preset switch.** Run old and new chains in parallel for 20–50 ms with an equal-power crossfade (sin/cos) for uncorrelated changes. Use a linear (equal-gain) crossfade when the chains are highly correlated, as in an EQ change of the same signal, to avoid a +3 dB bump. A preset switch can also be a parameter morph when topologies match (smooth all parameters). That is preferable with SVF EQ.
- **Bypass.** Never hard-switch. Crossfade the wet path against a **latency-compensated** dry path (dry delayed by the chain latency) over 10–30 ms. Otherwise a crossfade between misaligned signals combs.
- **Sample-rate or device change** (`kAudioDevicePropertyNominalSampleRate` listener). On a non-RT thread: recompute all coefficients (biquads, SVF g, K-weighting, crossovers), reload HRIRs at the new fs (ship 44.1/48/96 sets or resample offline) and reallocate buffers. Publish the new chain, fade out to silence over ~5 ms, swap, then fade in. Load the AutoEq or speaker profile for the new device at the same time.

---

## 8. AI/ML in 2026

### 8.1 Feasibility on Apple Silicon

- **Inference speed.** The ANE delivers sub-ms inference for small CNNs (0.2–0.6 ms for a speech-classification CNN across 4 devices) ([engrXiv preprint](https://engrxiv.org/preprint/view/6814)).
- **Callback safety.** A **DAFx-26** paper benchmarking real-time neural audio on Apple Silicon under realistic DAW load reports three points: current consumer NPU APIs do not appear to offer a callback-safe path; handing inference to another thread adds at least one buffer of latency; and **BNNSGraph** (Accelerate, CPU) was the most robust for convolutional models under contention ([DAFx26 paper 16](https://www.dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf), [details](https://dafx.de/paper-archive/details/rBxXewYH3YxRTiGXqSabwQ)). Isolated benchmarks mislead.
- **Architecture rule.** Never call Core ML from the IO callback. Use **IO thread → SPSC ring → ML worker** (joined to the audio workgroup, or on ANE/GPU via Core ML), with the result returned through **SPSC → IO thread**. Compensate the dry path's latency and fall back to bypass on underrun, using a model-health watchdog.

### 8.2 Dialogue enhancement

- **Apple precedent.** "Enhance Dialogue" started on HomePod. tvOS 18 extended it to TV speakers, receivers and **Bluetooth devices including AirPods** on Apple TV 4K (2nd gen+) ([TechCrunch](https://techcrunch.com/2024/06/10/apple-tv-insight-feature-wwdc-2024)). No 2025–2026 changes could be confirmed in this pass **[UNVERIFIED for tvOS 26]**.
- **Three tiers for our product:**
  1. **Classic (v1, zero risk).** Centre extraction (time-domain M or STFT PAE primary), a speech-band (1–4 kHz) presence boost on the centre only, multiband compression, and ducking of S and low frequencies when speech probability is high.
  2. **Low-latency neural speech/background separation.**
     - **HS-TasNet** (ICASSP 2024): 23 ms latency, MUSDB SDR 4.65 dB, or 5.55 dB with extra data ([arXiv 2402.17701](https://arxiv.org/abs/2402.17701v1)).
     - **RT-STT** (Nov 2025, quantized lightweight TFC-TDF) ([arXiv 2511.13146](https://arxiv.org/abs/2511.13146v1)).
     - **DeepFilterNet 2/3**: 48 kHz full band, RTF 0.04 on a notebook i5 for DFN2, 10 ms frames + 20 ms lookahead. It is a *noise suppressor* for speech, so retraining it for dialogue-vs-music/effects would be required ([DFN2 arXiv](https://arxiv.org/abs/2205.05474v1), [DFN3 arXiv](https://arxiv.org/abs/2305.08227v1), [DFN3 MLX port](https://huggingface.co/aufklarer/DeepFilterNet3-MLX), [DFN3 CoreML port](https://huggingface.co/aufklarer/DeepFilterNet3-CoreML/commit/a9ec0b667af0653d31598b459a46fb65527ecfcf)). **[UNVERIFIED]** The license is MIT/Apache dual per the repo, from memory; check it.
  3. **Offline-quality separation.** HTDemucs (Rouard, Massa, Défossez; ICASSP 2023; 9.20 dB SDR MUSDB with extra data) is **not real-time**, given its seconds-long context and size ([arXiv 2211.08553](https://export.arxiv.org/pdf/2211.08553)). It is useful only for a "process file" feature.
- **Latency verdict.** 20–40 ms of extra latency is acceptable for music and podcasts. With video, it is acceptable only if A/V sync is maintained. macOS players compensate for device latency reported via `kAudioDevicePropertyLatency`/`SafetyOffset` on a virtual device **[UNVERIFIED how reliably apps honour it]**. It is unacceptable for games. Make dialogue AI a toggle that is automatically off for "Game".

### 8.3 Content-aware preset switching

- **Classifier.** Use Apple **SoundAnalysis** `SNClassifySoundRequest(classifierIdentifier: .version1)`, a built-in model with 300+ labels and multi-label output ([Apple docs](https://developer.apple.com/documentation/soundanalysis/snclassifysoundrequest.md), [Zenn](https://zenn.dev/shu223/articles/soundanalysis-builtin)). **[UNVERIFIED]** Whether "speech" and "music" are exact labels in `knownClassifications` must be checked at runtime. Background-execution failures have been reported on iOS, and macOS agent apps should be tested ([forum thread](https://developer.apple.com/forums/thread/811582)). An alternative is a small custom Create ML or YAMNet-style classifier (AudioSet, Apache-2.0 **[UNVERIFIED]**).
- **Policy.** Run classification at 1–2 Hz on 1 s windows. Smooth the probabilities (EMA with τ ≈ 3–5 s), add hysteresis (switch only after a class has dominated for more than 5 s), and **crossfade presets over 1–2 s**. Cheaper and more robust: use the frontmost app's bundle ID (games, video players, Music, Zoom) as a strong prior, with the audio classifier as a tiebreaker. Respect a user lock.

### 8.4 Neural EQ and auto-mastering

Research and commercial "AI mastering" (reference-matching EQ, differentiable-DSP parameter estimation) exists, but no source in this pass established a clearly superior, real-time, licensable model for consumer playback **[UNVERIFIED landscape]**. A practical "smart EQ" can be classical:
1. Measure the long-term average spectrum of the content (1/3-octave, 30 s window).
2. Compare it with a genre target curve.
3. Apply a gentle (±3 dB, 3–5 broad bands) slowly-varying correction through the same SVF EQ.

That is cheap, explainable and has no latency.

---

## 9. Competitive notes

- **Boom 3D:**
  - 3D surround with per-virtual-speaker toggles, intensity and LFE gain
  - 31-band EQ with genre, vocal, movie and bass presets
  - per-app volume, and an iOS remote ([Hongkiat](https://www.hongkiat.com/blog/boom3d-mac-review/), [Setapp](https://setapp.com/how-to/boost-mac-volume-with-boom-3d))
- **FxSound:** open source since 2023-11-28, licensed GPL-3 per its blog and AGPL-3 per its LICENSE file ([FxSound blog](https://www.fxsound.com/blog)). Its knobs are Fidelity, Ambience, 3D Surround, Dynamic Boost and Bass Boost.
- **Differentiators we can build:**
  - an accurate graphic EQ (ACGE), so the curve you draw is the curve you get
  - automatic AutoEq per headphone
  - a true-peak-safe boost
  - loudness-matched A/B
  - a MacBook-specific virtual-bass profile
  - a HUTUBS/SADIE-based HRTF choice
  - optional neural dialogue mode with honest latency reporting

---

## 10. Open questions and flagged items

1. SADIE II license on Zenodo (believed Apache-2.0) **[UNVERIFIED]**. HIIR, libmysofa and libbs2b license texts **[UNVERIFIED]**.
2. Commercial redistribution of AutoEq results derived from third-party measurements **[UNVERIFIED; needs legal review]**.
3. Public API for the Bluetooth Product ID on macOS **[UNVERIFIED]**. Fallback: `system_profiler`.
4. FPCR persistence across macOS context switches, and the subnormal penalty on M-series **[UNVERIFIED]**.
5. Where Apple's built-in speaker protection sits relative to the HAL output stream **[UNVERIFIED]**.
6. Exact Vicanek and Simper formulas were written from memory because the PDFs were unreachable from this sandbox **[VERIFY before implementation]**.
7. All CPU and latency numbers in §7.5 are **[ESTIMATE]**. Benchmark them.

---

## Sources

**EQ**
- W3C Audio EQ Cookbook (WG Note, 2021-06-08): https://www.w3.org/TR/audio-eq-cookbook
- Legacy W3C cookbook copy: https://w3.org/2011/audio/audio-eq-cookbook.html
- W3C public-audio thread on the 2021 note: https://lists.w3.org/Archives/Public/public-audio/2021AprJun/0038.html
- Vicanek, Matched Second Order Digital Filters (2016): https://www.vicanek.de/articles/BiquadFits.pdf
- Orfanidis 1997, AES e-library: https://aes2.org/publications/elibrary-page/?id=13397
- MathWorks parametricEqualizerDesign: https://www.mathworks.com/help/audio/ref/parametricequalizerdesign.html
- comp.dsp thread on Orfanidis: https://www.dsprelated.com/showthread/comp.dsp/154018-1.php
- Zavalishin, The Art of VA Filter Design 2.1.0: https://www.native-instruments.com/fileadmin/ni_media/downloads/pdf/VAFilterDesign_2.1.0.pdf
- Unreal FSVFCoefficients (cites the Cytomic SVF paper): https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/SignalProcessing/FDynamicStateVariableFilter/FSVFCoefficients
- chowdsp StateVariableFilter: https://ccrma.stanford.edu/~jatin/chowdsp/chowdsp_utils/classchowdsp_1_1StateVariableFilter.html
- Välimäki & Liski, ACGE (DBLP): https://dblp.uni-trier.de/pid/194/6504.html
- Liski & Välimäki, The Quest for the Best Graphic Equalizer (DAFx-17): https://dafx.de/paper-archive/details/Ycir51R86FWcfPNqrjV2kQ
- Neurally Controlled Graphic Equalizer (2019): https://acris.aalto.fi/ws/portalfiles/portal/40860405/V_lim_ki_Neurally_Controlle_Graphic_Equalizer.08809819_1.pdf
- Third-octave and Bark GEQ (2020): https://research.aalto.fi/fi/publications/third-octave-and-bark-graphic-equalizer-design-with-symmetric-ban/
- Partitioned convolution survey (CNMAT 2010): https://www.cnmat.berkeley.edu/sites/default/files/attachments/2010_advances-in-the-parallelization-of-music-and-audio.pdf
- Farina et al., Mohonk 2001: https://angelofarina.it/Public/papers/164-Mohonk2001.PDF

**Apple platform and Arm**
- Apple vDSP_biquad: https://developer.apple.com/documentation/accelerate/vdsp_biquad.md
- Apple vDSP_biquadD: https://developer.apple.com/documentation/accelerate/vdsp_biquadd.md
- Apple vDSP_biquadm: https://developer.apple.com/documentation/accelerate/vdsp_biquadm.md
- Apple FFT on interleaved complex data: https://developer.apple.com/documentation/accelerate/performing-fourier-transforms-on-interleaved-complex-data.md
- About vDSP: https://developer.apple.com/library/mac/documentation/Performance/Conceptual/vDSP_Programming_Guide/About_vDSP/About_vDSP.html
- Arm FPCR reference: https://df.lth.se/~getz/ARM/SysReg/AArch64-fpcr.html
- WebKit DenormalDisabler: https://crrev.com/4a8a7ad6155544b087fdedff4bcb4e4a5a35bbd1/third_party/WebKit/Source/platform/audio/DenormalDisabler.h
- Blender aarch64 FTZ commit: https://developer.blender.org/rB4b5195a9d75ac1cef101f902c9866e07e75193bb
- Apple workgroup management: https://developer.apple.com/documentation/audiotoolbox/workgroup-management.md
- Apple, adding parallel real-time threads to audio workgroups: https://developer.apple.com/documentation/audiotoolbox/adding-parallel-real-time-threads-to-audio-workgroups.md
- Apple, porting audio code to Apple silicon: https://developer.apple.com/documentation/apple-silicon/porting-your-audio-code-to-apple-silicon.md
- Apple forums, joining the HAL workgroup: https://developer.apple.com/forums/thread/697874
- AudioCap (Core Audio taps): https://github.com/insidegui/AudioCap
- Recall.ai on Core Audio taps: https://www.recall.ai/blog/core-audio-taps

**Headphone correction and device detection**
- AutoEq: https://github.com/jaakkopasanen/AutoEq
- AutoEq targets folder: https://github.com/jaakkopasanen/AutoEq/tree/master/targets
- PipeWire parametric-equalizer module (AutoEq format): https://man.archlinux.org/man/libpipewire-module-parametric-equalizer.7.en
- Equalizer APO configuration reference: https://sourceforge.net/p/equalizerapo/wiki/Configuration%20reference/
- Harman IE preference model (AES 143): https://www.sportsvideo.org/2017/09/21/best-paper-awards-announced-for-upcoming-aes-new-york-convention/
- AES e-library, Harman IE paper: https://aes2.org/publications/elibrary-page/?id=19436
- The Apple Wiki, models and identifiers: https://theapplewiki.com/wiki/Models
- MacRumors, AirPods Pro 3 misidentified: https://forums.macrumors.com/threads/computer-identifies-airpod-pro-3-as-airpod-pro-2.2474638/

**Loudness**
- ITU-R BS.1770-5: https://www.itu.int/rec/R-REC-BS.1770-5-202311-I
- EBU Tech 3341: https://tech.ebu.ch/docs/tech/tech3341.pdf
- Wikipedia, EBU R 128: https://en.wikipedia.org/wiki/EBU_R_128
- Audacity manual, EBU R128: https://manual.audacityteam.org/man/perceived_loudness_ebu_r_128.html
- ARIB TR-B32: https://arib.or.jp/english/std_tr/broadcasting/desc/tr-b32.html
- Sound On Sound, streaming loudness Q&A: https://www.soundonsound.com/sound-advice/q-how-loud-should-master-tracks-intended-streaming

**Enhancement and spatial**
- Larsen & Aarts 2002 (TU/e): https://research.tue.nl/en/publications/reproducing-low-pitched-signals-through-small-loudspeakers/
- Larsen & Aarts 2002 (AES): https://aes2.org/publications/elibrary-page/?id=11088
- Virtual bass, DAFx 2020: https://acris.aalto.fi/ws/portalfiles/portal/51973173/Eloi2020_Virtual_bass_DAFx2020.pdf
- bs2b: https://bs2b.sourceforge.net/
- libbs2b on MacPorts: https://ports.macports.org/port/libbs2b/
- bs2b Rust crate: https://docs.rs/crate/bs2b/0.2.0
- Modified Linkwitz Crossfeed: https://tangentsoft.com/audio/mlxfeed.html
- HUTUBS: https://depositonce.tu-berlin.de/items/dc2a3076-a291-417e-97f0-7697e332c960/full
- SADIE (original, Apache-2.0): https://www.york.ac.uk/sadie-project/database_old.html
- SADIE II project page: https://www.york.ac.uk/sadie-project/database.html
- SADIE II on Zenodo: https://zenodo.org/records/10886409
- MIT KEMAR hrtfdoc: https://sound.media.mit.edu/resources/KEMAR/hrtfdoc.txt
- MIT KEMAR FAQ: https://sound.media.mit.edu/resources/KEMAR/KEMAR-FAQ.txt
- SOFA (ÖAW): https://www.oeaw.ac.at/isf/forschung/hoeren/laufende-projekte/sofa-spatially-oriented-format-for-acoustics
- IANA audio/sofa: https://iana.org/assignments/media-types/audio/sofa
- libmysofa: https://github.com/hoene/libmysofa
- Avendano & Jot upmix (AES): https://aes2.org/publications/elibrary-page/?id=13016
- US7412380 ambience extraction patent: https://patents.google.com/patent/US7412380

**MacBook speakers**
- Asahi audio userspace docs: https://asahilinux.org/docs/sw/audio-userspace/
- asahi-audio: https://github.com/chadmed/asahi-audio
- speakersafetyd: https://github.com/chadmed/speakersafetyd
- Hacker News discussion: https://hn.svelte.dev/item/42021237

**Real time**
- LWN on Bencina's real-time audio article: https://lwn.net/Articles/453005/
- HIIR fork (unevens): https://github.com/unevens/hiir
- Rust halfband crate: https://docs.rs/halfband

**ML**
- HS-TasNet: https://arxiv.org/abs/2402.17701v1
- RT-STT: https://arxiv.org/abs/2511.13146v1
- HTDemucs: https://export.arxiv.org/pdf/2211.08553
- DeepFilterNet2: https://arxiv.org/abs/2205.05474v1
- DeepFilterNet3: https://arxiv.org/abs/2305.08227v1
- DeepFilterNet3 MLX port: https://huggingface.co/aufklarer/DeepFilterNet3-MLX
- DeepFilterNet3 CoreML port: https://huggingface.co/aufklarer/DeepFilterNet3-CoreML/commit/a9ec0b667af0653d31598b459a46fb65527ecfcf
- DAFx26, real-time neural audio on Apple Silicon: https://www.dafx.de/paper-archive/2026/papers/DAFx26_paper_16.pdf
- DAFx26 paper details: https://dafx.de/paper-archive/details/rBxXewYH3YxRTiGXqSabwQ
- ANE benchmark preprint: https://engrxiv.org/preprint/view/6814
- Apple SNClassifySoundRequest: https://developer.apple.com/documentation/soundanalysis/snclassifysoundrequest.md
- Zenn, SoundAnalysis built-in classifier: https://zenn.dev/shu223/articles/soundanalysis-builtin
- Apple forums, SoundAnalysis background failure: https://developer.apple.com/forums/thread/811582
- TechCrunch, tvOS 18 Enhance Dialogue: https://techcrunch.com/2024/06/10/apple-tv-insight-feature-wwdc-2024
- GSMArena, tvOS 18: https://www.gsmarena.com/tvos_18_brings_insight_enhanced_dialogue_and_219_support-news-63228.php

**Competitors**
- Boom 3D review (Hongkiat): https://www.hongkiat.com/blog/boom3d-mac-review/
- Boom 3D (9to5Mac): https://9to5mac.com/?p=549661
- Setapp, Boom 3D: https://setapp.com/how-to/boost-mac-volume-with-boom-3d
- FxSound blog: https://www.fxsound.com/blog
- FxSound README: https://raw.githubusercontent.com/fxsound2/fxsound-app/main/README.md
