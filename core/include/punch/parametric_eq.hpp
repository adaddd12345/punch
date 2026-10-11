#pragma once

#include <array>
#include <cstddef>
#include <initializer_list>
#include <vector>

#include "punch/dsp_util.hpp"
#include "punch/svf.hpp"

namespace punch {

inline constexpr int kMaxEqBands = 24;
inline constexpr int kMaxChannels = 8;

struct EqParams {
  std::array<FilterSpec, kMaxEqBands> bands{};
  int numBands = 0;
  float preampDb = 0.f;

  friend bool operator==(const EqParams&, const EqParams&) = default;
};

// Control-thread helpers (allocate / do transcendental math freely).
// Combined magnitude of all enabled bands at `hz`, excluding preamp.
double eqResponseDb(const EqParams& p, double sampleRate, double hz);
// Peak boost across 20 Hz..20 kHz (log grid). Negate and use as preamp to
// guarantee a full-scale sine can never be pushed over 0 dBFS by the EQ.
double eqPeakBoostDb(const EqParams& p, double sampleRate);
// Same, for several EQ stages in series.
double eqPeakBoostDb(std::initializer_list<const EqParams*> stages, double sampleRate);
// Fills `outDb` with the response sampled on a log grid between lo and hi.
void eqResponseCurve(const EqParams& p, double sampleRate, double lo, double hi, std::vector<double>& outDb);

// Audio-thread processor. All bands run in series per channel. Parameter
// changes glide (frequency and Q geometrically, gain linearly) and
// coefficients are recomputed every kControlBlock samples while gliding, so
// sweeping a band in the UI is click-free.
class ParametricEq {
 public:
  static constexpr int kControlBlock = 32;

  void prepare(double sampleRate, int numChannels);
  void reset();
  // Call from the audio thread when a new snapshot arrives.
  void setParams(const EqParams& p);
  // Jump straight to the targets of the last setParams() (no glide). Use
  // after prepare(), before audio flows.
  void snapToTargets();
  // Planar, in-place.
  void process(float* const* channels, int numChannels, int numFrames);

  double sampleRate() const { return sampleRate_; }

 private:
  struct Band {
    FilterSpec current;
    FilterSpec target;
    SvfCoeffs coeffs;
    std::array<SvfState, kMaxChannels> state{};
    bool gliding = false;
    bool active = false;  // false => skip entirely (disabled and settled)
  };

  void advanceGlide(Band& b);

  double sampleRate_ = 48000.0;
  int numChannels_ = 2;
  int numBands_ = 0;
  std::array<Band, kMaxEqBands> bands_{};
  Smoothed preamp_;
  float glideCoeff_ = 0.2f;
};

}  // namespace punch
