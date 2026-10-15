#include "punch/enhancers.hpp"

#include <algorithm>
#include <cmath>
#include <numbers>

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

// ---------------------------------------------------------------- Bass Shaker

namespace {
// Niemitalo's 4+4 allpass coefficients, squared (z^-2 sections).
constexpr float sq(double c) { return float(c * c); }
constexpr std::array<float, 4> kHilA = {sq(0.6923878), sq(0.9360654322959), sq(0.9882295226860), sq(0.9987488452737)};
constexpr std::array<float, 4> kHilB = {sq(0.4021921162426), sq(0.8561710882420), sq(0.9722909545651), sq(0.9952884791278)};

constexpr double kPunchHz = 100.0, kPunchQ = 0.8, kPunchDb = 8.0;
constexpr double kBodyHz = 80.0, kBodyQ = 0.71, kBodyDb = 9.0, kBodySusDb = 4.0;
constexpr double kDipHz = 260.0, kDipQ = 1.1;
constexpr float kHarmMix = 0.35f;
constexpr double kPaceBias = 0.9;  // releases run ~10% fast: tighter on doubtful tempos
constexpr double kMinBpm = 70.0, kMaxBpm = 180.0;

inline float dbOf(float v) { return 20.f * std::log10(std::max(v, 1e-9f)); }

void bell(SvfCoeffs& c, double w, double q, double db) {
  const double A = std::pow(10.0, db / 40.0), k = 1.0 / (q * A);
  const double a1 = 1.0 / (1.0 + w * (w + k));
  c.a1 = float(a1); c.a2 = float(w * a1); c.a3 = float(w * w * a1);
  c.m0 = 1.f; c.m1 = float(k * (A * A - 1.0)); c.m2 = 0.f;
}
void lowShelf(SvfCoeffs& c, double w, double q, double db) {
  const double A = std::pow(10.0, db / 40.0), g = w / std::sqrt(A), k = 1.0 / q;
  const double a1 = 1.0 / (1.0 + g * (g + k));
  c.a1 = float(a1); c.a2 = float(g * a1); c.a3 = float(g * g * a1);
  c.m0 = 1.f; c.m1 = float(k * (A - 1.0)); c.m2 = float(A * A - 1.0);
}
double foldBpm(double bpm) {
  if (!(bpm > 0.0) || !std::isfinite(bpm)) return 0.0;
  while (bpm < kMinBpm) bpm *= 2.0;
  while (bpm > kMaxBpm) bpm *= 0.5;
  return bpm;
}
}  // namespace

void BassShaker::Hilbert::tick(float x, float& i, float& q) {
  float u = x, v = x;
  for (size_t k = 0; k < 4; ++k) {
    const float y = kHilA[k] * (u + ya2[k]) - xa2[k];
    xa2[k] = xa1[k]; xa1[k] = u; ya2[k] = ya1[k]; ya1[k] = y;
    u = y;
  }
  for (size_t k = 0; k < 4; ++k) {
    const float y = kHilB[k] * (v + yb2[k]) - xb2[k];
    xb2[k] = xb1[k]; xb1[k] = v; yb2[k] = yb1[k]; yb1[k] = y;
    v = y;
  }
  i = d1;
  d1 = u;
  q = v;
}

void BassShaker::prepare(double sampleRate, int numChannels) {
  sampleRate_ = sampleRate;
  numChannels_ = std::clamp(numChannels, 1, kMaxChannels);
  const int r = std::max(1, int(std::lround(sampleRate / 48000.0)));
  ctlLen_ = 16 * r;
  decim_ = std::max(1, int(std::lround(sampleRate / 12000.0)));
  auto mk = [&](FilterType t, double hz) { return SvfCoeffs::make({t, hz, 0.0, 0.7071, true}, sampleRate); };
  detHp_ = mk(FilterType::HighPass, 25.0);
  detLp_ = mk(FilterType::LowPass, 150.0);
  srcHp_ = mk(FilterType::HighPass, 30.0);
  srcLp_ = mk(FilterType::LowPass, 90.0);
  outHp_ = mk(FilterType::HighPass, 60.0);
  outLp_ = mk(FilterType::LowPass, 250.0);
  const double gs = std::tan(std::numbers::pi * 100.0 / sampleRate);
  sideLpG_ = float(gs / (1.0 + gs));
  wPunch_ = std::tan(std::numbers::pi * kPunchHz / sampleRate);
  wBody_ = std::tan(std::numbers::pi * kBodyHz / sampleRate);
  wDip_ = std::tan(std::numbers::pi * kDipHz / sampleRate);
  const double n = double(ctlLen_);
  auto co = [&](double ms) { return float(1.0 - std::exp(-n / (ms * 0.001 * sampleRate))); };
  aF_ = co(0.5);
  aS_ = co(20.0);
  pkA_ = co(2.0);
  gSm_ = co(1.5);
  amount_.prepare(sampleRate, 30.0);
  setParams(p_);
  amount_.snap(amount_.target());
  reset();
  idle_ = amount_.target() == 0.f;
}

void BassShaker::reset() {
  for (SvfState* s : {&detHpS_, &detLpA_, &detLpB_, &srcHpS_, &srcLpA_, &srcLpB_, &outHpA_, &outHpB_, &outLpA_, &outLpB_})
    s->reset();
  hilDet_ = Hilbert{};
  hilSrc_ = Hilbert{};
  sideLpS_.fill(0.f);
  for (auto& c : st_) c = Chan{};
  blkEnv2_ = blkEnv2Sum_ = blkPeak_ = blkPow_ = 0.f;
  blkHil_ = 0;
  ctlPos_ = decimPos_ = 0;
  eF_ = eS_ = ms_ = lowMs_ = totMs_ = pk_ = 0.f;
  pDb_ = bDb_ = dipDb_ = 0.f;
  hHold_ = 0.f;
  harmMix_ = 0.f;
  builtPunch_ = builtBody_ = builtDip_ = 1e9f;
  buildGains();
  atkHigh_ = false;
  sinceOnset_ = 1 << 29;
  ioi_.fill(0.f);
  ioiCount_ = ioiPos_ = 0;
  kickBpm_ = 0.f;
  // Start the pace where it is aimed (no glide from a stale value).
  coeffBeatMs_ = -1.0;
  const double bpm = p_.paceBpm > 0.f ? foldBpm(p_.paceBpm) : tempoHint_ > 0.f ? foldBpm(tempoHint_) : 120.0;
  beatMs_ = 60000.0 / bpm * kPaceBias;
  paceCoeffs(beatMs_);
  pace_.store(float(bpm), std::memory_order_relaxed);
}

void BassShaker::setParams(const BassShakerParams& p) {
  p_ = p;
  auto fin = [](float v, float lo, float hi, float fallback) { return std::isfinite(v) ? std::clamp(v, lo, hi) : fallback; };
  p_.amount = fin(p.amount, 0.f, 1.f, 0.f);
  p_.boostDb = fin(p.boostDb, 0.f, 24.f, 0.f);
  p_.ceilingDb = fin(p.ceilingDb, -30.f, 0.f, -1.f);
  p_.paceBpm = fin(p.paceBpm, 0.f, 400.f, 0.f);
  p_.harmonics = fin(p.harmonics, 0.f, 3.f, 1.f);
  amount_.setTarget(p_.amount);
}

void BassShaker::paceCoeffs(double beatMs) {
  coeffBeatMs_ = beatMs;
  const double n = double(ctlLen_), fs = sampleRate_;
  auto co = [&](double ms) { return float(1.0 - std::exp(-n / (ms * 0.001 * fs))); };
  rF_ = co(beatMs / 8.0);   // punch window falls over ~1/32 note
  a16_ = co(beatMs / 4.0);  // sustain rises over a 1/16 note...
  r8_ = co(beatMs / 2.0);   // ...and falls over a 1/8 note
  aDom_ = co(beatMs);       // bass dominance: about a beat
  pkR_ = co(2.0 * beatMs);  // headroom peak: released over 2 beats
}

void BassShaker::updatePace(int numFrames) {
  double bpm = 120.0;
  if (p_.paceBpm > 0.f) bpm = foldBpm(p_.paceBpm);
  else if (tempoHint_ > 0.f) bpm = foldBpm(tempoHint_);
  else if (kickBpm_ > 0.f) bpm = kickBpm_;
  const double target = 60000.0 / bpm * kPaceBias;
  beatMs_ += (target - beatMs_) * (1.0 - std::exp(-double(numFrames) / (0.5 * sampleRate_)));
  if (std::fabs(beatMs_ - coeffBeatMs_) > 0.002 * beatMs_) paceCoeffs(beatMs_);
  pace_.store(float(60000.0 * kPaceBias / beatMs_), std::memory_order_relaxed);
}

// A kick onset: keep the last inter-onset intervals; their median (folded
// into 70-180 BPM) is the pace when no tracker tempo is around.
void BassShaker::noteOnset() {
  const float sec = float(double(sinceOnset_) * double(ctlLen_) / sampleRate_);
  if (sec < 0.25f) return;  // same hit (or faster than 240 BPM)
  sinceOnset_ = 0;
  if (sec > 2.f) {          // a gap: start over
    ioiCount_ = 0;
    return;
  }
  ioi_[size_t(ioiPos_)] = sec;
  ioiPos_ = (ioiPos_ + 1) % int(ioi_.size());
  ioiCount_ = std::min(ioiCount_ + 1, int(ioi_.size()));
  if (ioiCount_ < 4) return;
  std::array<float, 9> v{};
  std::copy_n(ioi_.begin(), ioiCount_, v.begin());
  std::sort(v.begin(), v.begin() + ioiCount_);
  const float med = v[size_t(ioiCount_ / 2)];
  int near = 0;
  for (int k = 0; k < ioiCount_; ++k) near += std::fabs(v[size_t(k)] - med) <= 0.12f * med;
  kickBpm_ = 2 * near >= ioiCount_ + 1 ? float(foldBpm(60.0 / double(med))) : 0.f;
}

void BassShaker::buildGains() {
  if (pDb_ != builtPunch_) { bell(punchC_, wPunch_, kPunchQ, pDb_); builtPunch_ = pDb_; }
  if (bDb_ != builtBody_) { lowShelf(bodyC_, wBody_, kBodyQ, bDb_); builtBody_ = bDb_; }
  if (dipDb_ != builtDip_) { bell(dipC_, wDip_, kDipQ, dipDb_); builtDip_ = dipDb_; }
}

void BassShaker::control(int) {
  const float S = amount_.current() * kStrengthScale;
  const float env = std::sqrt(blkEnv2_);
  const float envMs = blkHil_ > 0 ? blkEnv2Sum_ / float(blkHil_) : env * env;
  eF_ += (env - eF_) * (env > eF_ ? aF_ : rF_);
  eS_ += (env - eS_) * (env > eS_ ? aS_ : rF_);
  ms_ += (envMs - ms_) * (envMs > ms_ ? a16_ : r8_);
  lowMs_ += (0.5f * envMs - lowMs_) * aDom_;
  totMs_ += (blkPow_ / float(ctlLen_) - totMs_) * aDom_;
  pk_ += (blkPeak_ - pk_) * (blkPeak_ > pk_ ? pkA_ : pkR_);
  blkEnv2_ = blkEnv2Sum_ = blkPeak_ = blkPow_ = 0.f;
  blkHil_ = 0;

  float atk = 0.f, sus = 0.f;
  if (eF_ > 1e-6f) {
    const float dF = dbOf(eF_);
    atk = std::clamp((dF - dbOf(eS_)) / 6.f, 0.f, 1.f);
    sus = std::clamp((dbOf(std::sqrt(ms_)) - dF + 4.f) / 4.f, 0.f, 1.f);
  }
  // Pace from the kicks: an attack rising through the middle, above -50 dBFS.
  if (sinceOnset_ < (1 << 29)) ++sinceOnset_;
  if (!atkHigh_ && atk > 0.5f && eF_ > 0.003f) {
    atkHigh_ = true;
    noteOnset();
  } else if (atk < 0.2f) {
    atkHigh_ = false;
  }
  if (double(sinceOnset_) * double(ctlLen_) > 4.0 * sampleRate_) { ioiCount_ = 0; kickBpm_ = 0.f; }

  float pT = S * float(kPunchDb) * atk;
  float bT = S * float(kBodyDb - kBodySusDb * double(sus));
  // Headroom: what's left under the ceiling after the music's slow peak and
  // the Boost that follows this stage.
  const float room = p_.ceilingDb - dbOf(pk_) - p_.boostDb;
  bT = std::min(bT, std::max(0.f, room + 1.f) - S * float(kBodySusDb) * sus);
  pT = std::min(pT, std::max(0.f, room + 3.f));
  auto glide = [&](float& v, float t) {
    v += (t - v) * gSm_;
    if (std::fabs(t - v) < 1e-4f) v = t;
  };
  glide(pDb_, pT);
  glide(bDb_, bT);
  // Bass dominance: the 25-150 Hz band against the rest, over about a beat.
  const float rest = std::max(totMs_ - lowMs_, 0.f);
  const float dom = std::clamp((10.f * std::log10((lowMs_ + 1e-12f) / (rest + 1e-12f)) + 3.f) / 9.f, 0.f, 1.f);
  glide(dipDb_, -(0.3f * pDb_ + 2.f * S * dom));
  harmMix_ = kHarmMix * S * p_.harmonics;
  buildGains();
}

void BassShaker::process(float* const* ch, int numChannels, int numFrames) {
  numChannels = std::min(numChannels, numChannels_);
  if (numChannels < 1 || numFrames <= 0) return;
  if (idle_) {
    if (amount_.target() == 0.f) return;  // bit-exact
    reset();
    idle_ = false;
  } else if (amount_.target() == 0.f && amount_.settled() && pDb_ == 0.f && bDb_ == 0.f && dipDb_ == 0.f) {
    idle_ = true;  // everything is exactly flat again
    return;
  }
  updatePace(numFrames);
  const bool stereo = numChannels >= 2;
  float* L = ch[0];
  float* R = stereo ? ch[1] : ch[0];
  for (int i = 0; i < numFrames; ++i) {
    const float a = amount_.next();
    float l = L[i], r = R[i];
    float peak = 0.f;
    for (int c = 0; c < numChannels; ++c) peak = std::max(peak, std::fabs(ch[c][i]));
    blkPeak_ = std::max(blkPeak_, peak);
    const float m = stereo ? 0.5f * (l + r) : l;
    if (stereo) {
      // Mono lows: take the side's lows out (one-pole at 100 Hz).
      const float sd = 0.5f * (l - r);
      const float v = (sd - sideLpS_[0]) * sideLpG_;
      const float lp = v + sideLpS_[0];
      sideLpS_[0] = lp + v;
      const float mix = std::min(1.f, 2.f * a);
      if (mix > 0.f) {
        const float s2 = sd - mix * lp;
        l = m + s2;
        r = m - s2;
      }
    }
    blkPow_ += m * m;
    const float d = detLpB_.tick(detLp_, detLpA_.tick(detLp_, detHpS_.tick(detHp_, m)));
    const float hs = srcLpB_.tick(srcLp_, srcLpA_.tick(srcLp_, srcHpS_.tick(srcHp_, m)));
    if (++decimPos_ >= decim_) {
      decimPos_ = 0;
      float di, dq, hi, hq;
      hilDet_.tick(d, di, dq);
      const float e2 = di * di + dq * dq;
      blkEnv2_ = std::max(blkEnv2_, e2);
      blkEnv2Sum_ += e2;
      ++blkHil_;
      // 2nd + 3rd harmonic of the 30-90 Hz band: |z| (cos 2phi + cos 3phi / 2).
      hilSrc_.tick(hs, hi, hq);
      const float r2 = hi * hi + hq * hq;
      hHold_ = r2 > 1e-14f ? (hi * hi - hq * hq) / std::sqrt(r2) + 0.5f * (hi * hi * hi - 3.f * hi * hq * hq) / r2 : 0.f;
    }
    const float h = harmMix_ * outLpB_.tick(outLp_, outLpA_.tick(outLp_, outHpB_.tick(outHp_, outHpA_.tick(outHp_, hHold_))));
    for (int c = 0; c < numChannels; ++c) {
      Chan& s = st_[size_t(c)];
      const float x = c == 0 ? l : c == 1 ? r : ch[c][i];
      float y = s.dip.tick(dipC_, s.body.tick(bodyC_, s.punch.tick(punchC_, x)));
      if (c < 2) y += h;
      ch[c][i] = y;
    }
    if (++ctlPos_ >= ctlLen_) {
      ctlPos_ = 0;
      control(numChannels);
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
