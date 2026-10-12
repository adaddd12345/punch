// Night Guard (relative loudness guard) and the DJ effects.
// Real-time safe after prepare(); every switch glides, so pads never click.
#pragma once

#include <array>
#include <atomic>
#include <vector>

#include "punch/dsp_util.hpp"
#include "punch/parametric_eq.hpp"  // kMaxChannels
#include "punch/svf.hpp"

namespace punch {

// ---------------------------------------------------------------- Night Guard

struct LoudnessGuardParams {
  float overDb = 8.f;     // allowed rise above the running average loudness
  float maxCutDb = 20.f;  // most it will turn things down
  bool enabled = false;

  friend bool operator==(const LoudnessGuardParams&, const LoudnessGuardParams&) = default;
};

// Keeps sudden loud stretches (a title sequence after quiet dialogue, an ad
// break, an explosion) from jumping more than `overDb` above what you've
// been listening to. Short-term loudness (K-weighting approximation, ~0.2 s)
// is compared with a slow running average (rises over ~60 s, falls over
// ~15 s, ignores silence); anything above average + overDb is turned down
// with a fast attack (~60 ms) and a gentle release (~1.5 s).
class LoudnessGuard {
 public:
  void prepare(double sampleRate);
  void reset();
  void setParams(const LoudnessGuardParams& p);
  void process(float* const* ch, int numChannels, int numFrames);
  float cutDb() const { return cutDb_.load(std::memory_order_relaxed); }  // <= 0

 private:
  double sampleRate_ = 48000.0;
  LoudnessGuardParams p_;
  SvfCoeffs kHp_, kShelf_;
  std::array<SvfState, kMaxChannels> hpState_{}, shelfState_{};
  double power_ = 0.0;
  float meanDb_ = -200.f;  // not yet initialised
  float warmCoeff_ = 0.f;
  int warmSamples_ = 0;    // audible samples seen; the average learns fast at first
  float gainDb_ = 0.f;
  float powerCoeff_ = 0.f, riseCoeff_ = 0.f, fallCoeff_ = 0.f, attackCoeff_ = 0.f, releaseCoeff_ = 0.f;
  Smoothed active_;
  std::atomic<float> cutDb_{0.f};
};

// ---------------------------------------------------------------- DJ effects

struct DjParams {
  bool lowKill = false;   // isolator: bass  (< 250 Hz)
  bool midKill = false;   //           mids  (250 Hz - 3 kHz)
  bool highKill = false;  //           highs (> 3 kHz)
  float filter = 0.f;     // -1..1: <0 low-pass sweep, >0 high-pass sweep, 0 off
  bool echo = false;      // 3/8 s echo with feedback (tail rings out when released)
  bool crush = false;     // bit-crusher / sample-rate reducer
  bool drive = false;     // hard tanh distortion

  friend bool operator==(const DjParams&, const DjParams&) = default;
};

class DjFx {
 public:
  void prepare(double sampleRate, int numChannels);
  void reset();
  void setParams(const DjParams& p);
  void process(float* const* ch, int numChannels, int numFrames);

 private:
  void updateFilter(float v);

  double sampleRate_ = 48000.0;
  int numChannels_ = 2;
  DjParams p_;
  // Isolator: Linkwitz-Riley 4 tree (250 Hz, 3 kHz), bands phase-aligned;
  // bypassed entirely (bit-exact) while no kill is engaged.
  SvfCoeffs lp250_, hp250_, lp3k_, hp3k_;
  struct IsoChan { SvfState a1, a2, b1, b2, c1, c2, d1, d2, e1, e2, f1, f2; };
  std::array<IsoChan, kMaxChannels> iso_{};
  Smoothed gLow_, gMid_, gHigh_, isoWet_;
  // Sweep filter.
  Smoothed filterPos_, filterWet_;
  SvfCoeffs filt_;
  float filtFor_ = 0.f;
  std::array<SvfState, kMaxChannels> filtState_{};
  // Echo.
  std::array<std::vector<float>, kMaxChannels> delay_;
  int delayPos_ = 0, delayLen_ = 1;
  Smoothed echoSend_;
  SvfCoeffs echoTone_;
  std::array<SvfState, kMaxChannels> echoToneState_{};
  // Crush / drive.
  Smoothed crushMix_, driveMix_;
  std::array<float, kMaxChannels> held_{};
  int holdCount_ = 0;
  int echoTail_ = 0;
};

}  // namespace punch
