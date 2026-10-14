// Night Guard (relative loudness guard) and the DJ effects.
// Real-time safe after prepare(); every switch glides, so pads never click.
#pragma once

#include <array>
#include <atomic>
#include <vector>

#include "punch/analysis.hpp"  // TempoTracker
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
  // Performance pads (DjPerform below).
  bool tapeStop = false;  // varispeed slow-down to a halt; release snaps back
  bool chipmunk = false;  // pitch +7 semitones (wins over screw if both on)
  bool screw = false;     // pitch -5 semitones
  bool roll = false;      // loop the last 1/8 note, halving every beat held
  bool lofi = false;      // cassette: wow & flutter, saturation, 3.5 kHz, narrow, hiss
  bool pump = false;      // sidechain-style duck on every beat
  // Run the tempo tracker even with nothing on (e.g. while the DJ panel is
  // showing), so Roll and Pump already know the BPM on the first press.
  bool trackTempo = false;

  friend bool operator==(const DjParams&, const DjParams&) = default;
};

// The six performance pads. Chain inside the DJ stage:
//   roll -> pitch -> tape stop -> lofi -> (isolator, filter, drive, crush,
//   echo) -> pump.
// Every effect crossfades in and out; with all of them off and settled the
// stage only records its input history (needed so Roll can grab the past)
// and the audio is bit-exact.
class DjPerform {
 public:
  void prepare(double sampleRate, int numChannels);
  void reset();
  void setParams(const DjParams& p);
  // Latest tempo (0 = unknown). Audio thread.
  void setBpm(double bpm) { bpm_ = bpm; }
  bool idle() const;
  // Roll is looping a silent slice. Any thread.
  bool rollSilent() const { return rollSilent_.load(std::memory_order_relaxed); }
  // Before the classic DJ chain / after it.
  void processPre(float* const* ch, int numChannels, int numFrames);
  void processPost(float* const* ch, int numChannels, int numFrames);

 private:
  struct Ring {
    std::vector<float> d;
    int mask = 0;
    void alloc(int minSize);
    inline float& at(int i) { return d[size_t(i & mask)]; }
    // 4-point Hermite read at fractional absolute position pos.
    float read(double pos) const;
  };
  void recordHistory(float* const* ch, int numChannels, int numFrames);
  int rollSliceLen() const;
  void captureRoll();

  double sampleRate_ = 48000.0;
  int numChannels_ = 2;
  DjParams p_;
  double bpm_ = 0.0;

  // Input history (always written) and its write index.
  std::array<Ring, kMaxChannels> hist_;
  int histW_ = 0;
  int histFilled_ = 0;  // frames recorded since reset (saturates)

  // Roll.
  std::array<std::vector<float>, kMaxChannels> loop_;
  Smoothed rollMix_;
  bool rollLatched_ = false;  // a press has been captured for the current hold
  int rollLen_ = 1, rollMinLen_ = 1, rollPos_ = 0, rollFade_ = 1;
  int rollBeat_ = 1, rollElapsed_ = 0, rollNextHalve_ = 0;
  std::atomic<bool> rollSilent_{false};

  // Pitch (two-head delay-line shifter, Hann crossfade).
  std::array<Ring, kMaxChannels> pitchBuf_;
  int pitchW_ = 0;
  Smoothed pitchMix_, semis_;
  double pitchPhase_ = 0.0;
  double grain_ = 1920.0;  // samples
  bool pitchRunning_ = false;
  float ratioFor_ = 0.f;
  double ratio_ = 1.0;

  // Tape stop.
  std::array<Ring, kMaxChannels> tapeBuf_;
  int tapeW_ = 0;
  Smoothed tapeMix_;
  bool tapeRunning_ = false, tapeHeld_ = false;
  double tapeT_ = 0.0, tapeLag_ = 0.0, tapeStopSamples_ = 48000.0;

  // Lofi.
  std::array<Ring, kMaxChannels> lofiBuf_;
  int lofiW_ = 0;
  Smoothed lofiMix_;
  bool lofiRunning_ = false;
  double wowPh_ = 0.0, flutPh_ = 0.0, wowInc_ = 0.0, flutInc_ = 0.0;
  float lofiBase_ = 0.f, wowDepth_ = 0.f, flutDepth_ = 0.f;
  SvfCoeffs lofiLp1_, lofiLp2_;
  std::array<SvfState, kMaxChannels> lofiS1_{}, lofiS2_{};
  std::array<uint32_t, kMaxChannels> noise_{};

  // Pump.
  Smoothed pumpMix_;
  SvfCoeffs kickLp_;
  SvfState kickS_{};
  float kickFast_ = 0.f, kickSlow_ = 0.f;
  bool kickAbove_ = false, pumpRunning_ = false;
  int sinceSync_ = 1 << 30;
  float kickAtt_ = 0.f, kickRel_ = 0.f, kickSlowC_ = 0.f;
  int sinceOnset_ = 1 << 30, refractory_ = 1, lastIoi_ = 0;
  double beatPhase_ = 0.0;  // 0..1 within the beat
  bool locked_ = false;
  int sinceTrigger_ = 1 << 30;
  float duckStart_ = 0.f, duck_ = 0.f;
  int duckAttack_ = 1, duckRelease_ = 1;
};

class DjFx {
 public:
  void prepare(double sampleRate, int numChannels);
  void reset();
  void setParams(const DjParams& p);
  void process(float* const* ch, int numChannels, int numFrames);
  // Detected tempo (BPM, 0 when unknown or unsure). Any thread.
  float bpm() const { return bpm_.load(std::memory_order_relaxed); }
  bool rollSilent() const { return perform_.rollSilent(); }

 private:
  void updateFilter(float v);
  void processClassic(float* const* ch, int numChannels, int numFrames);
  void trackTempo(float* const* ch, int numChannels, int numFrames);

  DjPerform perform_;
  TempoTracker tempo_;
  bool tracking_ = false;
  std::atomic<float> bpm_{0.f};

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
