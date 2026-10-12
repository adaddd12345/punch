#include "punch/analysis.hpp"

#include <algorithm>
#include <cmath>
#include <cstdlib>

namespace punch {

namespace {

// Vertex offset (-0.5..0.5) of the parabola through (-1,a) (0,b) (1,c).
double parabolicOffset(double a, double b, double c) {
  const double den = a - 2.0 * b + c;
  if (std::fabs(den) < 1e-12) return 0.0;
  return std::clamp(0.5 * (a - c) / den, -0.5, 0.5);
}

}  // namespace

// ===========================================================================
// TempoTracker
// ===========================================================================

void TempoTracker::prepare(double sampleRate) {
  fs_ = sampleRate;
  hop_ = std::max(1, int(std::lround(fs_ / kFrameRate)));

  // Six bands: kick, low-mid, mids, upper-mids, presence, hats. Energy flux
  // per band is the poor man's spectral flux (no FFT needed).
  const FilterSpec specs[kBands] = {
      {FilterType::LowPass, 120.0, 0.0, 0.7071, true},
      {FilterType::BandPass, 300.0, 0.0, 1.0, true},
      {FilterType::BandPass, 700.0, 0.0, 1.0, true},
      {FilterType::BandPass, 1500.0, 0.0, 1.0, true},
      {FilterType::BandPass, 3000.0, 0.0, 1.0, true},
      {FilterType::HighPass, 6000.0, 0.0, 0.7071, true},
  };
  for (int b = 0; b < kBands; ++b) bandCoeffs_[size_t(b)] = SvfCoeffs::make(specs[b], fs_);

  const int frames = int(kWindowSec * kFrameRate);
  onset_.assign(size_t(frames), 0.f);
  work_.assign(size_t(frames), 0.f);
  // Lag range for the tempo search plus room for the comb multiples.
  minLag_ = int(std::floor(60.0 * kFrameRate / kMaxBpm));
  maxLag_ = int(std::ceil(60.0 * kFrameRate / kMinBpm));
  score_.assign(size_t(maxLag_ + 1), 0.0);
  reset();
}

void TempoTracker::reset() {
  for (auto& s : bandState_) s.reset();
  bandEnergy_.fill(0.0);
  bandPrevLog_.fill(0.f);
  std::fill(onset_.begin(), onset_.end(), 0.f);
  hopCount_ = 0;
  onsetWrite_ = 0;
  onsetCount_ = 0;
  framesSinceUpdate_ = 0;
  bpm_ = 0.0;
  confidence_ = 0.0;
}

void TempoTracker::process(const float* mono, std::size_t n) {
  for (std::size_t i = 0; i < n; ++i) {
    const float x = mono[i];
    for (int b = 0; b < kBands; ++b) {
      const float y = bandState_[size_t(b)].tick(bandCoeffs_[size_t(b)], x);
      bandEnergy_[size_t(b)] += double(y) * double(y);
    }
    if (++hopCount_ < hop_) continue;
    hopCount_ = 0;

    // Log-compressed band energies; onset = summed positive change.
    float flux = 0.f;
    for (int b = 0; b < kBands; ++b) {
      const float lg = float(std::log1p(1e4 * bandEnergy_[size_t(b)] / hop_));
      flux += std::max(0.f, lg - bandPrevLog_[size_t(b)]);
      bandPrevLog_[size_t(b)] = lg;
      bandEnergy_[size_t(b)] = 0.0;
    }
    pushOnsetFrame(flux);
  }
}

void TempoTracker::pushOnsetFrame(float value) {
  const int size = int(onset_.size());
  onset_[size_t(onsetWrite_)] = value;
  onsetWrite_ = (onsetWrite_ + 1) % size;
  onsetCount_ = std::min(onsetCount_ + 1, size);
  if (++framesSinceUpdate_ >= int(kUpdateSec * kFrameRate) &&
      onsetCount_ >= int(kMinSecToReport * kFrameRate)) {
    framesSinceUpdate_ = 0;
    estimate();
  }
}

double TempoTracker::acfAt(const float* x, int n, int lag) const {
  double acc = 0.0;
  for (int i = 0; i + lag < n; ++i) acc += double(x[i]) * double(x[i + lag]);
  return acc;
}

void TempoTracker::estimate() {
  // Linearise the newest onsetCount_ frames (oldest first) and remove the mean.
  const int size = int(onset_.size());
  const int n = onsetCount_;
  const int start = (onsetWrite_ - n + size) % size;
  double mean = 0.0;
  for (int i = 0; i < n; ++i) mean += onset_[size_t((start + i) % size)];
  mean /= n;
  for (int i = 0; i < n; ++i) work_[size_t(i)] = float(onset_[size_t((start + i) % size)] - mean);
  const float* x = work_.data();

  const double r0 = acfAt(x, n, 0);
  if (r0 < 1e-9 || mean < 1e-4) {  // silence or a flat envelope
    confidence_ = 0.0;
    return;
  }
  auto r = [&](int lag) { return acfAt(x, n, lag) / r0; };  // biased, so r(lag) <= 1

  // Tempo prior: log-Gaussian around 120 BPM (after Ellis 2007), kPriorOctaves
  // wide. With the biased ACF it resolves the half/double-tempo ambiguity of
  // patterns that repeat every two beats (kick + snare on 2 and 4).
  int best = -1;
  double bestScore = -1e9;
  const int lastLag = std::min(maxLag_, n / 2);
  for (int lag = minLag_; lag <= lastLag; ++lag) {
    const double bpm = 60.0 * kFrameRate / lag;
    const double oct = std::log2(bpm / 120.0);
    const double s = r(lag) * std::exp(-0.5 * oct * oct / (kPriorOctaves * kPriorOctaves));
    score_[size_t(lag)] = s;
    if (s > bestScore) bestScore = s, best = lag;
  }
  if (best <= minLag_ || best >= lastLag) {  // peak on the edge: no clear tempo
    confidence_ = 0.0;
    return;
  }

  const double peak = r(best);
  double period = best + parabolicOffset(r(best - 1), peak, r(best + 1));

  // Comb refinement: the peaks at 2T, 3T, 4T pin the period to a fraction of
  // a frame (least-squares fit through the origin).
  double num = period, den = 1.0;
  for (int k = 2; k <= 4; ++k) {
    const int c = int(std::lround(k * period));
    if (c + 3 >= n / 2) break;
    int m = c;
    for (int l = c - 2; l <= c + 2; ++l)
      if (r(l) > r(m)) m = l;
    const double pk = m + parabolicOffset(r(m - 1), r(m), r(m + 1));
    num += k * pk;
    den += double(k * k);
  }
  period = num / den;

  bpm_ = 60.0 * kFrameRate / period;
  // r(T) is ~0.1 for noise and 0.5-0.9 for a steady groove.
  confidence_ = std::clamp((peak - 0.15) / 0.35, 0.0, 1.0);
}

// ===========================================================================
// BassPitchTracker
// ===========================================================================

void BassPitchTracker::prepare(double sampleRate) {
  fs_ = sampleRate;
  decim_ = std::max(1, int(std::lround(fs_ / 3000.0)));
  fsDec_ = fs_ / decim_;
  // 4th-order Butterworth at 300 Hz = two SVF low-passes (Q 0.541, 1.307).
  // ~56 dB down at the 1.5 kHz decimated Nyquist, so aliasing is negligible.
  lp1_ = SvfCoeffs::make({FilterType::LowPass, 300.0, 0.0, 0.5412, true}, fs_);
  lp2_ = SvfCoeffs::make({FilterType::LowPass, 300.0, 0.0, 1.3066, true}, fs_);
  minTau_ = std::max(2, int(std::floor(fsDec_ / kMaxHz)));
  maxTau_ = std::min(kBuffer - kWindow - 2, int(std::ceil(fsDec_ / kMinHz)));
  reset();
}

void BassPitchTracker::reset() {
  s1_.reset();
  s2_.reset();
  ring_.fill(0.f);
  decimPhase_ = 0;
  ringWrite_ = 0;
  filled_ = 0;
  sinceHop_ = 0;
  hz_ = 0.0;
  midi_ = -1;
  cents_ = 0.0;
  confidence_ = 0.0;
  note_[0] = '\0';
}

void BassPitchTracker::process(const float* mono, std::size_t n) {
  for (std::size_t i = 0; i < n; ++i) {
    const float y = s2_.tick(lp2_, s1_.tick(lp1_, mono[i]));
    if (++decimPhase_ < decim_) continue;
    decimPhase_ = 0;
    ring_[size_t(ringWrite_)] = y;
    ringWrite_ = (ringWrite_ + 1) & (kBuffer - 1);
    filled_ = std::min(filled_ + 1, kBuffer);
    if (++sinceHop_ >= kHop && filled_ == kBuffer) {
      sinceHop_ = 0;
      analyse();
    }
  }
}

void BassPitchTracker::analyse() {
  // Oldest sample first.
  for (int i = 0; i < kBuffer; ++i) frame_[size_t(i)] = ring_[size_t((ringWrite_ + i) & (kBuffer - 1))];
  const float* x = frame_.data();

  auto unvoiced = [&](double conf) {
    hz_ = 0.0;
    midi_ = -1;
    cents_ = 0.0;
    confidence_ = conf;
    note_[0] = '\0';
  };

  double energy = 0.0;
  for (int j = 0; j < kWindow; ++j) energy += double(x[j]) * double(x[j]);
  if (energy / kWindow < 1e-8) return unvoiced(0.0);  // below -80 dBFS: silence

  // YIN steps 2-3: difference function and its cumulative-mean normalisation.
  const int lastTau = maxTau_ + 1;
  float* d = diff_.data();
  d[0] = 1.f;
  double running = 0.0;
  for (int tau = 1; tau <= lastTau; ++tau) {
    double acc = 0.0;
    for (int j = 0; j < kWindow; ++j) {
      const double e = double(x[j]) - double(x[j + tau]);
      acc += e * e;
    }
    raw_[size_t(tau)] = float(acc);
    running += acc;
    d[tau] = running > 0.0 ? float(acc * tau / running) : 1.f;
  }

  // Step 4: first dip under the threshold (avoids sub-octave errors), walked
  // down to its local minimum; otherwise fall back to the global minimum.
  int tau = -1;
  for (int t = minTau_; t <= maxTau_; ++t) {
    if (d[t] < kThreshold) {
      while (t + 1 <= maxTau_ && d[t + 1] < d[t]) ++t;
      tau = t;
      break;
    }
  }
  if (tau < 0) {
    tau = minTau_;
    for (int t = minTau_ + 1; t <= maxTau_; ++t)
      if (d[t] < d[tau]) tau = t;
  }
  const double conf = std::clamp(1.0 - double(d[tau]), 0.0, 1.0);
  if (conf < 0.5 || tau <= minTau_ || tau >= maxTau_) return unvoiced(conf);

  // Step 5: parabolic interpolation on the raw difference function.
  const double period = tau + parabolicOffset(raw_[size_t(tau - 1)], raw_[size_t(tau)], raw_[size_t(tau + 1)]);
  hz_ = fsDec_ / period;
  const double midiF = 69.0 + 12.0 * std::log2(hz_ / 440.0);
  midi_ = int(std::lround(midiF));
  cents_ = 100.0 * (midiF - midi_);
  confidence_ = conf;
  midiToName(midi_, note_, sizeof(note_));
}

void BassPitchTracker::midiToName(int midi, char* out, std::size_t size) {
  static const char* const names[12] = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"};
  if (size == 0) return;
  if (midi < 0 || midi > 127 || size < 5) {
    out[0] = '\0';
    return;
  }
  const char* name = names[midi % 12];
  const int octave = midi / 12 - 1;  // -1..9
  std::size_t k = 0;
  while (*name) out[k++] = *name++;
  if (octave < 0) out[k++] = '-';
  out[k++] = char('0' + std::abs(octave));
  out[k] = '\0';
}

}  // namespace punch
