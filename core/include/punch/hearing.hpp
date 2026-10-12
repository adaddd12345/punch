// Hearing Fit: gentle per-ear (L/R) compensation at six fixed frequencies.
// Low shelf at 250 Hz, bells at 500/1k/2k/4k, high shelf at 8 kHz, each
// boost-only and capped at +10 dB. Gains glide (Smoothed, ~40 ms) and
// coefficients are recomputed per sub-block while moving. When disabled and
// settled the stage is skipped entirely (bit-exact bypass).
#pragma once

#include <algorithm>

#include "punch/dsp_util.hpp"
#include "punch/svf.hpp"

namespace punch {

inline constexpr int kHearingBands = 6;
inline constexpr float kHearingFreqs[kHearingBands] = {250.f, 500.f, 1000.f, 2000.f, 4000.f, 8000.f};
inline constexpr float kHearingMaxDb = 10.f;

struct HearingParams {
  bool enabled = false;
  float gainDb[2][kHearingBands] = {};  // [0]=left, [1]=right
  friend bool operator==(const HearingParams&, const HearingParams&) = default;
};

class HearingFit {
 public:
  void prepare(double sampleRate) {
    sampleRate_ = sampleRate;
    for (auto& ch : gain_)
      for (auto& g : ch) g.prepare(sampleRate, 40.0);
    snapToTargets();
    reset();
  }

  void setParams(const HearingParams& p) {
    for (int c = 0; c < 2; ++c)
      for (int b = 0; b < kHearingBands; ++b)
        gain_[c][b].setTarget(p.enabled ? std::clamp(p.gainDb[c][b], 0.f, kHearingMaxDb) : 0.f);
  }

  void snapToTargets() {
    for (int c = 0; c < 2; ++c) {
      for (int b = 0; b < kHearingBands; ++b) gain_[c][b].snap(gain_[c][b].target());
      updateCoeffs(c);
    }
  }

  bool active() const {
    for (const auto& ch : gain_)
      for (const auto& g : ch)
        if (!(g.settled() && g.current() == 0.f)) return true;
    return false;
  }

  static FilterSpec spec(int band, float db) {
    const FilterType t = band == 0 ? FilterType::LowShelf
                         : band == kHearingBands - 1 ? FilterType::HighShelf
                                                     : FilterType::Bell;
    // Wide (gentle) bells: Q ~0.9 spans roughly an octave and a half.
    return {t, double(kHearingFreqs[band]), double(db), t == FilterType::Bell ? 0.9 : 0.7071, true};
  }

  // Exact magnitude (dB) of one channel's current curve at hz (tests/UI).
  double magnitudeDb(int c, double hz) const {
    double db = 0;
    for (int b = 0; b < kHearingBands; ++b) db += coeffs_[c][b].magnitudeDb(hz, sampleRate_);
    return db;
  }

  void process(float* const* ch, int numChannels, int numFrames) {
    if (!active()) return;
    const int nc = std::min(numChannels, 2);
    constexpr int kSub = 32;
    for (int start = 0; start < numFrames; start += kSub) {
      const int n = std::min(kSub, numFrames - start);
      for (int c = 0; c < 2; ++c) {
        bool moving = false;
        for (int b = 0; b < kHearingBands; ++b) {
          if (!gain_[c][b].settled()) {
            moving = true;
            for (int i = 0; i < n; ++i) gain_[c][b].next();
          }
        }
        if (moving) updateCoeffs(c);
      }
      for (int c = 0; c < nc; ++c) {
        float* x = ch[c] + start;
        for (int b = 0; b < kHearingBands; ++b) {
          if (gain_[c][b].settled() && gain_[c][b].current() == 0.f) continue;
          auto& s = state_[c][b];
          const auto& k = coeffs_[c][b];
          for (int i = 0; i < n; ++i) x[i] = s.tick(k, x[i]);
        }
      }
    }
  }

  void reset() {
    for (auto& ch : state_)
      for (auto& s : ch) s.reset();
  }

 private:
  void updateCoeffs(int c) {
    for (int b = 0; b < kHearingBands; ++b) coeffs_[c][b] = SvfCoeffs::make(spec(b, gain_[c][b].current()), sampleRate_);
  }

  double sampleRate_ = 48000.0;
  Smoothed gain_[2][kHearingBands];
  SvfCoeffs coeffs_[2][kHearingBands];
  SvfState state_[2][kHearingBands];
};

}  // namespace punch
