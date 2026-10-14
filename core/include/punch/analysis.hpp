// Lightweight music analysis: tempo (BPM) and bass pitch.
//
// Both trackers are meant to run OFF the audio thread, fed from the engine's
// mono analyzer stream (Engine::analyzerFeed()) or any mono float buffer.
// They allocate only in prepare(); process() and the getters are
// allocation-free and O(1) amortised per sample. Not thread-safe: call
// everything from one thread (e.g. the thread that drains the analyzer ring).
//
// See docs/research/26-bpm-pitch-detection.md for the method and parameters.
#pragma once

#include <array>
#include <cstddef>
#include <vector>

#include "punch/svf.hpp"

namespace punch {

// Tempo from a multi-band energy-flux onset envelope (200 Hz frame rate),
// autocorrelated over a 6 s window, weighted by a log-Gaussian tempo prior
// around 120 BPM and refined at sub-frame precision from the first few
// beat-period multiples (a small comb). No beat phase, just the period.
class TempoTracker {
 public:
  static constexpr double kMinBpm = 60.0;
  static constexpr double kMaxBpm = 200.0;

  void prepare(double sampleRate);
  void reset();
  void process(const float* mono, std::size_t n);

  // 0 until enough audio (~3 s) has been seen.
  double bpm() const { return bpm_; }
  // 0..1. Hide the readout below ~0.5.
  double confidence() const { return confidence_; }

 private:
  static constexpr int kBands = 6;
  static constexpr double kFrameRate = 200.0;  // target onset frames per second
  static constexpr double kWindowSec = 6.0;
  static constexpr double kMinSecToReport = 3.0;
  static constexpr double kUpdateSec = 0.5;
  static constexpr int kCombSize = 4;            // multiples per comb
  static constexpr double kPriorOctaves = 1.0;  // tempo-prior width (std dev)

  void pushOnsetFrame(float value);
  // An estimate is spread over the following onset frames (a fixed slice of
  // autocorrelation lags per frame), so no audio callback pays for a whole
  // one: begin snapshots the window, step does a slice, finish picks the tempo.
  void beginEstimate();
  void stepEstimate();
  void finishEstimate();

  double fs_ = 48000.0;
  int hop_ = 240;
  double frameRate_ = 200.0;  // actual: fs / hop
  int hopCount_ = 0;
  std::array<SvfCoeffs, kBands> bandCoeffs_{};
  std::array<SvfState, kBands> bandState_{};
  std::array<double, kBands> bandEnergy_{};
  std::array<float, kBands> bandPrevLog_{};

  std::vector<float> onset_;   // ring of onset frames
  std::vector<float> work_;    // linearised, mean-removed copy
  std::vector<double> acf_;    // normalised autocorrelation per lag
  int onsetWrite_ = 0;
  int onsetCount_ = 0;
  int framesSinceUpdate_ = 0;
  int minLag_ = 60, maxLag_ = 200;
  int acfLag_ = -1;          // next lag to compute; -1 = no estimate running
  int acfN_ = 0, acfMaxLag_ = 0, acfStep_ = 1;
  double acfMean_ = 0.0;

  double bpm_ = 0.0;
  double confidence_ = 0.0;
};

// Monophonic bass f0 (about 30-250 Hz): 4th-order Butterworth low-pass at
// 300 Hz, decimation to ~3 kHz, then YIN (cumulative-mean-normalised
// difference, absolute threshold, parabolic refinement) on an 85 ms buffer
// with a ~10 ms hop. Confidence = 1 - aperiodicity.
class BassPitchTracker {
 public:
  static constexpr double kMinHz = 30.0;
  static constexpr double kMaxHz = 250.0;

  void prepare(double sampleRate);
  void reset();
  void process(const float* mono, std::size_t n);

  double hz() const { return hz_; }                // 0 when unvoiced
  int midiNote() const { return midi_; }           // -1 when unvoiced
  const char* noteName() const { return note_; }   // e.g. "E1", "" when unvoiced
  double cents() const { return cents_; }          // -50..+50 from midiNote()
  double confidence() const { return confidence_; }  // 0..1, hide below ~0.6

  // Utility: writes e.g. "A#2" into out (needs 5 bytes).
  static void midiToName(int midi, char* out, std::size_t size);

 private:
  static constexpr int kWindow = 128;  // YIN integration window, decimated samples
  static constexpr int kBuffer = 256;  // window + max lag (power of two)
  static constexpr int kHop = 32;
  static constexpr float kThreshold = 0.15f;

  void analyse();

  double fs_ = 48000.0;
  double fsDec_ = 3000.0;
  int decim_ = 16;
  int decimPhase_ = 0;
  SvfCoeffs lp1_{}, lp2_{};
  SvfState s1_{}, s2_{};

  std::array<float, kBuffer> ring_{};
  std::array<float, kBuffer> frame_{};
  std::array<float, kBuffer> diff_{};  // normalised difference d'(tau)
  std::array<float, kBuffer> raw_{};   // raw difference d(tau)
  int ringWrite_ = 0;
  int filled_ = 0;
  int sinceHop_ = 0;
  int minTau_ = 12, maxTau_ = 100;

  double hz_ = 0.0;
  int midi_ = -1;
  double cents_ = 0.0;
  double confidence_ = 0.0;
  char note_[8] = {};
};

}  // namespace punch
