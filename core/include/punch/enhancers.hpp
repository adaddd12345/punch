// "Character" processors: the things Boom-style apps market as Boom /
// Fidelity / Ambience / 3D. Each is cheap (a handful of SVF ticks per frame)
// and has a single 0..1 amount so it maps directly onto a UI slider.
#pragma once

#include <array>

#include "punch/dsp_util.hpp"
#include "punch/parametric_eq.hpp"
#include "punch/svf.hpp"

namespace punch {

// Psychoacoustic bass ("missing fundamental"). Small speakers (MacBook,
// earbuds) cannot reproduce ~40-100 Hz at volume, but the ear infers a
// fundamental from its harmonic series. We isolate the low band, generate
// harmonics with an asymmetric soft saturator (even + odd orders), band-limit
// them into the range the speaker can play, and mix them in. Far less
// excursion/clipping than a raw +12 dB low shelf.
struct BassEnhancerParams {
  float amount = 0.f;        // 0..1 harmonic mix
  float cutoffHz = 120.f;    // upper edge of the band fed to the harmonic generator
  float drive = 4.f;         // saturator input gain
  bool enabled = false;

  friend bool operator==(const BassEnhancerParams&, const BassEnhancerParams&) = default;
};

class BassEnhancer {
 public:
  void prepare(double sampleRate, int numChannels);
  void reset();
  void setParams(const BassEnhancerParams& p);
  void process(float* const* ch, int numChannels, int numFrames);

 private:
  double sampleRate_ = 48000.0;
  int numChannels_ = 2;
  BassEnhancerParams p_;
  SvfCoeffs lowBand_, harmHp_, harmLp_;
  struct Chan { SvfState lp1, lp2, hp, lp; };
  std::array<Chan, kMaxChannels> st_{};
  Smoothed amount_;
};

// Mid/side stereo width. width 1 = unchanged, 0 = mono, up to 2 = wide.
// Side is high-passed before boosting so widening never smears the bass
// (keeps mono compatibility and avoids phasey low end).
struct StereoParams {
  float width = 1.f;
  float sideHighpassHz = 180.f;
  bool enabled = false;

  friend bool operator==(const StereoParams&, const StereoParams&) = default;
};

class StereoWidener {
 public:
  void prepare(double sampleRate);
  void reset();
  void setParams(const StereoParams& p);
  // Operates on channels 0/1 only.
  void process(float* const* ch, int numChannels, int numFrames);

 private:
  double sampleRate_ = 48000.0;
  StereoParams p_;
  SvfCoeffs sideHp_;
  SvfState hpState_;
  Smoothed width_;
};

// Headphone crossfeed (Bauer-style): feeds a low-passed, slightly delayed
// copy of each channel into the other, reducing the "inside the head"
// fatigue of hard-panned stereo on headphones. Only engaged on headphone
// routes.
struct CrossfeedParams {
  float amount = 0.f;       // 0..1, ~0.3 is a typical "natural" setting
  float cutoffHz = 700.f;
  bool enabled = false;

  friend bool operator==(const CrossfeedParams&, const CrossfeedParams&) = default;
};

class Crossfeed {
 public:
  void prepare(double sampleRate);
  void reset();
  void setParams(const CrossfeedParams& p);
  void process(float* const* ch, int numChannels, int numFrames);

 private:
  double sampleRate_ = 48000.0;
  CrossfeedParams p_;
  SvfCoeffs lp_;
  // Fixed ~0.3 ms interaural delay.
  static constexpr int kMaxDelay = 64;
  std::array<float, kMaxDelay> dl_{}, dr_{};
  int delay_ = 14, pos_ = 0;
  SvfState sl_, sr_;
  Smoothed amount_;
};

}  // namespace punch
