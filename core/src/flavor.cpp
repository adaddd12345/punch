#include "punch/flavor.hpp"

#include <algorithm>
#include <cmath>

namespace punch {

namespace {
float coeffFor(double ms, double sampleRate) {
  return float(1.0 - std::exp(-1.0 / (std::max(0.05, ms) * 0.001 * sampleRate)));
}
// log(cosh(u)) in double (the ADAA difference cancels badly in float).
inline double logCosh(double u) {
  const double a = std::fabs(u);
  return a + std::log1p(std::exp(-2.0 * a)) - 0.6931471805599453;
}
// Cubic soft clip: unity slope at 0, flat (±1) from |v| = 1.5.
inline float softClip(float v) {
  if (v >= 1.5f) return 1.f;
  if (v <= -1.5f) return -1.f;
  return v - (4.f / 27.f) * v * v * v;
}
SvfCoeffs make(FilterType t, double hz, double gainDb, double q, double fs) {
  return SvfCoeffs::make({t, hz, gainDb, q, true}, fs);
}
}  // namespace

// ================================================================ BassCharacter

void BassCharacter::prepare(double sampleRate, int numChannels) {
  sampleRate_ = sampleRate;
  numChannels_ = std::clamp(numChannels, 1, kMaxChannels);
  amount_.prepare(sampleRate, 10.0);
  driveScale_.prepare(sampleRate, 10.0);
  mixStep_ = float(1.0 / (0.025 * sampleRate));
  envCoeff_ = coeffFor(300.0, sampleRate);
  aFast_ = coeffFor(0.5, sampleRate);
  aSlow_ = coeffFor(25.0, sampleRate);
  rShort_ = coeffFor(40.0, sampleRate);
  rLong_ = coeffFor(300.0, sampleRate);
  gSmooth_ = coeffFor(1.0, sampleRate);
  diffHp_ = make(FilterType::HighPass, 10.0, 0.0, 0.7071, sampleRate);
  setParams(p_);
  amount_.snap(amount_.target());
  driveScale_.snap(driveScale_.target());
  active_ = p_.kind;
  mix_ = active_ != BassCharacterKind::Off ? 1.f : 0.f;
  reset();
}

void BassCharacter::reset() {
  for (auto& c : st_) c = Chan{};
  diffHpState_.reset();
  postState_.reset();
  prevU_ = 0.0;
  envRaw_ = envWet_ = 0.f;
  eFast_ = eSlowAtt_ = eLong_ = gDb_ = 0.f;
  coeffAmount_ = -1.f;
}

void BassCharacter::setParams(const BassCharacterParams& p) {
  p_ = p;
  if (p_.kind != BassCharacterKind::Distort && p_.kind != BassCharacterKind::Punch) p_.kind = BassCharacterKind::Off;
  amount_.setTarget(std::isfinite(p.amount) ? std::clamp(p.amount, 0.f, 1.f) : 0.6f);
  driveScale_.setTarget(std::isfinite(p.driveScale) ? std::clamp(p.driveScale, 0.f, 1.f) : 1.f);
}

void BassCharacter::updateCoeffs(float a) {
  coeffAmount_ = a;
  const double fs = sampleRate_;
  const bool distortKind = active_ == BassCharacterKind::Distort;
  split_ = make(FilterType::LowPass, distortKind ? 120.0 : 150.0, 0.0, 0.7071, fs);  // x2 = LR4
  post_ = make(FilterType::LowPass, 3000.0 - 1500.0 * double(a), 0.0, 0.7071, fs);
  dip_ = make(FilterType::Bell, 250.0, -(1.0 + 2.0 * double(a)), 1.0, fs);
}

float BassCharacter::distort(float low) {
  const float a = amount_.current();
  const float driveDb = (6.f + 18.f * a) * driveScale_.next();
  const float g = dbToGain(driveDb);
  const float bias = 0.2f + 0.3f * a;  // asymmetry 0.2..0.5: even harmonics
  const float tb = std::tanh(bias);
  const double u = double(g * low + bias);
  const double du = u - prevU_;
  const float y = std::fabs(du) > 1e-5 ? float((logCosh(u) - logCosh(prevU_)) / du)
                                       : std::tanh(float(0.5 * (u + prevU_)));
  prevU_ = u;
  // Then a soft clip that flattens the tops: the square-ish 808 grit.
  float w = softClip(1.6f * (y - tb)) * 0.625f;
  w /= g * (1.f - tb * tb);  // small-signal unity
  w = postState_.tick(post_, w);
  // Level match: the distorted lows sit at the raw lows' RMS (300 ms).
  envRaw_ += envCoeff_ * (low * low - envRaw_);
  envWet_ += envCoeff_ * (w * w - envWet_);
  const float gain = std::clamp(std::sqrt((envRaw_ + 1e-12f) / (envWet_ + 1e-12f)), 0.25f, 4.f);
  return w * gain;
}

float BassCharacter::punch(float low) {
  const float a = amount_.current();
  const float e = std::fabs(low);
  eFast_ += (e - eFast_) * (e > eFast_ ? aFast_ : rShort_);
  eSlowAtt_ += (e - eSlowAtt_) * (e > eSlowAtt_ ? aSlow_ : rShort_);
  eLong_ += (e - eLong_) * (e > eLong_ ? aFast_ : rLong_);
  float target = 0.f;
  if (eFast_ > 1e-6f) {
    const float atk = std::clamp(gainToDb(eFast_ / std::max(eSlowAtt_, 1e-9f)) / 6.f, 0.f, 1.f);
    const float sus = std::clamp(gainToDb(eLong_ / eFast_) / 6.f, 0.f, 1.f);
    target = 6.f * a * atk - 4.f * a * sus;
  }
  gDb_ += (target - gDb_) * gSmooth_;
  const float v = low * dbToGain(gDb_);
  // Light 2nd-harmonic warmth (up to ~3 dB drive, asymmetry 0.3).
  const float gw = dbToGain(3.f * a), b = 0.15f, tb = 0.148885f;  // tanh(0.15)
  return (std::tanh(gw * v + b) - tb) / (gw * (1.f - tb * tb));
}

void BassCharacter::process(float* const* ch, int numChannels, int numFrames) {
  numChannels = std::min(numChannels, numChannels_);
  if (numChannels < 1) return;
  if (active_ == BassCharacterKind::Off && p_.kind == BassCharacterKind::Off) {
    // Keep the glides current so a later switch starts from the right place.
    if (!amount_.settled() || !driveScale_.settled()) {
      amount_.snap(amount_.target());
      driveScale_.snap(driveScale_.target());
    }
    return;  // bit-exact
  }
  if (active_ != BassCharacterKind::Off && std::fabs(amount_.current() - coeffAmount_) > 1e-3f)
    updateCoeffs(amount_.current());
  for (int i = 0; i < numFrames; ++i) {
    // Kind switch: ramp the mix to 0, swap, ramp back up.
    if (active_ != p_.kind) {
      mix_ -= mixStep_;
      if (mix_ <= 0.f) {
        mix_ = 0.f;
        active_ = p_.kind;
        reset();
        if (active_ != BassCharacterKind::Off) updateCoeffs(amount_.current());
      }
    } else if (active_ != BassCharacterKind::Off && mix_ < 1.f) {
      mix_ = std::min(1.f, mix_ + mixStep_);
    }
    amount_.next();
    if (active_ == BassCharacterKind::Off) {
      if (p_.kind == BassCharacterKind::Off) return;  // the rest of the block stays untouched
      continue;
    }
    if ((i & 31) == 31 && std::fabs(amount_.current() - coeffAmount_) > 1e-3f) updateCoeffs(amount_.current());

    float lows[kMaxChannels];
    float mono = 0.f;
    for (int c = 0; c < numChannels; ++c) {
      Chan& s = st_[size_t(c)];
      lows[c] = s.lp2.tick(split_, s.lp1.tick(split_, ch[c][i]));
      mono += lows[c];
    }
    mono /= float(numChannels);
    const float proc = active_ == BassCharacterKind::Distort ? distort(mono) : punch(mono);
    const float d = diffHpState_.tick(diffHp_, proc - mono);
    const bool dip = active_ == BassCharacterKind::Punch;
    const float m = mix_;
    for (int c = 0; c < numChannels; ++c) {
      const float x = ch[c][i];
      float delta = mono - lows[c] + d;
      if (dip) delta += st_[size_t(c)].dip.tick(dip_, x) - x;
      ch[c][i] = x + m * delta;
    }
  }
}

// ================================================================ LateNight

namespace {
constexpr float kSatBias = 0.1f;  // asymmetry 0.2
constexpr float kSatMix = 0.3f;
constexpr float kCompThresholdDb = -14.f;
constexpr float kCompMakeupDb = 1.f;
}  // namespace

void LateNight::prepare(double sampleRate, int numChannels) {
  sampleRate_ = sampleRate;
  numChannels_ = std::clamp(numChannels, 1, kMaxChannels);
  haze_.prepare(sampleRate, 30.0);
  fadeStep_ = float(1.0 / (0.3 * sampleRate));
  compAtt_ = coeffFor(30.0, sampleRate);
  compRel_ = coeffFor(300.0, sampleRate);
  dcBlock_ = make(FilterType::HighPass, 15.0, 0.0, 0.7071, sampleRate);
  scHp_ = make(FilterType::HighPass, 100.0, 0.0, 0.7071, sampleRate);
  room_.prepare(sampleRate);  // sizes the room's buffers for this rate
  setParams(p_);
  haze_.snap(haze_.target());
  fade_ = fadeTarget_;
  room_.prepare(sampleRate);  // again, so its taps and mix land on p_
  reset();
}

void LateNight::reset() {
  for (auto& c : st_) c = Chan{};
  envDb_ = 0.f;
  coeffHaze_ = -1.f;
  room_.reset();
}

void LateNight::setParams(const LateNightParams& p) {
  p_ = p;
  const float h = std::isfinite(p.haze) ? std::clamp(p.haze, 0.f, 1.f) : 0.5f;
  haze_.setTarget(h);
  fadeTarget_ = p.enabled ? 1.f : 0.f;
  AmbienceParams r;
  r.enabled = p.enabled;
  r.mix = 0.08f + 0.07f * h;
  r.size = 0.4f;
  r.dampingHz = 3000.f;
  r.returnWidth = 1.5f;  // widen only the reverb return
  room_.setParams(r);
}

void LateNight::updateCoeffs(float h) {
  coeffHaze_ = h;
  const double fs = sampleRate_;
  lowShelf_ = make(FilterType::LowShelf, 70.0, 2.0 + 2.0 * double(h), 0.7071, fs);
  dip_ = make(FilterType::Bell, 300.0, -2.0, 0.8, fs);
  // 5 kHz -> 2.5 kHz, gliding in log frequency.
  lpf_ = make(FilterType::LowPass, 5000.0 * std::exp2(-double(h)), 0.0, 0.9, fs);
  satGain_ = dbToGain(3.f + 3.f * h);
  const float tb = std::tanh(kSatBias);
  satNorm_ = 1.f / (satGain_ * (1.f - tb * tb));
}

void LateNight::process(float* const* ch, int numChannels, int numFrames) {
  numChannels = std::min(numChannels, numChannels_);
  if (numChannels < 1) return;
  if (fade_ == 0.f && fadeTarget_ == 0.f) {
    if (!haze_.settled()) haze_.snap(haze_.target());
    room_.process(ch, numChannels, numFrames);  // returns at once when its mix is 0
    return;
  }
  const float tb = std::tanh(kSatBias);
  if (std::fabs(haze_.current() - coeffHaze_) > 1e-4f) updateCoeffs(haze_.current());
  for (int i = 0; i < numFrames; ++i) {
    if (fade_ < fadeTarget_) fade_ = std::min(fadeTarget_, fade_ + fadeStep_);
    else if (fade_ > fadeTarget_) fade_ = std::max(fadeTarget_, fade_ - fadeStep_);
    haze_.next();
    if ((i & 31) == 31 && std::fabs(haze_.current() - coeffHaze_) > 1e-4f) updateCoeffs(haze_.current());

    // Glue compressor: channel-linked, detector ignores the lows.
    float peak = 0.f;
    for (int c = 0; c < numChannels; ++c)
      peak = std::max(peak, std::fabs(st_[size_t(c)].sc.tick(scHp_, ch[c][i])));
    const float tgt = Compressor::computeGainDb(gainToDb(peak), kCompThresholdDb, 2.f, 6.f);
    envDb_ += (tgt - envDb_) * (tgt < envDb_ ? compAtt_ : compRel_);
    const float cg = dbToGain(envDb_ + kCompMakeupDb);

    const float f = fade_;
    for (int c = 0; c < numChannels; ++c) {
      Chan& s = st_[size_t(c)];
      const float x = ch[c][i];
      float v = s.dip.tick(dip_, s.shelf.tick(lowShelf_, x));
      const float sat = s.dc.tick(dcBlock_, (std::tanh(satGain_ * v + kSatBias) - tb) * satNorm_);
      v += kSatMix * (sat - v);
      v = s.lpf.tick(lpf_, v * cg);
      ch[c][i] = x + f * (v - x);
    }
  }
  room_.process(ch, numChannels, numFrames);
}

}  // namespace punch
