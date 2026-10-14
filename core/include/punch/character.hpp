// Character processors for modes and genre presets: compressor (sleep /
// study smoothing), saturator (underground "distort"), noise bed (sleep /
// focus masking) and ambience (early reflections + short diffuse tail).
// All real-time safe after prepare(); each glides its amount so toggling a
// mode never clicks.
#pragma once

#include <array>
#include <cstdint>
#include <vector>

#include "punch/dsp_util.hpp"
#include "punch/parametric_eq.hpp"  // kMaxChannels
#include "punch/svf.hpp"

namespace punch {

// ---------------------------------------------------------------- compressor

struct CompressorParams {
  float thresholdDb = -18.f;
  float ratio = 2.f;
  float attackMs = 10.f;
  float releaseMs = 150.f;
  float kneeDb = 6.f;
  float makeupDb = 0.f;
  float sidechainHpHz = 0.f;  // >0: detector ignores lows (808s don't pump the mix)
  bool enabled = false;

  friend bool operator==(const CompressorParams&, const CompressorParams&) = default;
};

// Feed-forward, channel-linked, soft-knee compressor with log-domain
// attack/release smoothing.
class Compressor {
 public:
  void prepare(double sampleRate);
  void reset();
  void setParams(const CompressorParams& p);
  void process(float* const* ch, int numChannels, int numFrames);
  float gainReductionDb() const { return grDb_; }

  // Static curve (exposed for tests): gain change in dB for input level dB.
  static float computeGainDb(float levelDb, float thresholdDb, float ratio, float kneeDb);

 private:
  double sampleRate_ = 48000.0;
  CompressorParams p_;
  float attackCoeff_ = 0.f, releaseCoeff_ = 0.f;
  float envDb_ = 0.f;     // smoothed gain reduction (<= 0)
  float grDb_ = 0.f;
  Smoothed mix_;          // 0 = bypassed, 1 = fully applied (click-free toggle)
  Smoothed makeup_;
  SvfCoeffs scHp_;
  std::array<SvfState, kMaxChannels> scState_{};
};

// ---------------------------------------------------------------- saturator

struct SaturatorParams {
  float driveDb = 0.f;     // 0..30
  float mix = 0.f;         // 0..1 wet
  float toneHz = 12000.f;  // low-pass on the wet path (tames fizz)
  float asymmetry = 0.2f;  // 0..1: adds even harmonics ("warm/gritty")
  float crossoverHz = 0.f; // >0: only content above this is saturated (clean sub/808)
  bool enabled = false;

  friend bool operator==(const SaturatorParams&, const SaturatorParams&) = default;
};

// tanh waveshaper with first-order antiderivative anti-aliasing (ADAA):
// y[n] = (F(u[n]) - F(u[n-1])) / (u[n] - u[n-1]), F(u) = log(cosh(u)).
// Suppresses most aliasing without oversampling. Small-signal gain is
// normalised to unity so the mix knob changes character, not loudness.
class Saturator {
 public:
  void prepare(double sampleRate, int numChannels);
  void reset();
  void setParams(const SaturatorParams& p);
  void process(float* const* ch, int numChannels, int numFrames);

 private:
  double sampleRate_ = 48000.0;
  int numChannels_ = 2;
  SaturatorParams p_;
  float gain_ = 1.f, bias_ = 0.f, norm_ = 1.f, biasOut_ = 0.f;
  SvfCoeffs tone_, dcBlock_, split_;
  bool splitBand_ = false;
  struct Chan { float prevU = 0.f; SvfState tone, dc, split; };
  std::array<Chan, kMaxChannels> st_{};
  Smoothed mix_;
};

// ---------------------------------------------------------------- noise bed

enum class NoiseColor : std::uint8_t { White = 0, Pink, Brown };

struct NoiseParams {
  NoiseColor color = NoiseColor::Pink;
  float levelDb = -36.f;  // RMS level in dBFS
  bool enabled = false;

  friend bool operator==(const NoiseParams&, const NoiseParams&) = default;
};

// Decorrelated stereo noise. Pink: Paul Kellet's refined filter (-3 dB/oct
// within ±0.05 dB above 10 Hz). Brown: leaky-integrated white (-6 dB/oct).
// Output is normalised to the requested RMS level per colour.
class NoiseBed {
 public:
  void prepare(double sampleRate);
  void reset();
  void setParams(const NoiseParams& p);
  // Adds noise into the channels.
  void process(float* const* ch, int numChannels, int numFrames);

 private:
  struct Gen {
    std::uint32_t rng = 0x9E3779B9u;
    float b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0;  // pink
    float brown = 0;
    float next(NoiseColor c);
  };
  double sampleRate_ = 48000.0;
  NoiseParams p_;
  std::array<Gen, 2> gen_{};
  Smoothed level_;
  SvfCoeffs hp_;  // 20 Hz high-pass: keeps brown noise from wandering DC
  std::array<SvfState, 2> hpState_{};
};

// ---------------------------------------------------------------- ambience

struct AmbienceParams {
  float mix = 0.f;        // 0..1
  float size = 0.5f;      // 0..1 (≈ small room .. large hall reflections)
  float dampingHz = 7000.f;
  bool enabled = false;
  float returnWidth = 1.f;  // M/S width of the reverb return only (1 = as built)

  friend bool operator==(const AmbienceParams&, const AmbienceParams&) = default;
};

// Stereo early reflections (cross-fed taps) followed by two allpass
// diffusers per channel and a damping low-pass. Deliberately short (no long
// tail) so it adds space without washing out music.
class Ambience {
 public:
  void prepare(double sampleRate);
  void reset();
  void setParams(const AmbienceParams& p);
  void process(float* const* ch, int numChannels, int numFrames);

 private:
  static constexpr int kTaps = 6;
  static constexpr int kAllpasses = 2;
  struct Allpass {
    std::vector<float> buf;
    int pos = 0;
    float g = 0.6f;
    float tick(float x);
  };
  double sampleRate_ = 48000.0;
  AmbienceParams p_;
  std::array<std::vector<float>, 2> delay_;
  int delayPos_ = 0;
  int delayLen_ = 1;
  std::array<int, kTaps> tapL_{}, tapR_{};
  std::array<float, kTaps> tapGain_{};
  std::array<std::array<Allpass, kAllpasses>, 2> ap_;
  SvfCoeffs damp_;
  std::array<SvfState, 2> dampState_{};
  Smoothed mix_;
};

}  // namespace punch
