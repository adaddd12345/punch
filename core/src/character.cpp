#include "punch/character.hpp"

#include <algorithm>
#include <cmath>

namespace punch {

namespace {
float coeffFor(double ms, double sampleRate) {
  return float(1.0 - std::exp(-1.0 / (std::max(0.05, ms) * 0.001 * sampleRate)));
}
}  // namespace

// ================================================================ Compressor

float Compressor::computeGainDb(float x, float t, float r, float w) {
  const float slope = 1.f / std::max(1.f, r) - 1.f;  // <= 0
  const float over = x - t;
  if (2.f * over < -w) return 0.f;
  if (w > 0.f && 2.f * std::fabs(over) <= w) {
    const float k = over + 0.5f * w;
    return slope * k * k / (2.f * w);
  }
  return slope * over;
}

void Compressor::prepare(double sampleRate) {
  sampleRate_ = sampleRate;
  mix_.prepare(sampleRate, 30.0);
  makeup_.prepare(sampleRate, 30.0);
  setParams(p_);
  mix_.snap(mix_.target());
  makeup_.snap(makeup_.target());
  reset();
}

void Compressor::reset() {
  envDb_ = 0.f;
  grDb_ = 0.f;
  for (auto& s : scState_) s.reset();
}

void Compressor::setParams(const CompressorParams& p) {
  p_ = p;
  attackCoeff_ = coeffFor(p.attackMs, sampleRate_);
  scHp_ = SvfCoeffs::make({FilterType::HighPass, std::max(10.0, double(p.sidechainHpHz)), 0.0, 0.7071,
                           p.sidechainHpHz > 0.f}, sampleRate_);
  releaseCoeff_ = coeffFor(p.releaseMs, sampleRate_);
  mix_.setTarget(p.enabled ? 1.f : 0.f);
  makeup_.setTarget(p.enabled ? std::clamp(p.makeupDb, 0.f, 24.f) : 0.f);
}

void Compressor::process(float* const* ch, int numChannels, int numFrames) {
  if (mix_.settled() && mix_.target() == 0.f && envDb_ > -0.01f) return;
  float minGr = 0.f;
  for (int i = 0; i < numFrames; ++i) {
    float peak = 0.f;
    for (int c = 0; c < numChannels; ++c)
      peak = std::max(peak, std::fabs(scState_[size_t(c)].tick(scHp_, ch[c][i])));
    const float levelDb = 20.f * std::log10(std::max(peak, 1e-9f));
    const float target = computeGainDb(levelDb, p_.thresholdDb, p_.ratio, p_.kneeDb);
    envDb_ += (target - envDb_) * (target < envDb_ ? attackCoeff_ : releaseCoeff_);
    const float m = mix_.next();
    const float gDb = m * envDb_ + makeup_.next();
    const float g = std::pow(10.f, gDb * 0.05f);
    for (int c = 0; c < numChannels; ++c) ch[c][i] *= g;
    minGr = std::min(minGr, m * envDb_);
  }
  grDb_ = minGr;
}

// ================================================================ Saturator

namespace {
// log(cosh(u)), stable for large |u|.
inline float logCosh(float u) {
  const float a = std::fabs(u);
  return a + std::log1p(std::exp(-2.f * a)) - 0.69314718f;
}
}  // namespace

void Saturator::prepare(double sampleRate, int numChannels) {
  sampleRate_ = sampleRate;
  numChannels_ = std::clamp(numChannels, 1, kMaxChannels);
  mix_.prepare(sampleRate, 30.0);
  setParams(p_);
  mix_.snap(mix_.target());
  reset();
}

void Saturator::reset() {
  for (auto& c : st_) c = Chan{};
  for (auto& c : st_) c.prevU = bias_;
}

void Saturator::setParams(const SaturatorParams& p) {
  p_ = p;
  gain_ = dbToGain(std::clamp(p.driveDb, 0.f, 30.f));
  bias_ = 0.5f * std::clamp(p.asymmetry, 0.f, 1.f);
  biasOut_ = std::tanh(bias_);
  splitBand_ = p.crossoverHz > 0.f;
  if (splitBand_) {
    // Split band: the highs are a small residue, so normalise for unity
    // small-signal gain; otherwise peak scaling would boost them ~drive×.
    norm_ = 1.f / std::max(1e-3f, gain_ * (1.f - biasOut_ * biasOut_));
  } else {
    // Peak-preserving normalisation: a full-scale input maps to ~full scale.
    norm_ = 1.f / std::max(1e-3f, std::tanh(gain_ + bias_) - biasOut_);
  }
  tone_ = SvfCoeffs::make({FilterType::LowPass, std::clamp<double>(p.toneHz, 1000.0, 20000.0), 0.0, 0.7071, true},
                          sampleRate_);
  dcBlock_ = SvfCoeffs::make({FilterType::HighPass, 15.0, 0.0, 0.7071, true}, sampleRate_);
  split_ = SvfCoeffs::make({FilterType::HighPass, std::clamp<double>(p.crossoverHz, 20.0, 1000.0), 0.0, 0.7071,
                            splitBand_}, sampleRate_);
  mix_.setTarget(p.enabled ? std::clamp(p.mix, 0.f, 1.f) : 0.f);
}

void Saturator::process(float* const* ch, int numChannels, int numFrames) {
  numChannels = std::min(numChannels, numChannels_);
  if (mix_.settled() && mix_.target() == 0.f) return;
  for (int i = 0; i < numFrames; ++i) {
    const float m = mix_.next();
    for (int c = 0; c < numChannels; ++c) {
      Chan& s = st_[size_t(c)];
      const float x = ch[c][i];
      // Split band: saturate only the highs h; lows (x - h) pass untouched,
      // and x - h + h reconstructs x exactly when mix = 0.
      const float h = splitBand_ ? s.split.tick(split_, x) : x;
      const float u = gain_ * h + bias_;
      const float du = u - s.prevU;
      const float y = std::fabs(du) > 1e-5f ? (logCosh(u) - logCosh(s.prevU)) / du
                                            : std::tanh(0.5f * (u + s.prevU));
      s.prevU = u;
      float wet = (y - biasOut_) * norm_;
      wet = s.dc.tick(dcBlock_, s.tone.tick(tone_, wet));
      ch[c][i] = x + m * (wet - h);
    }
  }
}

// ================================================================ NoiseBed

float NoiseBed::Gen::next(NoiseColor c) {
  rng ^= rng << 13;
  rng ^= rng >> 17;
  rng ^= rng << 5;
  const float white = float(rng >> 8) * (2.f / 16777216.f) - 1.f;
  switch (c) {
    case NoiseColor::White:
      return white;
    case NoiseColor::Pink: {
      b0 = 0.99886f * b0 + white * 0.0555179f;
      b1 = 0.99332f * b1 + white * 0.0750759f;
      b2 = 0.96900f * b2 + white * 0.1538520f;
      b3 = 0.86650f * b3 + white * 0.3104856f;
      b4 = 0.55000f * b4 + white * 0.5329522f;
      b5 = -0.7616f * b5 - white * 0.0168980f;
      const float pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362f;
      b6 = white * 0.115926f;
      return pink;
    }
    case NoiseColor::Brown:
      brown = (brown + 0.02f * white) / 1.02f;
      return brown;
  }
  return white;
}

void NoiseBed::prepare(double sampleRate) {
  sampleRate_ = sampleRate;
  level_.prepare(sampleRate, 200.0);  // slow, gentle fades
  hp_ = SvfCoeffs::make({FilterType::HighPass, 20.0, 0.0, 0.7071, true}, sampleRate);
  setParams(p_);
  level_.snap(level_.target());
  reset();
}

void NoiseBed::reset() {
  gen_[0] = Gen{};
  gen_[1] = Gen{};
  gen_[1].rng = 0x7F4A7C15u;  // decorrelated right channel
  for (auto& s : hpState_) s.reset();
}

void NoiseBed::setParams(const NoiseParams& p) {
  p_ = p;
  // Per-colour normalisation to unit RMS. Constants measured from these
  // exact generators over 2M samples; the noise_level test checks them.
  float rms = 0.5774f;  // uniform white
  if (p.color == NoiseColor::Pink) rms = 1.7655f;
  if (p.color == NoiseColor::Brown) rms = 0.0573f;
  const float target = p.enabled ? dbToGain(std::clamp(p.levelDb, -90.f, -6.f)) / rms : 0.f;
  level_.setTarget(target);
}

void NoiseBed::process(float* const* ch, int numChannels, int numFrames) {
  if (level_.settled() && level_.target() == 0.f) return;
  const int n = std::min(numChannels, 2);
  for (int i = 0; i < numFrames; ++i) {
    const float g = level_.next();
    for (int c = 0; c < n; ++c) {
      const float v = hpState_[size_t(c)].tick(hp_, gen_[size_t(c)].next(p_.color));
      ch[c][i] += g * v;
    }
  }
}

// ================================================================ Ambience

float Ambience::Allpass::tick(float x) {
  const float d = buf[size_t(pos)];
  const float y = d - g * x;
  buf[size_t(pos)] = x + g * y;
  pos = pos + 1 == int(buf.size()) ? 0 : pos + 1;
  return y;
}

void Ambience::prepare(double sampleRate) {
  sampleRate_ = sampleRate;
  delayLen_ = int(0.1 * sampleRate) + 1;
  for (auto& d : delay_) d.assign(size_t(delayLen_), 0.f);
  const double apMs[2][kAllpasses] = {{5.3, 1.7}, {5.9, 2.1}};
  for (int c = 0; c < 2; ++c)
    for (int k = 0; k < kAllpasses; ++k) {
      ap_[size_t(c)][size_t(k)].buf.assign(size_t(std::max(1.0, apMs[c][k] * 0.001 * sampleRate)), 0.f);
      ap_[size_t(c)][size_t(k)].g = 0.6f;
    }
  mix_.prepare(sampleRate, 40.0);
  setParams(p_);
  mix_.snap(mix_.target());
  reset();
}

void Ambience::reset() {
  for (auto& d : delay_) std::fill(d.begin(), d.end(), 0.f);
  for (auto& c : ap_)
    for (auto& a : c) {
      std::fill(a.buf.begin(), a.buf.end(), 0.f);
      a.pos = 0;
    }
  for (auto& s : dampState_) s.reset();
  delayPos_ = 0;
}

void Ambience::setParams(const AmbienceParams& p) {
  p_ = p;
  static constexpr double kL[kTaps] = {7.1, 11.3, 17.9, 23.7, 31.3, 41.9};
  static constexpr double kR[kTaps] = {8.3, 13.1, 19.7, 27.1, 35.3, 45.7};
  const double scale = 0.4 + 1.2 * std::clamp(double(p.size), 0.0, 1.0);
  for (int i = 0; i < kTaps; ++i) {
    tapL_[size_t(i)] = std::clamp(int(kL[i] * scale * 0.001 * sampleRate_), 1, delayLen_ - 1);
    tapR_[size_t(i)] = std::clamp(int(kR[i] * scale * 0.001 * sampleRate_), 1, delayLen_ - 1);
    tapGain_[size_t(i)] = 0.55f * std::pow(0.8f, float(i));
  }
  damp_ = SvfCoeffs::make({FilterType::LowPass, std::clamp<double>(p.dampingHz, 1500.0, 16000.0), 0.0, 0.7071, true},
                          sampleRate_);
  mix_.setTarget(p.enabled ? std::clamp(p.mix, 0.f, 1.f) : 0.f);
}

void Ambience::process(float* const* ch, int numChannels, int numFrames) {
  if (numChannels < 1) return;
  if (mix_.settled() && mix_.target() == 0.f) return;
  float* L = ch[0];
  float* R = numChannels > 1 ? ch[1] : ch[0];
  for (int i = 0; i < numFrames; ++i) {
    const float m = mix_.next();
    auto at = [&](int ch01, int tap) {
      int idx = delayPos_ - tap;
      if (idx < 0) idx += delayLen_;
      return delay_[size_t(ch01)][size_t(idx)];
    };
    float wl = 0.f, wr = 0.f;
    for (int t = 0; t < kTaps; ++t) {
      // Alternate same-side / cross-fed reflections for a wide image.
      wl += tapGain_[size_t(t)] * at(t % 2 == 0 ? 0 : 1, tapL_[size_t(t)]);
      wr += tapGain_[size_t(t)] * at(t % 2 == 0 ? 1 : 0, tapR_[size_t(t)]);
    }
    for (auto& a : ap_[0]) wl = a.tick(wl);
    for (auto& a : ap_[1]) wr = a.tick(wr);
    wl = dampState_[0].tick(damp_, wl);
    wr = dampState_[1].tick(damp_, wr);
    delay_[0][size_t(delayPos_)] = L[i];
    delay_[1][size_t(delayPos_)] = R[i];
    delayPos_ = delayPos_ + 1 == delayLen_ ? 0 : delayPos_ + 1;
    L[i] += m * wl;
    if (numChannels > 1) R[i] += m * wr;
  }
}

}  // namespace punch
