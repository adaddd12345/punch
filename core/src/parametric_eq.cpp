#include "punch/parametric_eq.hpp"

#include <algorithm>
#include <cmath>

namespace punch {

namespace {

bool hasGain(FilterType t) {
  return t == FilterType::Bell || t == FilterType::LowShelf || t == FilterType::HighShelf;
}

double logLerp(double a, double b, double t) { return std::exp(std::log(a) + (std::log(b) - std::log(a)) * t); }

}  // namespace

double eqResponseDb(const EqParams& p, double sampleRate, double hz) {
  double db = 0.0;
  for (int i = 0; i < p.numBands; ++i) {
    const FilterSpec& b = p.bands[size_t(i)];
    if (!b.enabled) continue;
    db += SvfCoeffs::make(b, sampleRate).magnitudeDb(hz, sampleRate);
  }
  return db;
}

double eqPeakBoostDb(std::initializer_list<const EqParams*> stages, double sampleRate, double minHz) {
  constexpr int kPoints = 1024;
  const double lo = std::max(20.0, minHz), hi = std::min(20000.0, 0.49 * sampleRate);
  // Build coefficient sets once, then scan.
  std::vector<SvfCoeffs> cs;
  for (const EqParams* p : stages)
    for (int i = 0; i < p->numBands; ++i)
      if (p->bands[size_t(i)].enabled) cs.push_back(SvfCoeffs::make(p->bands[size_t(i)], sampleRate));
  double peak = 0.0;
  for (int k = 0; k < kPoints; ++k) {
    const double hz = lo * std::pow(hi / lo, double(k) / (kPoints - 1));
    double db = 0.0;
    for (const auto& c : cs) db += c.magnitudeDb(hz, sampleRate);
    peak = std::max(peak, db);
  }
  return peak;
}

double eqPeakBoostDb(const EqParams& p, double sampleRate) { return eqPeakBoostDb({&p}, sampleRate); }

void eqResponseCurve(const EqParams& p, double sampleRate, double lo, double hi, std::vector<double>& outDb) {
  const size_t n = outDb.size();
  if (n == 0) return;
  std::vector<SvfCoeffs> cs;
  for (int i = 0; i < p.numBands; ++i)
    if (p.bands[size_t(i)].enabled) cs.push_back(SvfCoeffs::make(p.bands[size_t(i)], sampleRate));
  for (size_t k = 0; k < n; ++k) {
    const double hz = n == 1 ? lo : lo * std::pow(hi / lo, double(k) / double(n - 1));
    double db = p.preampDb;
    for (const auto& c : cs) db += c.magnitudeDb(hz, sampleRate);
    outDb[k] = db;
  }
}

void ParametricEq::prepare(double sampleRate, int numChannels) {
  sampleRate_ = sampleRate;
  numChannels_ = std::clamp(numChannels, 1, kMaxChannels);
  // ~20 ms glide time constant, evaluated once per control block.
  glideCoeff_ = float(1.0 - std::exp(-double(kControlBlock) / (0.020 * sampleRate)));
  preamp_.prepare(sampleRate, 10.0);
  preamp_.snap(dbToGain(0.f));
  for (auto& b : bands_) {
    if (b.active) b.coeffs = SvfCoeffs::make(b.current, sampleRate_);
  }
  reset();
}

void ParametricEq::reset() {
  for (auto& b : bands_)
    for (auto& s : b.state) s.reset();
}

void ParametricEq::setParams(const EqParams& p) {
  preamp_.setTarget(dbToGain(p.preampDb));
  const int n = std::clamp(p.numBands, 0, kMaxEqBands);
  for (int i = 0; i < kMaxEqBands; ++i) {
    Band& b = bands_[size_t(i)];
    FilterSpec t = i < n ? p.bands[size_t(i)] : FilterSpec{};
    if (i >= n) t.enabled = false;

    if (!t.enabled) {
      if (!b.active) continue;
      if (hasGain(b.current.type)) {
        // Glide gain to 0 dB, then deactivate in advanceGlide().
        b.target = b.current;
        b.target.gainDb = 0.0;
        b.target.enabled = false;
        b.gliding = true;
      } else {
        b.active = false;
        b.gliding = false;
        for (auto& s : b.state) s.reset();
      }
      continue;
    }

    if (!b.active) {
      // Fade in gain bands from 0 dB; cut filters start at target.
      b.current = t;
      if (hasGain(t.type)) b.current.gainDb = 0.0;
      for (auto& s : b.state) s.reset();
      b.active = true;
    } else if (b.current.type != t.type) {
      b.current.type = t.type;  // topology is shared; only mix gains change
    }
    b.target = t;
    b.gliding = !(b.current == b.target);
    b.coeffs = SvfCoeffs::make(b.current, sampleRate_);
  }
  numBands_ = 0;
  for (int i = 0; i < kMaxEqBands; ++i)
    if (bands_[size_t(i)].active) numBands_ = i + 1;
}

void ParametricEq::snapToTargets() {
  preamp_.snap(preamp_.target());
  for (auto& b : bands_) {
    if (!b.active) continue;
    b.current = b.target;
    b.gliding = false;
    if (!b.current.enabled) {
      b.active = false;
      continue;
    }
    b.coeffs = SvfCoeffs::make(b.current, sampleRate_);
  }
}

void ParametricEq::advanceGlide(Band& b) {
  const double c = glideCoeff_;
  FilterSpec& cur = b.current;
  const FilterSpec& tgt = b.target;
  cur.freqHz = logLerp(cur.freqHz, tgt.freqHz, c);
  cur.q = logLerp(cur.q, tgt.q, c);
  cur.gainDb += (tgt.gainDb - cur.gainDb) * c;
  const bool done = std::fabs(cur.gainDb - tgt.gainDb) < 0.01 &&
                    std::fabs(std::log(cur.freqHz / tgt.freqHz)) < 1e-4 &&
                    std::fabs(std::log(cur.q / tgt.q)) < 1e-4;
  if (done) {
    cur = tgt;
    b.gliding = false;
    if (!tgt.enabled) {
      b.active = false;
      return;
    }
  }
  FilterSpec live = cur;
  live.enabled = true;
  b.coeffs = SvfCoeffs::make(live, sampleRate_);
}

void ParametricEq::process(float* const* ch, int numChannels, int numFrames) {
  numChannels = std::min(numChannels, numChannels_);
  for (int start = 0; start < numFrames; start += kControlBlock) {
    const int n = std::min(kControlBlock, numFrames - start);

    if (!preamp_.settled() || preamp_.current() != 1.f) {
      for (int i = 0; i < n; ++i) {
        const float g = preamp_.next();
        for (int c = 0; c < numChannels; ++c) ch[c][start + i] *= g;
      }
    }

    for (int bi = 0; bi < numBands_; ++bi) {
      Band& b = bands_[size_t(bi)];
      if (!b.active) continue;
      if (b.gliding) {
        advanceGlide(b);
        if (!b.active) continue;
      }
      const SvfCoeffs k = b.coeffs;
      for (int c = 0; c < numChannels; ++c) {
        SvfState st = b.state[size_t(c)];
        float* x = ch[c] + start;
        for (int i = 0; i < n; ++i) x[i] = st.tick(k, x[i]);
        b.state[size_t(c)] = st;
      }
    }
  }
}

}  // namespace punch
