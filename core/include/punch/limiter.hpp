#pragma once

#include <array>
#include <atomic>
#include <vector>

#include "punch/parametric_eq.hpp"  // kMaxChannels
#include "punch/dsp_util.hpp"
#include "punch/svf.hpp"

namespace punch {

struct LimiterParams {
  float ceilingDb = -1.0f;   // output never exceeds this sample peak
  float releaseMs = 80.0f;
  bool enabled = true;
  // Program-dependent release: the gain recovers quickly after isolated
  // transients but only up to a slowly moving average of the recent gain
  // reduction, so sustained bass doesn't make the mix pump between hits.
  float slowReleaseMs = 0.f;  // 0 = off (single release)
  // Soft clipper ahead of the limiter: peaks above (ceiling - clipKneeDb)
  // are rounded off sample by sample (no memory, so no pumping), leaving the
  // limiter far less gain to ride. 0 = off.
  float clipKneeDb = 0.f;
  // Bass-priority limiting: content below this crossover is limited first,
  // against whatever room the mids/highs leave, so boosted kicks and 808s
  // never duck the vocals. 0 = off (plain full-band limiter).
  float bassPriorityHz = 0.f;

  friend bool operator==(const LimiterParams&, const LimiterParams&) = default;
};

// Look-ahead brickwall peak limiter, channel-linked.
//
// Gain computer: per-frame required gain = min(1, ceiling / peak), then a
// sliding-window minimum over L+1 frames, then release smoothing (upward
// only), then a length L+1 moving average. Because the average at any output
// instant only covers frames whose held gain is <= the required gain of the
// sample leaving the delay line, the output is guaranteed not to exceed the
// ceiling while the attack is a smooth linear ramp (no clicks, no overshoot).
// Latency = L frames.
class Limiter {
 public:
  void prepare(double sampleRate, int numChannels, float lookaheadMs = 1.5f);
  void reset();
  void setParams(const LimiterParams& p);
  void process(float* const* channels, int numChannels, int numFrames);
  // Same, but with a per-frame ceiling (linear, <= the configured ceiling).
  void process(float* const* channels, int numChannels, int numFrames, const float* ceilingPerFrame);

  int latencyFrames() const { return lookahead_; }
  // Most recent applied gain reduction in dB (<= 0). Read from any thread
  // for metering.
  float gainReductionDb() const { return lastGrDb_.load(std::memory_order_relaxed); }

 private:
  float pushMin(float v);

  double sampleRate_ = 48000.0;
  int numChannels_ = 2;
  int lookahead_ = 72;
  int window_ = 73;
  LimiterParams params_;
  float ceiling_ = 0.891f;
  float releaseCoeff_ = 0.001f;

  std::array<std::vector<float>, kMaxChannels> delay_;
  int delayPos_ = 0;

  // Monotonic deque for the sliding minimum.
  std::vector<float> dqVal_;
  std::vector<long long> dqIdx_;
  int dqHead_ = 0, dqSize_ = 0;
  long long t_ = 0;

  float released_ = 1.f;
  Smoothed active_;  // 0 = off (pure delay, constant latency), 1 = limiting
  float slow_ = 1.f;
  float slowCoeff_ = 0.f;
  float clipKnee_ = 1.f;   // linear, absolute (ceiling * knee)
  float clipRange_ = 0.f;
  std::vector<float> boxBuf_;
  int boxPos_ = 0;
  double boxSum_ = 0.0;
  std::atomic<float> lastGrDb_{0.f};
};

// Bass-priority limiter. Splits at `crossoverHz` (4th-order low-pass; the
// highs are the exact complement, so the bands sum back bit-exactly), limits the low band against the room the
// highs leave at each instant:
//
//   low gain(t) = max g in [0,1] with |g*low(t) + high(t)| <= ceiling
//
// (exact per sample, so it also uses moments where bass and highs partly
// cancel), and the mids/highs are never turned
// down for the bass. The look-ahead (12 ms) also works as a hold longer than
// half a 40 Hz cycle, so the gain doesn't ripple inside bass waveforms
// (that ripple is what makes fast limiters sound distorted on 808s).
// A full-band limiter after this only catches the rare leftovers (highs that
// are over on their own).
class BassPriorityLimiter {
 public:
  void prepare(double sampleRate, int numChannels, int maxFrames, float lookaheadMs = 12.f);
  void reset();
  void setParams(float ceilingDb, float crossoverHz, float releaseMs, bool limiting);
  void process(float* const* channels, int numChannels, int numFrames);
  int latencyFrames() const { return low_.latencyFrames(); }
  float gainReductionDb() const { return limiting_ ? low_.gainReductionDb() : 0.f; }

 private:
  void processChunk(float* const* ch, int numChannels, int numFrames);

  double sampleRate_ = 48000.0;
  int numChannels_ = 2;
  int chunk_ = 512;
  float ceiling_ = 0.891f;
  bool limiting_ = true;
  SvfCoeffs lp_, hp_;
  struct Chan { SvfState lp1, lp2, hp1, hp2; };
  std::array<Chan, kMaxChannels> st_{};
  Limiter low_;
  std::array<std::vector<float>, kMaxChannels> lowBuf_, dryBuf_, hiDelay_, dryDelay_;
  Smoothed wet_;   // crossfade split path <-> plain delay (bit-exact when off)
  int hiPos_ = 0;
  std::vector<float> ceil_;
};

}  // namespace punch
