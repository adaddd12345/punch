#include "punch/fx.hpp"

#include <algorithm>
#include <cmath>

namespace punch {

namespace {
float coeffFor(double seconds, double rate) { return float(1.0 - std::exp(-1.0 / (seconds * rate))); }
}  // namespace

// ================================================================ LoudnessGuard

void LoudnessGuard::prepare(double sampleRate) {
  sampleRate_ = sampleRate;
  // ITU-R BS.1770 K-weighting, approximated with the SVF: a ~60 Hz high-pass
  // (RLB) and a +4 dB high shelf around 1.5 kHz (head effect).
  kHp_ = SvfCoeffs::make({FilterType::HighPass, 60.0, 0.0, 0.5, true}, sampleRate);
  kShelf_ = SvfCoeffs::make({FilterType::HighShelf, 1500.0, 4.0, 0.71, true}, sampleRate);
  powerCoeff_ = coeffFor(0.2, sampleRate);
  attackCoeff_ = coeffFor(0.06, sampleRate);
  releaseCoeff_ = coeffFor(1.5, sampleRate);
  // The average moves per sample too, but in dB, slowly.
  riseCoeff_ = coeffFor(60.0, sampleRate);
  fallCoeff_ = coeffFor(15.0, sampleRate);
  warmCoeff_ = coeffFor(0.75, sampleRate);
  active_.prepare(sampleRate, 50.0);
  setParams(p_);
  active_.snap(active_.target());
  reset();
}

void LoudnessGuard::reset() {
  for (auto& s : hpState_) s.reset();
  for (auto& s : shelfState_) s.reset();
  power_ = 0.0;
  meanDb_ = -200.f;
  warmSamples_ = 0;
  gainDb_ = 0.f;
  cutDb_.store(0.f, std::memory_order_relaxed);
}

void LoudnessGuard::setParams(const LoudnessGuardParams& p) {
  p_ = p;
  active_.setTarget(p.enabled ? 1.f : 0.f);
}

void LoudnessGuard::process(float* const* ch, int numChannels, int numFrames) {
  numChannels = std::min(numChannels, kMaxChannels);
  if (active_.settled() && active_.target() == 0.f) {
    cutDb_.store(0.f, std::memory_order_relaxed);
    return;
  }
  const float over = std::clamp(p_.overDb, 1.f, 30.f);
  const float maxCut = std::clamp(p_.maxCutDb, 0.f, 40.f);
  for (int i = 0; i < numFrames; ++i) {
    double sum = 0.0;
    for (int c = 0; c < numChannels; ++c) {
      const float k = shelfState_[size_t(c)].tick(kShelf_, hpState_[size_t(c)].tick(kHp_, ch[c][i]));
      sum += double(k) * k;
    }
    power_ += (sum - power_) * double(powerCoeff_);
    const float shortDb = float(10.0 * std::log10(power_ + 1e-12));
    // Running average of what you've been hearing; silence doesn't count.
    // For the first ~4 s of audible sound it learns quickly (and doesn't
    // act), so starting playback isn't treated as a jump.
    const int warmup = int(4.0 * sampleRate_);
    if (shortDb > -60.f) {
      if (meanDb_ < -150.f) meanDb_ = shortDb;
      const float c = warmSamples_ < warmup ? warmCoeff_ : (shortDb > meanDb_ ? riseCoeff_ : fallCoeff_);
      meanDb_ += (shortDb - meanDb_) * c;
      if (warmSamples_ < warmup) ++warmSamples_;
    }
    const float excess = meanDb_ > -150.f && warmSamples_ >= warmup ? shortDb - (meanDb_ + over) : 0.f;
    const float target = -std::clamp(excess, 0.f, maxCut);
    gainDb_ += (target - gainDb_) * (target < gainDb_ ? attackCoeff_ : releaseCoeff_);
    const float a = active_.next();
    const float g = dbToGain(gainDb_ * a);
    for (int c = 0; c < numChannels; ++c) ch[c][i] *= g;
  }
  cutDb_.store(gainDb_ * active_.current(), std::memory_order_relaxed);
}

// ================================================================ DjFx

void DjFx::prepare(double sampleRate, int numChannels) {
  sampleRate_ = sampleRate;
  numChannels_ = std::clamp(numChannels, 1, kMaxChannels);
  lp250_ = SvfCoeffs::make({FilterType::LowPass, 250.0, 0.0, 0.7071, true}, sampleRate);
  hp250_ = SvfCoeffs::make({FilterType::HighPass, 250.0, 0.0, 0.7071, true}, sampleRate);
  lp3k_ = SvfCoeffs::make({FilterType::LowPass, 3000.0, 0.0, 0.7071, true}, sampleRate);
  hp3k_ = SvfCoeffs::make({FilterType::HighPass, 3000.0, 0.0, 0.7071, true}, sampleRate);
  echoTone_ = SvfCoeffs::make({FilterType::LowPass, 4000.0, 0.0, 0.7071, true}, sampleRate);
  for (auto* s : {&gLow_, &gMid_, &gHigh_, &isoWet_}) s->prepare(sampleRate, 12.0);
  filterPos_.prepare(sampleRate, 40.0);
  filterWet_.prepare(sampleRate, 25.0);
  echoSend_.prepare(sampleRate, 15.0);
  crushMix_.prepare(sampleRate, 15.0);
  driveMix_.prepare(sampleRate, 15.0);
  delayLen_ = std::max(1, int(std::lround(0.375 * sampleRate)));
  for (auto& d : delay_) d.assign(size_t(delayLen_), 0.f);
  setParams(p_);
  for (auto* s : {&gLow_, &gMid_, &gHigh_, &isoWet_, &filterPos_, &filterWet_, &echoSend_, &crushMix_, &driveMix_})
    s->snap(s->target());
  updateFilter(filterPos_.current());
  reset();
}

void DjFx::reset() {
  for (auto& s : iso_) s = IsoChan{};  // NOLINT
  for (auto& s : filtState_) s.reset();
  for (auto& s : echoToneState_) s.reset();
  for (auto& d : delay_) std::fill(d.begin(), d.end(), 0.f);
  delayPos_ = 0;
  held_.fill(0.f);
  holdCount_ = 0;
  echoTail_ = 0;
}

void DjFx::setParams(const DjParams& p) {
  p_ = p;
  gLow_.setTarget(p.lowKill ? 0.f : 1.f);
  gMid_.setTarget(p.midKill ? 0.f : 1.f);
  gHigh_.setTarget(p.highKill ? 0.f : 1.f);
  isoWet_.setTarget(p.lowKill || p.midKill || p.highKill ? 1.f : 0.f);
  const float f = std::clamp(p.filter, -1.f, 1.f);
  // Keep the last position while fading out so the sweep doesn't jump.
  if (std::fabs(f) > 0.01f) filterPos_.setTarget(f);
  filterWet_.setTarget(std::fabs(f) > 0.01f ? 1.f : 0.f);
  echoSend_.setTarget(p.echo ? 1.f : 0.f);
  crushMix_.setTarget(p.crush ? 1.f : 0.f);
  driveMix_.setTarget(p.drive ? 1.f : 0.f);
}

void DjFx::updateFilter(float v) {
  // v < 0: low-pass from 20 kHz down to 150 Hz; v > 0: high-pass from 20 Hz
  // up to 6 kHz. Exponential so equal knob travel = equal musical steps.
  const double a = std::fabs(double(v));
  const bool lp = v < 0.f;
  const double fc = lp ? 20000.0 * std::pow(150.0 / 20000.0, a) : 20.0 * std::pow(6000.0 / 20.0, a);
  filt_ = SvfCoeffs::make({lp ? FilterType::LowPass : FilterType::HighPass, fc, 0.0, 1.3, true}, sampleRate_);
  filtFor_ = v;
}

void DjFx::process(float* const* ch, int numChannels, int numFrames) {
  numChannels = std::min(numChannels, numChannels_);
  const bool isoIdle = isoWet_.settled() && isoWet_.current() == 0.f;
  const bool filtIdle = filterWet_.settled() && filterWet_.current() == 0.f;
  const bool echoIdle = echoSend_.settled() && echoSend_.current() == 0.f;
  const bool crushIdle = crushMix_.settled() && crushMix_.current() == 0.f;
  const bool driveIdle = driveMix_.settled() && driveMix_.current() == 0.f;
  // After the echo pad is released its tail keeps ringing (~4 s to -60 dB
  // at 50% feedback), so keep running until that has had time to die away.
  if (!echoIdle) echoTail_ = int(6.0 * sampleRate_);
  if (isoIdle && filtIdle && crushIdle && driveIdle && echoIdle) {
    if (echoTail_ <= 0) return;
    echoTail_ -= numFrames;
    if (echoTail_ <= 0) {
      for (auto& d : delay_) std::fill(d.begin(), d.end(), 0.f);
      return;
    }
  }

  constexpr int kBlock = 32;
  for (int s = 0; s < numFrames; s += kBlock) {
    const int n = std::min(kBlock, numFrames - s);
    // Sweep filter coefficients, once per block.
    const float pos = filterPos_.current();
    if (pos != filtFor_) updateFilter(pos);
    for (int i = s; i < s + n; ++i) {
      const float gl = gLow_.next(), gm = gMid_.next(), gh = gHigh_.next(), iw = isoWet_.next();
      filterPos_.next();
      const float fw = filterWet_.next();
      const float es = echoSend_.next();
      const float cm = crushMix_.next();
      const float dm = driveMix_.next();
      // Crusher sample-and-hold at 1/6 rate.
      const bool grab = holdCount_ == 0;
      holdCount_ = holdCount_ + 1 == 6 ? 0 : holdCount_ + 1;
      for (int c = 0; c < numChannels; ++c) {
        float x = ch[c][i];
        // Isolator: LR4 split at 250 Hz, the rest split again at 3 kHz; the
        // low band goes through the 3 kHz allpass (its LP+HP sum) so all
        // three bands stay phase-aligned and sum flat.
        if (!isoIdle) {
          IsoChan& is = iso_[size_t(c)];
          const float lo0 = is.a2.tick(lp250_, is.a1.tick(lp250_, x));
          const float rest = is.b2.tick(hp250_, is.b1.tick(hp250_, x));
          const float mid = is.c2.tick(lp3k_, is.c1.tick(lp3k_, rest));
          const float hi = is.d2.tick(hp3k_, is.d1.tick(hp3k_, rest));
          const float lo = is.e2.tick(lp3k_, is.e1.tick(lp3k_, lo0)) + is.f2.tick(hp3k_, is.f1.tick(hp3k_, lo0));
          const float bands = gl * lo + gm * mid + gh * hi;
          x += iw * (bands - x);
        }
        // Sweep filter.
        const float f = filtState_[size_t(c)].tick(filt_, x);
        x += fw * (f - x);
        // Drive: hard tanh with level trim.
        if (dm > 0.f) {
          const float d = std::tanh(6.f * x) * 0.6f;
          x += dm * (d - x);
        }
        // Crush: 6-bit, 1/6 sample rate.
        if (cm > 0.f) {
          if (grab) held_[size_t(c)] = std::round(x * 32.f) / 32.f;
          x += cm * (held_[size_t(c)] - x);
        }
        // Echo: 3/8 s, 50% feedback darkened at 4 kHz, 40% wet.
        float& slot = delay_[size_t(c)][size_t(delayPos_)];
        const float wet = slot;
        slot = es * x + 0.5f * echoToneState_[size_t(c)].tick(echoTone_, wet);
        x += 0.4f * wet;
        ch[c][i] = x;
      }
      delayPos_ = delayPos_ + 1 == delayLen_ ? 0 : delayPos_ + 1;
    }
  }
}

}  // namespace punch
