// The complete processing chain run inside the Core Audio IOProc.
//
//   in -> device correction EQ (AutoEq / Studio Ears) -> user EQ (with preamp)
//      -> saturator -> compressor -> bass enhancer -> stereo width
//      -> ambience -> crossfeed -> output gain ("boost") -> noise bed
//      -> look-ahead limiter -> out
//
// Correction and user EQ are separate stages so a per-headphone AutoEq
// profile stays applied underneath whatever preset the user picks.
//
// Threading contract:
//   * prepare() / control setters / publish(): one control thread (main).
//   * process*(): the real-time IO thread only. Never allocates or locks.
//   * takeMeters(): any single polling thread.
#pragma once

#include <atomic>
#include <memory>
#include <string_view>
#include <vector>

#include "punch/character.hpp"
#include "punch/enhancers.hpp"
#include "punch/limiter.hpp"
#include "punch/lockfree.hpp"
#include "punch/parametric_eq.hpp"

namespace punch {

struct EngineParams {
  EqParams correction;  // per-output-device (headphone/speaker) correction
  EqParams eq;          // user preset / graphic EQ
  bool autoPreamp = true;  // preamp = min(user preamps, -combined EQ peak boost)
  BassEnhancerParams bass;
  StereoParams stereo;
  CrossfeedParams crossfeed;
  CompressorParams compressor;
  SaturatorParams saturator;
  AmbienceParams ambience;
  NoiseParams noise;
  float outputGainDb = 0.f;  // post-EQ boost, protected by the limiter
  LimiterParams limiter;
  bool bypass = false;

  friend bool operator==(const EngineParams&, const EngineParams&) = default;
};

struct Meters {
  float inPeak[2] = {0, 0};
  float outPeak[2] = {0, 0};
  float gainReductionDb = 0;
};

class Engine {
 public:
  Engine();

  // Control thread. May allocate. Must not run concurrently with process().
  void prepare(double sampleRate, int numChannels, int maxFrames);

  // Control thread: edit the pending parameter set, then publish().
  EngineParams& edit() { return pending_; }
  const EngineParams& pending() const { return pending_; }
  void publish();
  double effectivePreampDb() const { return effectivePreampDb_; }

  // Real-time thread.
  void processPlanar(float* const* channels, int numChannels, int numFrames);
  // Interleaved float32, the native layout of most Core Audio devices/taps.
  // `in` and `out` may alias.
  void processInterleaved(const float* in, float* out, int numChannels, int numFrames);

  int latencyFrames() const { return limiter_.latencyFrames() + bassLimiter_.latencyFrames(); }
  // Peaks accumulated since the previous call (UI polls at ~30-60 Hz).
  Meters takeMeters();
  // Post-processing mono feed for the UI spectrum analyzer.
  SpscRing<float>& analyzerFeed() { return analyzer_; }

  double sampleRate() const { return sampleRate_; }
  int numChannels() const { return numChannels_; }

 private:
  void applySnapshot(const EngineParams& p);

  double sampleRate_ = 48000.0;
  int numChannels_ = 2;
  int maxFrames_ = 0;

  EngineParams pending_;
  double effectivePreampDb_ = 0.0;
  TripleBuffer<EngineParams> mailbox_;
  EngineParams live_;

  ParametricEq correction_;
  ParametricEq eq_;
  BassEnhancer bass_;
  StereoWidener stereo_;
  Crossfeed crossfeed_;
  Compressor compressor_;
  Saturator saturator_;
  Ambience ambience_;
  NoiseBed noise_;
  Smoothed outGain_;
  Limiter limiter_;
  BassPriorityLimiter bassLimiter_;
  bool bassPriority_ = false;

  std::vector<std::vector<float>> scratch_;
  std::vector<float*> scratchPtrs_;
  SpscRing<float> analyzer_{1 << 14};

  std::atomic<float> inPeak_[2];
  std::atomic<float> outPeak_[2];
};

}  // namespace punch
