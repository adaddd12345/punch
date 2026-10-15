// Flavours: a bass character (Distort / Punch) and the Late Night mode.
//
// BassCharacter reshapes only the bass, and the stereo image of the bass
// stays exactly where the mix put it (side bass is never raised). With mix 0 nothing is touched (bit-exact skip). Switching kind
// ramps the mix down, swaps, and ramps back up (~25 ms each way).
//   * The low band comes from a low-delay split (three "1 - high-pass"
//     sections at 100 Hz): 1.6-2.0 ms of group delay at 40-150 Hz instead
//     of an LR4's 4.2-4.6 ms, so Distort's grit lands on the kick instead
//     of after it. (Faster still lets the low mids into the shaper.)
//   * Distort adds (distorted low - low): the dry bass is never delayed.
//   * What is added is computed once from the mid and shared out by each
//     channel's share of the bass level (50 ms), so a bass that leans to
//     one side keeps its lean and phase, and a centred one stays centred.
//   * Punch moves a low shelf (a minimum-phase EQ on each channel, same
//     coefficients) instead of adding a gained LR4 band, so a boost can't
//     cancel against the dry signal near the crossover (no 150 Hz notch).
//
// LateNight is a mellow, "underwater" master tone (OVO-style late-night
// mixes): low shelf + 300 Hz dip, light tape saturation, 2:1 glue
// compression, a 12 dB/oct low-pass that slides 5 kHz -> 2.5 kHz with Haze,
// and a short damped room with a widened return. It blends in over ~300 ms.
//
// Both are real-time safe after prepare() and bit-exact when off.
#pragma once

#include <array>
#include <cstdint>

#include "punch/character.hpp"
#include "punch/dsp_util.hpp"
#include "punch/parametric_eq.hpp"  // kMaxChannels
#include "punch/svf.hpp"

namespace punch {

// ------------------------------------------------------------ bass character

enum class BassCharacterKind : std::uint8_t { Off = 0, Distort = 1, Punch = 2 };

struct BassCharacterParams {
  BassCharacterKind kind = BassCharacterKind::Off;
  float amount = 0.6f;     // 0..1
  float driveScale = 1.f;  // 0..1: caps Distort's drive (Late Night uses 0.6)

  friend bool operator==(const BassCharacterParams&, const BassCharacterParams&) = default;
};

class BassCharacter {
 public:
  void prepare(double sampleRate, int numChannels);
  void reset();
  void setParams(const BassCharacterParams& p);
  void process(float* const* ch, int numChannels, int numFrames);

 private:
  struct Chan {
    std::array<SvfState, 3> split;  // three "1 - HP" sections
    float ms = 0.f;      // low-band mean square (where the bass sits)
    SvfState shelf, dip;
  };

  void updateCoeffs(float amount);
  float distort(float low, float drive, float bias);
  float punchGainDb(float low);
  void buildShelf(float db);
  float splitLow(Chan& s, float x);
  void updateWeights(int numChannels);

  double sampleRate_ = 48000.0;
  int numChannels_ = 2;
  BassCharacterParams p_;
  BassCharacterKind active_ = BassCharacterKind::Off;  // kind being rendered
  float mix_ = 0.f, mixStep_ = 0.f;                    // linear switch ramp
  Smoothed amount_, driveScale_;
  float coeffAmount_ = -1.f;  // amount the filters were last built for

  // Per channel: the low-delay split, the bass level (for the weights) and
  // Punch's shelf and dip. The shaper runs once, on the mid's lows.
  SvfCoeffs split_, post_, dip_, shelf_;
  float dcCoeff_ = 0.f, dc_ = 0.f;        // 3 Hz DC blocker on the added part
  float shelfW_ = 0.f;                    // tan(pi * shelf Hz / fs)
  float shelfDb_ = 0.f, warmGain_ = 1.f;  // what the shelf was last built for
  float msCoeff_ = 0.f;                   // 50 ms bass-level follower
  std::array<float, kMaxChannels> weight_{};
  std::array<Chan, kMaxChannels> st_{};
  SvfState postState_;
  double prevU_ = 0.0;
  float envRaw_ = 0.f, envWet_ = 0.f, envCoeff_ = 0.f;
  // Punch
  float eFast_ = 0.f, eSlowAtt_ = 0.f, eLong_ = 0.f, gDb_ = 0.f;
  float aFast_ = 0.f, aSlow_ = 0.f, rShort_ = 0.f, rLong_ = 0.f, gSmooth_ = 0.f;
};

// ------------------------------------------------------------ late night

struct LateNightParams {
  bool enabled = false;
  float haze = 0.5f;  // 0..1

  friend bool operator==(const LateNightParams&, const LateNightParams&) = default;
};

class LateNight {
 public:
  void prepare(double sampleRate, int numChannels);
  void reset();
  void setParams(const LateNightParams& p);
  void process(float* const* ch, int numChannels, int numFrames);
  bool active() const { return !(fade_ == 0.f && fadeTarget_ == 0.f); }

 private:
  void updateCoeffs(float haze);

  double sampleRate_ = 48000.0;
  int numChannels_ = 2;
  LateNightParams p_;
  float fade_ = 0.f, fadeTarget_ = 0.f, fadeStep_ = 0.f;  // 300 ms linear "dim"
  Smoothed haze_;
  float coeffHaze_ = -1.f;
  float satGain_ = 1.f, satNorm_ = 1.f;
  SvfCoeffs lowShelf_, dip_, lpf_, dcBlock_, scHp_;
  struct Chan { SvfState shelf, dip, lpf, dc, sc; };
  std::array<Chan, kMaxChannels> st_{};
  float envDb_ = 0.f, compAtt_ = 0.f, compRel_ = 0.f;
  Ambience room_;
};

}  // namespace punch
