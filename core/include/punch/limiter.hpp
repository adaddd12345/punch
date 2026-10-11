#pragma once

#include <array>
#include <atomic>
#include <vector>

#include "punch/parametric_eq.hpp"  // kMaxChannels

namespace punch {

struct LimiterParams {
  float ceilingDb = -1.0f;   // output never exceeds this sample peak
  float releaseMs = 80.0f;
  bool enabled = true;

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
  std::vector<float> boxBuf_;
  int boxPos_ = 0;
  double boxSum_ = 0.0;
  std::atomic<float> lastGrDb_{0.f};
};

}  // namespace punch
