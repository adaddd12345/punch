# 33. EQ measurement views

Implementation semantics as of 2026-10-18. The scope, spectrum, and EQ response describe different quantities and retain separate axes.

## Captured signal and time axis

`Engine::processPlanar` writes the analyzer feed after every engine DSP stage, both limiters, the master fade, and nonfinite-output handling. It averages the processed channels:

\[
x[n]=\frac{1}{C}\sum_{c=1}^{C}y_c[n].
\]

This is mono post-FX PCM, not a stereo maximum, an acoustic measurement, or a measurement of downstream device volume. Opposite-polarity channels can cancel in the mono feed. The ring may drop blocks when its consumer falls behind.

`WaveformModel` targets 60 ms using the running route's sample rate, with 48 kHz as the unavailable-rate fallback. A rising zero crossing stabilizes capture; its search can place the displayed interval before the newest samples. Startup availability and ring capacity can shorten the interval, so the caption reports the actual duration `sampleCount / sampleRate`. Changing rate clears the capture ring. The 32,768-sample ring accommodates the target interval plus trigger search through 192 kHz.

All three measured views partition the same capture into 240 time columns. Their x axis is elapsed time, so they occupy a separate lane below the frequency-response graph. At 48 kHz and 60 ms, each column contains 12 samples, or 0.25 ms.

The shared auto-range multiplier is displayed as `AUTO ×s`. Raw extrema and RMS remain linear PCM values; drawing multiplies them by `s` and clamps to [-1, 1]. This zoom supports shape inspection, not absolute level comparisons between differently scaled frames. When capture stops, the last coherent measurement fades; its amplitudes are not artificially decayed.

## Three measured views

For a column with sample indices \(I_j\) and count \(M_j\):

- **Extrema:** \(l_j=\min_{n\in I_j}x[n]\), \(h_j=\max_{n\in I_j}x[n]\). The signed range and its stair-step boundaries retain actual sample excursions. The filled interval does not imply that samples occupied every amplitude between the bounds.
- **Energy:** \(r_j=\sqrt{M_j^{-1}\sum_{n\in I_j}x[n]^2}\), with \(p_j=\max_{n\in I_j}|x[n]|\). RMS amplitude fills upward from zero at the bottom; a second boundary shows absolute sample peak. These short-column measurements are neither perceived loudness nor intersample true peak. RMS is measured from samples, not inferred from extrema.
- **Density:** \(q_{j,b}=M_j^{-1}\#\{n\in I_j:x[n]\text{ maps to bin }b\}\). There are 24 equal amplitude bins across the displayed signed range, corresponding to [-1/s, 1/s] in PCM units. Out-of-range values enter the endpoint bins. Nonempty columns sum to one. Opacity is \(\sqrt{q_{j,b}}\), not a linear probability scale. This is discrete sample occupancy, without an inferred smooth distribution.

Stored style keys `silk`, `reed`, and `fold` remain compatible with earlier preferences; their displayed names are Extrema, Energy, and Density.

## EQ response and selected-band contribution

The response evaluator uses the actual route sample rate; its cache includes that rate. Frequencies are logarithmically spaced from 20 Hz to 20 kHz:

\[
f_i=20\,10^{3i/(N-1)},\qquad
G(f)=\mathrm{Boost}_{dB}+\sum_b20\log_{10}|H_b(e^{j2\pi f/f_s})|.
\]

The line represents user EQ plus configured Boost only. It does not model downstream saturation, dynamic gain reduction, leveler action, correction, or the rest of the processing chain. The dotted datum is fixed at 0 dB.

For a selected band, Contribution compares the complete response with that band's gain set to zero, retaining every other setting and Boost. The shaded vertical difference is the selected band's dB contribution; it is not an uncertainty interval or a second measured audio signal. Display clipping can truncate the visible separation. The curve represents target parameters, rather than the engine's short coefficient glide during an edit.

## Spectrum calibration and paper basis

[Gareus & Goddard (2014), §§2.1–2.2, 2.7, 2.9](https://lac.linuxaudio.org/2014/papers/24.pdf) establishes the distinctions between sample peak, RMS, true peak, and calibrated waveform displays. [Simper, pp. 6, 18](https://www.cytomic.com/files/dsp/SvfLinearTrapOptimised2.pdf) matches the implemented SVF, including prewarping `g = tan(πfc/fs)`. [Orfanidis (1997), p. 3, Eqs. 9–15](https://www.collinsaudio.com/Prosound_Workshop/orfanidis%20decramping.pdf) explains why high-frequency bandwidth cannot be drawn as an arbitrary symmetric bell. These informed the actual-rate transfer evaluation and denser shared sampling grid.

[Harris (1978), pp. 53–56, Eqs. 6, 11, 16 and Table I](https://web.mit.edu/xiphmont/Public/windows.pdf) separates window leakage, coherent gain, and equivalent noise bandwidth:

\[
B_{ENBW}=f_s\frac{\sum w^2}{(\sum w)^2}.
\]

[Welch (1967), pp. 70–73](https://blog.ioces.com/matt/posts/colouring-noise/welch-1967.pdf) averages window-normalized squared Fourier magnitudes before logarithmic display. Power uses \(10\log_{10}\); amplitude ratios use \(20\log_{10}\).

`SpectrumAnalyzer` now measures the generated Hann's energy \(E_w=\sum w^2\). For Accelerate's real-FFT scaling, its one-sided bin power relative to a full-scale sine is \(|Y_k|^2/(N E_w)\), excluding DC/Nyquist. This removes the previous 4.26 dB mismatch between `vDSP_HANN_NORM` and an ordinary-Hann energy constant. Integrated tone power has the sine reference; individual smoothed peaks need not read 0 dBFS. The existing fixed-bandwidth density conversion, logarithmic frequency mapping, and display ballistics remain separate operations.
