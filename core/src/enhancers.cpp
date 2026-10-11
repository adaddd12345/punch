#include "punch/enhancers.hpp"

#include <algorithm>
#include <cmath>

namespace punch {

// ---------------------------------------------------------------- Bass

void BassEnhancer::prepare(double sampleRate, int numChannels) {
  sampleRate_ = sampleRate;
  numChannels_ = std::clamp(numChannels, 1, kMaxChannels);
  amount_.prepare(sampleRate, 30.0);
  setParams(p_);
  amount_.snap(amount_.target());
  reset();
}

void BassEnhancer::reset() {
  for (auto& c : st_) c = Chan{};
}

void BassEnhancer::setParams(const BassEnhancerParams& p) {
  p_ = p;
  const double fc = std::clamp<double>(p.cutoffHz, 40.0, 300.0);
  lowBand_ = SvfCoeffs::make({FilterType::LowPass, fc, 0.0, 0.7071, true}, sampleRate_);
  // Keep harmonics (2f..~5f) and drop the regenerated fundamental region the
  // speaker can't reproduce anyway.
  harmHp_ = SvfCoeffs::make({FilterType::HighPass, fc * 0.8, 0.0, 0.7071, true}, sampleRate_);
  harmLp_ = SvfCoeffs::make({FilterType::LowPass, fc * 5.0, 0.0, 0.7071, true}, sampleRate_);
  amount_.setTarget(p.enabled ? std::clamp(p.amount, 0.f, 1.f) : 0.f);
}

void BassEnhancer::process(float* const* ch, int numChannels, int numFrames) {
  numChannels = std::min(numChannels, numChannels_);
  if (amount_.settled() && amount_.target() == 0.f) return;
  const float drive = std::max(1.f, p_.drive);
  constexpr float kBias = 0.3f;
  const float biasOffset = std::tanh(kBias);
  // The saturator only ever sees content below ~fc (24 dB/oct), so the
  // harmonics it creates stay far below Nyquist: no oversampling needed.
  for (int i = 0; i < numFrames; ++i) {
    const float amt = amount_.next() * 1.5f;
    for (int c = 0; c < numChannels; ++c) {
      Chan& s = st_[size_t(c)];
      const float x = ch[c][i];
      const float low = s.lp2.tick(lowBand_, s.lp1.tick(lowBand_, x));
      const float sat = (std::tanh(drive * low + kBias) - biasOffset) / drive * 2.f;
      const float harm = s.lp.tick(harmLp_, s.hp.tick(harmHp_, sat));
      ch[c][i] = x + amt * harm;
    }
  }
}

// ---------------------------------------------------------------- Stereo

void StereoWidener::prepare(double sampleRate) {
  sampleRate_ = sampleRate;
  width_.prepare(sampleRate, 20.0);
  setParams(p_);
  width_.snap(width_.target());
  reset();
}

void StereoWidener::reset() { hpState_.reset(); }

void StereoWidener::setParams(const StereoParams& p) {
  p_ = p;
  sideHp_ = SvfCoeffs::make({FilterType::HighPass, std::max(20.f, p.sideHighpassHz), 0.0, 0.7071, true}, sampleRate_);
  width_.setTarget(p.enabled ? std::clamp(p.width, 0.f, 2.f) : 1.f);
}

void StereoWidener::process(float* const* ch, int numChannels, int numFrames) {
  if (numChannels < 2) return;
  if (width_.settled() && width_.target() == 1.f) return;
  float* L = ch[0];
  float* R = ch[1];
  for (int i = 0; i < numFrames; ++i) {
    const float w = width_.next();
    const float m = 0.5f * (L[i] + R[i]);
    const float s = 0.5f * (L[i] - R[i]);
    const float shp = hpState_.tick(sideHp_, s);
    const float s2 = s * std::min(w, 1.f) + std::max(w - 1.f, 0.f) * shp;
    L[i] = m + s2;
    R[i] = m - s2;
  }
}

// ---------------------------------------------------------------- Crossfeed

void Crossfeed::prepare(double sampleRate) {
  sampleRate_ = sampleRate;
  delay_ = std::clamp(int(std::lround(0.0003 * sampleRate)), 1, kMaxDelay - 1);
  amount_.prepare(sampleRate, 30.0);
  setParams(p_);
  amount_.snap(amount_.target());
  reset();
}

void Crossfeed::reset() {
  dl_.fill(0.f);
  dr_.fill(0.f);
  pos_ = 0;
  sl_.reset();
  sr_.reset();
}

void Crossfeed::setParams(const CrossfeedParams& p) {
  p_ = p;
  lp_ = SvfCoeffs::make({FilterType::LowPass, std::clamp<double>(p.cutoffHz, 200.0, 2000.0), 0.0, 0.5, true}, sampleRate_);
  amount_.setTarget(p.enabled ? std::clamp(p.amount, 0.f, 1.f) : 0.f);
}

void Crossfeed::process(float* const* ch, int numChannels, int numFrames) {
  if (numChannels < 2) return;
  if (amount_.settled() && amount_.target() == 0.f) return;
  float* L = ch[0];
  float* R = ch[1];
  for (int i = 0; i < numFrames; ++i) {
    const float a = amount_.next();
    const int rd = (pos_ - delay_ + kMaxDelay) % kMaxDelay;
    const float xl = sl_.tick(lp_, dl_[size_t(rd)]);
    const float xr = sr_.tick(lp_, dr_[size_t(rd)]);
    dl_[size_t(pos_)] = L[i];
    dr_[size_t(pos_)] = R[i];
    pos_ = (pos_ + 1) % kMaxDelay;
    const float norm = 1.f / (1.f + a);
    const float l = (L[i] + a * xr) * norm;
    const float r = (R[i] + a * xl) * norm;
    L[i] = l;
    R[i] = r;
  }
}

}  // namespace punch
