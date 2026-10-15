// "Character" processors: the things Boom-style apps market as Boom /
// Fidelity / Ambience / 3D. Each is cheap (a handful of SVF ticks per frame)
// and has a single 0..1 amount so it maps directly onto a UI slider.
#pragma once

#include <array>
#include <atomic>

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

// Bass Shaker: the Bass Shake preset's low end, driven by one Strength
// amount. It shapes the bass by what the music is doing instead of a fixed
// boost (docs: Bass Shake R&D, run 8):
//   * Punch: bell 100 Hz Q 0.8, up to +8 dB * S on kick attacks (0.5 ms vs
//     20 ms envelope of the 25-150 Hz band, read through a Hilbert pair so
//     the envelope has no ripple).
//   * Body: low shelf 80 Hz, S * (9 - 4 * sustain) dB: full on short notes,
//     less under long sustained bass (sustain = RMS rising over a 1/16 note
//     and falling over a 1/8 note, against the peak).
//   * Headroom: room = ceiling - slow peak - Boost; body <= room + 1 dB
//     (minus the sustain trim), punch <= room + 3 dB, so a loud master isn't
//     pushed into the limiter (no pumping of the mids).
//   * Low-mid dip: bell 260 Hz, -(0.3 * punch + 2 * S * bass dominance) dB.
//   * Clean harmonics: 2nd + 3rd of 30-90 Hz built from the analytic signal
//     (|z| (cos 2phi + cos 3phi / 2): no intermodulation with the rest of the
//     mix), band-limited to 60-250 Hz, mixed at 0.35 * S (more on small
//     built-in speakers).
//   * Mono lows: the side's lows below ~100 Hz are taken out (one-pole, so
//     panned low mids keep their place), crossfaded in by the amount.
//   * Pace: the envelopes' release times follow the beat (the tempo tracker
//     when it's confident, else the median kick interval, else 120 BPM),
//     clamped to 70-180 BPM, glided, and biased slightly fast.
// The gains are worked out every 16 frames (48 kHz) and glide over 1.5 ms;
// only the gain terms of the fixed-frequency filters are recomputed. The
// Hilbert pairs run at ~12 kHz (decimated after the band filters). At
// Strength 0, once settled, the stage returns at once (bit-exact).
struct BassShakerParams {
  float amount = 0.f;     // Strength 0..1 (S = amount * kStrengthScale)
  float boostDb = 0.f;    // gain after this stage (Boost + automatic lifts), for headroom
  float ceilingDb = -1.f; // limiter ceiling (the engine fills it in)
  float paceBpm = 0.f;    // 0 = automatic
  float harmonics = 1.f;  // harmonic mix scale (small built-in speakers: more)

  friend bool operator==(const BassShakerParams&, const BassShakerParams&) = default;
};

class BassShaker {
 public:
  // Strength (UI 0..1) to the R&D prototype's S. 1.4: the default Strength
  // 0.55 lands at S 0.77, the prototype's "S 0.8" column.
  static constexpr float kStrengthScale = 1.4f;

  void prepare(double sampleRate, int numChannels);
  void reset();
  void setParams(const BassShakerParams& p);
  // Audio thread: the tempo tracker's BPM while it is running and sure (0 = none).
  void setTempoHint(float bpm) { tempoHint_ = bpm; }
  void process(float* const* ch, int numChannels, int numFrames);
  // Pace in use (BPM, before the fast bias); any thread.
  float paceBpm() const { return pace_.load(std::memory_order_relaxed); }
  bool idle() const { return idle_; }

 private:
  // Niemitalo's 4+4 allpass 90-degree pair (z^-2 sections); a one-sample
  // delay on path a. 90 deg +-0.7 between 0.0005 and 0.49 of the rate.
  struct Hilbert {
    std::array<float, 4> xa1{}, xa2{}, ya1{}, ya2{}, xb1{}, xb2{}, yb1{}, yb2{};
    float d1 = 0.f;
    void tick(float x, float& i, float& q);
  };
  void control(int numChannels);
  void updatePace(int numFrames);
  void paceCoeffs(double beatMs);
  void noteOnset();
  void buildGains();

  double sampleRate_ = 48000.0;
  int numChannels_ = 2;
  BassShakerParams p_;
  Smoothed amount_;
  bool idle_ = true;
  int ctlLen_ = 16, ctlPos_ = 0, decim_ = 4, decimPos_ = 0;

  // Fixed filters.
  SvfCoeffs detHp_, detLp_, srcHp_, srcLp_, outHp_, outLp_;
  SvfState detHpS_, detLpA_, detLpB_, srcHpS_, srcLpA_, srcLpB_, outHpA_, outHpB_, outLpA_, outLpB_;
  Hilbert hilDet_, hilSrc_;
  float sideLpG_ = 0.f;                  // one-pole (TPT) for the side's lows
  std::array<float, 2> sideLpS_{};
  // Moving filters: tan() precomputed, gain terms rebuilt on change.
  SvfCoeffs punchC_, bodyC_, dipC_;
  double wPunch_ = 0, wBody_ = 0, wDip_ = 0;
  float builtPunch_ = 1e9f, builtBody_ = 1e9f, builtDip_ = 1e9f;
  struct Chan { SvfState punch, body, dip; };
  std::array<Chan, kMaxChannels> st_{};

  // Detector (control rate).
  float blkEnv2_ = 0.f, blkEnv2Sum_ = 0.f, blkPeak_ = 0.f, blkPow_ = 0.f;
  int blkHil_ = 0;
  float eF_ = 0.f, eS_ = 0.f, ms_ = 0.f, lowMs_ = 0.f, totMs_ = 0.f, pk_ = 0.f;
  float aF_ = 0.f, aS_ = 0.f, pkA_ = 0.f, gSm_ = 0.f;
  float rF_ = 0.f, a16_ = 0.f, r8_ = 0.f, aDom_ = 0.f, pkR_ = 0.f;  // from the pace
  float pDb_ = 0.f, bDb_ = 0.f, dipDb_ = 0.f;
  float hHold_ = 0.f, harmMix_ = 0.f;

  // Pace.
  float tempoHint_ = 0.f;
  double beatMs_ = 500.0, coeffBeatMs_ = -1.0;
  bool atkHigh_ = false;
  int sinceOnset_ = 1 << 29;          // control ticks
  std::array<float, 9> ioi_{};        // seconds, ring
  int ioiCount_ = 0, ioiPos_ = 0;
  float kickBpm_ = 0.f;
  std::atomic<float> pace_{120.f};
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
