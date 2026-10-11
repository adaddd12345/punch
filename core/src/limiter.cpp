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
  slow_ = 1.f;
  std::fill(boxBuf_.begin(), boxBuf_.end(), 1.f);
  boxPos_ = 0;
  boxSum_ = double(window_);
  lastGrDb_.store(0.f, std::memory_order_relaxed);
}

void Limiter::setParams(const LimiterParams& p) {
  params_ = p;
  ceiling_ = dbToGain(std::min(p.ceilingDb, 0.f));
  releaseCoeff_ = float(1.0 - std::exp(-1.0 / (0.001 * std::max(1.f, p.releaseMs) * sampleRate_)));
  slowCoeff_ = p.slowReleaseMs > 0.f
                   ? float(1.0 - std::exp(-1.0 / (0.001 * double(p.slowReleaseMs) * sampleRate_)))
                   : 0.f;
  if (p.clipKneeDb > 0.f) {
    clipKnee_ = ceiling_ * dbToGain(-p.clipKneeDb);
    // Soft region spans knee .. knee + 2*(ceiling-knee) on the input side and
    // maps into knee .. ceiling: up to ~knee dB of peak reduction, smoothly.
    clipRange_ = ceiling_ - clipKnee_;
  } else {
    clipKnee_ = 1e9f;
    clipRange_ = 0.f;
  }
}

static inline float softClip(float x, float knee, float range) {
  const float a = std::fabs(x);
  if (a <= knee) return x;
  // tanh shoulder: slope 1 at the knee, asymptote at knee + range.
  const float y = knee + range * std::tanh((a - knee) / range);
  return std::copysign(y, x);
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
  process(ch, numChannels, numFrames, nullptr);
}

void Limiter::process(float* const* ch, int numChannels, int numFrames, const float* ceilingPerFrame) {
  numChannels = std::min(numChannels, numChannels_);
  if (!params_.enabled) return;
  const float invWindow = 1.f / float(window_);
  float minGain = 1.f;

  const bool clip = clipRange_ > 0.f;
  for (int i = 0; i < numFrames; ++i) {
    if (clip)
      for (int c = 0; c < numChannels; ++c) ch[c][i] = softClip(ch[c][i], clipKnee_, clipRange_);
    float peak = 0.f;
    for (int c = 0; c < numChannels; ++c) peak = std::max(peak, std::fabs(ch[c][i]));
    const float ceil = ceilingPerFrame ? std::min(ceilingPerFrame[i], ceiling_) : ceiling_;
    const float required = peak > ceil ? ceil / peak : 1.f;

    const float held = pushMin(required);
    if (slowCoeff_ > 0.f) {
      // Slow average of the held gain; the fast release can't overshoot it.
      slow_ += (held - slow_) * slowCoeff_;
      if (held < released_)
        released_ = held;
      else
        released_ += (std::max(std::min(held, slow_), released_) - released_) * releaseCoeff_;
    } else if (held < released_) {
      released_ = held;
    } else {
      released_ += (held - released_) * releaseCoeff_;
    }

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

// ================================================================ BassPriorityLimiter

void BassPriorityLimiter::prepare(double sampleRate, int numChannels, int maxFrames, float lookaheadMs) {
  sampleRate_ = sampleRate;
  numChannels_ = std::clamp(numChannels, 1, kMaxChannels);
  chunk_ = std::max(64, maxFrames);
  low_.prepare(sampleRate, numChannels_, lookaheadMs);
  for (auto& b : lowBuf_) b.assign(size_t(chunk_), 0.f);
  for (auto& b : dryBuf_) b.assign(size_t(chunk_), 0.f);
  for (auto& d : hiDelay_) d.assign(size_t(low_.latencyFrames()), 0.f);
  for (auto& d : dryDelay_) d.assign(size_t(low_.latencyFrames()), 0.f);
  wet_.prepare(sampleRate, 15.0);
  ceil_.assign(size_t(chunk_), 1.f);
  setParams(gainToDb(ceiling_), 120.f, 150.f, limiting_);
  reset();
}

void BassPriorityLimiter::reset() {
  for (auto& c : st_) c = Chan{};
  low_.reset();
  for (auto& d : hiDelay_) std::fill(d.begin(), d.end(), 0.f);
  for (auto& d : dryDelay_) std::fill(d.begin(), d.end(), 0.f);
  hiPos_ = 0;
  wet_.snap(wet_.target());
}

void BassPriorityLimiter::setParams(float ceilingDb, float crossoverHz, float releaseMs, bool limiting) {
  ceiling_ = dbToGain(std::min(ceilingDb, 0.f));
  limiting_ = limiting;
  const double fc = std::clamp<double>(crossoverHz, 40.0, 400.0);
  lp_ = SvfCoeffs::make({FilterType::LowPass, fc, 0.0, 0.7071, true}, sampleRate_);
  hp_ = SvfCoeffs::make({FilterType::HighPass, fc, 0.0, 0.7071, true}, sampleRate_);
  low_.setParams({ceilingDb, releaseMs, true});
  wet_.setTarget(limiting ? 1.f : 0.f);
}

void BassPriorityLimiter::process(float* const* ch, int numChannels, int numFrames) {
  numChannels = std::min(numChannels, numChannels_);
  for (int s = 0; s < numFrames; s += chunk_) {
    float* p[kMaxChannels];
    for (int c = 0; c < numChannels; ++c) p[c] = ch[c] + s;
    processChunk(p, numChannels, std::min(chunk_, numFrames - s));
  }
}

static constexpr float kMinBassGain = 0.3f;  // about -10.5 dB

void BassPriorityLimiter::processChunk(float* const* ch, int numChannels, int n) {
  const int L = int(hiDelay_[0].size());
  float* low[kMaxChannels];
  for (int c = 0; c < numChannels; ++c) low[c] = lowBuf_[size_t(c)].data();

  // Split. ch keeps the highs, lowBuf the lows. Per frame, find the largest
  // low-band gain g in [0, 1] with |g*lo + hi| <= ceiling on every channel.
  // |g*lo + hi| is convex in g and fine at g = 0 (when |hi| <= ceiling), so
  // every gain below g is safe too, which is exactly what the limiter's
  // smoothing needs. Expressed as a per-frame low-band ceiling g * peak(|lo|).
  // The raw input goes into dryDelay_ for the bypass crossfade.
  int pos = hiPos_;
  for (int i = 0; i < n; ++i) {
    float g = 1.f, peakLo = 0.f;
    for (int c = 0; c < numChannels; ++c) {
      Chan& s = st_[size_t(c)];
      const float x = ch[c][i];
      dryBuf_[size_t(c)][size_t(i)] = x;
      // Linkwitz-Riley 4 split: bands in phase at every frequency, summing
      // to a flat-magnitude allpass. (A plain x - low complement leaks lots
      // of bass into the highs through the low-pass phase lag.)
      const float lo = s.lp2.tick(lp_, s.lp1.tick(lp_, x));
      const float hi = s.hp2.tick(hp_, s.hp1.tick(hp_, x));
      low[c][i] = lo;
      ch[c][i] = hi;
      const float alo = std::fabs(lo), ahi = std::fabs(hi);
      peakLo = std::max(peakLo, alo);
      if (alo > 1e-9f) {
        const bool same = (lo >= 0.f) == (hi >= 0.f);
        const float room = same ? ceiling_ - ahi : ceiling_ + ahi;
        g = std::min(g, std::max(0.f, room) / alo);
      }
    }
    // Never take the bass down more than kMinBassGain: past that point the
    // rest of the mix is over on its own (e.g. a big Boost), and the
    // full-band limiter after us shares the reduction instead of the bass
    // vanishing.
    g = std::max(g, kMinBassGain);
    ceil_[size_t(i)] = std::max(1e-6f, std::min(1.f, g) * peakLo);
  }

  low_.process(low, numChannels, n, ceil_.data());

  // Delay the highs (and the dry input) by the low limiter's look-ahead and
  // sum. Not limiting (bypass): crossfade to the plain delayed input so the
  // stage is bit-transparent; latency stays constant either way.
  for (int i = 0; i < n; ++i) {
    const float w = wet_.next();
    for (int c = 0; c < numChannels; ++c) {
      float& hslot = hiDelay_[size_t(c)][size_t(pos)];
      const float hi = hslot;
      hslot = ch[c][i];
      float& dslot = dryDelay_[size_t(c)][size_t(pos)];
      const float dry = dslot;
      dslot = dryBuf_[size_t(c)][size_t(i)];
      const float wet = low[c][i] + hi;
      ch[c][i] = w == 1.f ? wet : w == 0.f ? dry : dry + w * (wet - dry);
    }
    pos = pos + 1 == L ? 0 : pos + 1;
  }
  hiPos_ = pos;
}

}  // namespace punch
