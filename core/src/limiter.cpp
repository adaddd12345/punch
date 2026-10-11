#include "punch/limiter.hpp"

#include <algorithm>
#include <cmath>

#include "punch/dsp_util.hpp"

namespace punch {

void Limiter::prepare(double sampleRate, int numChannels, float lookaheadMs) {
  sampleRate_ = sampleRate;
  numChannels_ = std::clamp(numChannels, 1, kMaxChannels);
  lookahead_ = std::max(1, int(std::lround(lookaheadMs * 0.001 * sampleRate)));
  window_ = lookahead_ + 1;
  for (auto& d : delay_) d.assign(size_t(lookahead_), 0.f);
  dqVal_.assign(size_t(window_ + 1), 1.f);
  dqIdx_.assign(size_t(window_ + 1), 0);
  boxBuf_.assign(size_t(window_), 1.f);
  setParams(params_);
  reset();
}

void Limiter::reset() {
  for (auto& d : delay_) std::fill(d.begin(), d.end(), 0.f);
  delayPos_ = 0;
  dqHead_ = dqSize_ = 0;
  t_ = 0;
  released_ = 1.f;
  std::fill(boxBuf_.begin(), boxBuf_.end(), 1.f);
  boxPos_ = 0;
  boxSum_ = double(window_);
  lastGrDb_.store(0.f, std::memory_order_relaxed);
}

void Limiter::setParams(const LimiterParams& p) {
  params_ = p;
  ceiling_ = dbToGain(std::min(p.ceilingDb, 0.f));
  releaseCoeff_ = float(1.0 - std::exp(-1.0 / (0.001 * std::max(1.f, p.releaseMs) * sampleRate_)));
}

float Limiter::pushMin(float v) {
  const int cap = int(dqVal_.size());
  // Drop larger-or-equal values from the back.
  while (dqSize_ > 0) {
    const int back = (dqHead_ + dqSize_ - 1) % cap;
    if (dqVal_[size_t(back)] < v) break;
    --dqSize_;
  }
  const int at = (dqHead_ + dqSize_) % cap;
  dqVal_[size_t(at)] = v;
  dqIdx_[size_t(at)] = t_;
  ++dqSize_;
  // Expire entries older than the window.
  while (dqIdx_[size_t(dqHead_)] <= t_ - window_) {
    dqHead_ = (dqHead_ + 1) % cap;
    --dqSize_;
  }
  ++t_;
  return dqVal_[size_t(dqHead_)];
}

void Limiter::process(float* const* ch, int numChannels, int numFrames) {
  numChannels = std::min(numChannels, numChannels_);
  if (!params_.enabled) return;
  const float invWindow = 1.f / float(window_);
  float minGain = 1.f;

  for (int i = 0; i < numFrames; ++i) {
    float peak = 0.f;
    for (int c = 0; c < numChannels; ++c) peak = std::max(peak, std::fabs(ch[c][i]));
    const float required = peak > ceiling_ ? ceiling_ / peak : 1.f;

    const float held = pushMin(required);
    if (held < released_)
      released_ = held;
    else
      released_ += (held - released_) * releaseCoeff_;

    boxSum_ += double(released_) - double(boxBuf_[size_t(boxPos_)]);
    boxBuf_[size_t(boxPos_)] = released_;
    boxPos_ = boxPos_ + 1 == window_ ? 0 : boxPos_ + 1;
    // Guard against accumulated rounding pushing the average above a value
    // it mathematically cannot exceed.
    const float gain = std::min(float(boxSum_) * invWindow, 1.f);
    minGain = std::min(minGain, gain);

    for (int c = 0; c < numChannels; ++c) {
      float& slot = delay_[size_t(c)][size_t(delayPos_)];
      const float delayed = slot;
      slot = ch[c][i];
      // Final safety clamp handles float rounding in the averaging only;
      // it should essentially never engage.
      ch[c][i] = std::clamp(delayed * gain, -ceiling_, ceiling_);
    }
    delayPos_ = delayPos_ + 1 == lookahead_ ? 0 : delayPos_ + 1;
  }
  lastGrDb_.store(gainToDb(minGain), std::memory_order_relaxed);
}

}  // namespace punch
