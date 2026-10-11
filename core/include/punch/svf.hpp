// Trapezoidal-integrated state variable filter (Andy Simper / Cytomic,
// "SvfLinearTrapOptimised2"). Chosen over a Direct Form biquad because:
//   * coefficients can be changed every sample with no zipper noise or
//     transient blow-ups (state is stored as integrator charge, not past
//     outputs), which matters when the user drags an EQ band live;
//   * it stays numerically well-behaved for low cutoffs at high sample
//     rates in single precision, where DF1/DF2 biquads lose precision.
// Frequency response is identical to the RBJ cookbook (bilinear transform
// with prewarping at fc), so magnitude() below is exact.
#pragma once

#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdint>
#include <numbers>

namespace punch {

enum class FilterType : std::uint8_t {
  Bell = 0,
  LowShelf,
  HighShelf,
  LowPass,
  HighPass,
  BandPass,
  Notch,
};

struct FilterSpec {
  FilterType type = FilterType::Bell;
  double freqHz = 1000.0;
  double gainDb = 0.0;  // ignored for LP/HP/BP/Notch
  double q = 0.7071;
  bool enabled = true;

  friend bool operator==(const FilterSpec&, const FilterSpec&) = default;
};

struct SvfCoeffs {
  float a1 = 1.f, a2 = 0.f, a3 = 0.f;
  float m0 = 1.f, m1 = 0.f, m2 = 0.f;
  // Kept in double for exact UI magnitude evaluation.
  double g = 0.0, k = 1.0;
  double dm0 = 1.0, dm1 = 0.0, dm2 = 0.0;

  static SvfCoeffs identity() { return {}; }

  static SvfCoeffs make(const FilterSpec& s, double sampleRate) {
    SvfCoeffs c;
    if (!s.enabled || sampleRate <= 0.0) return c;
    // Keep fc safely below Nyquist; tan() explodes at fs/2.
    const double fc = std::clamp(s.freqHz, 1.0, 0.49 * sampleRate);
    const double q = std::clamp(s.q, 0.025, 40.0);
    const double gainDb = std::clamp(s.gainDb, -30.0, 30.0);
    const double w = std::tan(std::numbers::pi * fc / sampleRate);
    const double A = std::pow(10.0, gainDb / 40.0);

    double g = w, k = 1.0 / q, m0 = 0, m1 = 0, m2 = 0;
    switch (s.type) {
      case FilterType::Bell:
        k = 1.0 / (q * A);
        m0 = 1.0; m1 = k * (A * A - 1.0); m2 = 0.0;
        break;
      case FilterType::LowShelf:
        g = w / std::sqrt(A);
        m0 = 1.0; m1 = k * (A - 1.0); m2 = A * A - 1.0;
        break;
      case FilterType::HighShelf:
        g = w * std::sqrt(A);
        m0 = A * A; m1 = k * (1.0 - A) * A; m2 = 1.0 - A * A;
        break;
      case FilterType::LowPass:
        m0 = 0.0; m1 = 0.0; m2 = 1.0;
        break;
      case FilterType::HighPass:
        m0 = 1.0; m1 = -k; m2 = -1.0;
        break;
      case FilterType::BandPass:  // constant 0 dB peak gain
        m0 = 0.0; m1 = k; m2 = 0.0;
        break;
      case FilterType::Notch:
        m0 = 1.0; m1 = -k; m2 = 0.0;
        break;
    }
    const double a1 = 1.0 / (1.0 + g * (g + k));
    const double a2 = g * a1;
    const double a3 = g * a2;
    c.a1 = float(a1); c.a2 = float(a2); c.a3 = float(a3);
    c.m0 = float(m0); c.m1 = float(m1); c.m2 = float(m2);
    c.g = g; c.k = k; c.dm0 = m0; c.dm1 = m1; c.dm2 = m2;
    return c;
  }

  // Exact digital response at `hz`. Trapezoidal integration == bilinear
  // transform, so the digital response equals the analog prototype
  // evaluated at s = j*tan(pi f / fs) / g.
  std::complex<double> response(double hz, double sampleRate) const {
    if (g == 0.0) return {1.0, 0.0};
    const double om = std::tan(std::numbers::pi * std::min(hz, 0.4999 * sampleRate) / sampleRate) / g;
    const std::complex<double> s(0.0, om);
    const std::complex<double> den = s * s + k * s + 1.0;
    return (dm0 * den + dm1 * s + dm2) / den;
  }

  double magnitudeDb(double hz, double sampleRate) const {
    return 20.0 * std::log10(std::max(std::abs(response(hz, sampleRate)), 1e-12));
  }
};

// One channel of filter state.
struct SvfState {
  float ic1 = 0.f, ic2 = 0.f;

  inline float tick(const SvfCoeffs& c, float v0) {
    const float v3 = v0 - ic2;
    const float v1 = c.a1 * ic1 + c.a2 * v3;
    const float v2 = ic2 + c.a2 * ic1 + c.a3 * v3;
    ic1 = 2.f * v1 - ic1;
    ic2 = 2.f * v2 - ic2;
    return c.m0 * v0 + c.m1 * v1 + c.m2 * v2;
  }

  void reset() { ic1 = ic2 = 0.f; }
};

}  // namespace punch
