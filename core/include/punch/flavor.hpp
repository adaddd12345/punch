// Flavours: a bass character (Distort / Punch) and the Late Night mode.
//
// BassCharacter reshapes only the low band and adds the change back:
//   out_c = x_c + mix * (lowMono - low_c + hp(processed - lowMono))
// so with mix 0 nothing is touched (bit-exact skip), the LR4 split's phase
// never reaches the highs, and the lows end up mono. Switching kind ramps
// the mix down, swaps, and ramps back up (~25 ms each way).
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
  void updateCoeffs(float amount);
  float distort(float low);
  float punch(float low);

  double sampleRate_ = 48000.0;
  int numChannels_ = 2;
  BassCharacterParams p_;
  BassCharacterKind active_ = BassCharacterKind::Off;  // kind being rendered
  float mix_ = 0.f, mixStep_ = 0.f;                    // linear switch ramp
  Smoothed amount_, driveScale_;
  float coeffAmount_ = -1.f;  // amount the filters were last built for

  SvfCoeffs split_, diffHp_, post_, dip_;
  struct Chan { SvfState lp1, lp2, dip; };
  std::array<Chan, kMaxChannels> st_{};
  SvfState diffHpState_, postState_;

  // Distort
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
