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
  double meanDb_ = -200.0;  // not yet initialised (double: at 192 kHz the
                            // 60 s coefficient is ~1e-7, below float resolution)
  double warmCoeff_ = 0.0;
  int warmSamples_ = 0;    // audible samples seen; the average learns fast at first
  float gainDb_ = 0.f;
  float powerCoeff_ = 0.f, attackCoeff_ = 0.f, releaseCoeff_ = 0.f;
  double riseCoeff_ = 0.0, fallCoeff_ = 0.0;
  Smoothed active_;
  std::atomic<float> cutDb_{0.f};
};

// ---------------------------------------------------------------- Ear Protector

// Opt-in guard against sudden blasts (a jump-scare, a notification at full
// scale, a stream that starts 30 dB hotter). When the instantaneous peak
// leaps far above the recent level and is loud in absolute terms, the
// output drops ~20 dB within a millisecond, holds for a few seconds so the
// listener can reach for mute, then eases back. Normal music never trips it.
struct SpikeGuardParams {
  bool enabled = false;
  float riseDb = 20.f;      // jump above the recent level that counts as a spike
  float floorDb = -6.f;     // and it must be at least this loud (dBFS)
  float cutDb = 20.f;       // how far it turns down
  float holdSeconds = 3.f;

  friend bool operator==(const SpikeGuardParams&, const SpikeGuardParams&) = default;
};

class SpikeGuard {
 public:
  void prepare(double sampleRate);
  void reset();
  void setParams(const SpikeGuardParams& p) { p_ = p; }
  void process(float* const* ch, int numChannels, int numFrames);
  uint32_t events() const { return events_.load(std::memory_order_relaxed); }
  bool engaged() const { return holdLeft_ > 0 || gain_ < 0.99f; }

 private:
  double sampleRate_ = 48000.0;
  SpikeGuardParams p_;
  float fast_ = 0.f, slow_ = 0.f;
  float fastRel_ = 0.f, slowCoeff_ = 0.f, attack_ = 0.f, release_ = 0.f;
  float gain_ = 1.f;
  int holdLeft_ = 0;
  int warm_ = 0;
  std::atomic<uint32_t> events_{0};
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
  // Sweep filter: a low-pass and a high-pass that both keep running, each
  // weighted by its side of the knob, so sweeping through centre never
  // swaps one filter's state into the other (no click).
  Smoothed filterPos_, filterWet_;
  SvfCoeffs lpF_, hpF_;
  float filtFor_ = 1e9f;
  std::array<SvfState, kMaxChannels> lpState_{}, hpState_{};
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
