#include "punch/engine.hpp"

#include <algorithm>
#include <cmath>

#include "punch/dsp_util.hpp"

namespace punch {

namespace {

void atomicMax(std::atomic<float>& a, float v) {
  float cur = a.load(std::memory_order_relaxed);
  while (v > cur && !a.compare_exchange_weak(cur, v, std::memory_order_relaxed)) {
  }
}

float blockPeak(const float* x, int n) {
  float p = 0.f;
  for (int i = 0; i < n; ++i) p = std::max(p, std::fabs(x[i]));
  return p;
}

}  // namespace

Engine::Engine() {
  for (auto& a : inPeak_) a.store(0.f);
  for (auto& a : outPeak_) a.store(0.f);
}

void Engine::prepare(double sampleRate, int numChannels, int maxFrames) {
  sampleRate_ = sampleRate;
  numChannels_ = std::clamp(numChannels, 1, kMaxChannels);
  maxFrames_ = std::max(maxFrames, 16);

  correction_.prepare(sampleRate, numChannels_);
  eq_.prepare(sampleRate, numChannels_);
  bass_.prepare(sampleRate, numChannels_);
  stereo_.prepare(sampleRate);
  crossfeed_.prepare(sampleRate);
  outGain_.prepare(sampleRate, 15.0);
  outGain_.snap(1.f);
  limiter_.prepare(sampleRate, numChannels_);

  scratch_.assign(size_t(numChannels_), std::vector<float>(size_t(maxFrames_), 0.f));
  scratchPtrs_.resize(size_t(numChannels_));
  for (int c = 0; c < numChannels_; ++c) scratchPtrs_[size_t(c)] = scratch_[size_t(c)].data();

  // Re-derive coefficients for the new rate and land on the current params
  // without gliding (there is no audio to glide over yet).
  publish();
  mailbox_.read(live_);
  applySnapshot(live_);
  correction_.snapToTargets();
  correction_.reset();
  eq_.snapToTargets();
  eq_.reset();
  outGain_.snap(outGain_.target());
}

void Engine::publish() {
  EngineParams snap = pending_;
  // All headroom is applied once, at the correction stage's preamp; the
  // user stage runs at unity preamp.
  effectivePreampDb_ = double(snap.correction.preampDb) + double(snap.eq.preampDb);
  // Auto headroom: never let the combined EQ push a full-scale signal over
  // 0 dBFS, but don't double-count headroom the user (or an AutoEq profile,
  // which ships its own preamp) already provided.
  if (snap.autoPreamp)
    effectivePreampDb_ = std::min(effectivePreampDb_, -eqPeakBoostDb({&snap.correction, &snap.eq}, sampleRate_));
  snap.correction.preampDb = float(effectivePreampDb_);
  snap.eq.preampDb = 0.f;
  mailbox_.write(snap);
}

void Engine::applySnapshot(const EngineParams& p) {
  if (p.bypass) {
    // Bypass == glide everything to neutral. Keeps latency constant (the
    // limiter stays in circuit at 0 dBFS as a safety net) and is click-free
    // because every stage already smooths toward its targets.
    EqParams flat = p.eq;
    for (auto& b : flat.bands) b.enabled = false;
    flat.preampDb = 0.f;
    correction_.setParams(flat);
    eq_.setParams(flat);
    bass_.setParams({});
    stereo_.setParams({});
    crossfeed_.setParams({});
    outGain_.setTarget(1.f);
    LimiterParams lp = p.limiter;
    lp.ceilingDb = 0.f;
    lp.enabled = true;
    limiter_.setParams(lp);
    return;
  }
  correction_.setParams(p.correction);
  eq_.setParams(p.eq);
  bass_.setParams(p.bass);
  stereo_.setParams(p.stereo);
  crossfeed_.setParams(p.crossfeed);
  outGain_.setTarget(dbToGain(std::clamp(p.outputGainDb, -60.f, 24.f)));
  limiter_.setParams(p.limiter);
}

void Engine::processPlanar(float* const* ch, int numChannels, int numFrames) {
  ScopedFlushDenormals ftz;
  if (mailbox_.read(live_)) applySnapshot(live_);
  numChannels = std::min(numChannels, numChannels_);

  for (int c = 0; c < std::min(numChannels, 2); ++c) atomicMax(inPeak_[c], blockPeak(ch[c], numFrames));

  correction_.process(ch, numChannels, numFrames);
  eq_.process(ch, numChannels, numFrames);
  bass_.process(ch, numChannels, numFrames);
  stereo_.process(ch, numChannels, numFrames);
  crossfeed_.process(ch, numChannels, numFrames);
  if (!(outGain_.settled() && outGain_.current() == 1.f)) {
    for (int i = 0; i < numFrames; ++i) {
      const float g = outGain_.next();
      for (int c = 0; c < numChannels; ++c) ch[c][i] *= g;
    }
  }
  limiter_.process(ch, numChannels, numFrames);

  // NaN/Inf can arrive from a misbehaving client app or a driver glitch and
  // would otherwise latch inside the IIR state forever. Detect, emit silence
  // for this block, and start clean.
  bool finite = true;
  for (int c = 0; c < numChannels; ++c)
    for (int i = 0; i < numFrames; ++i) finite &= std::isfinite(ch[c][i]);
  if (!finite) {
    for (int c = 0; c < numChannels; ++c) std::fill(ch[c], ch[c] + numFrames, 0.f);
    correction_.reset();
    eq_.reset();
    bass_.reset();
    stereo_.reset();
    crossfeed_.reset();
    limiter_.reset();
  }

  for (int c = 0; c < std::min(numChannels, 2); ++c) atomicMax(outPeak_[c], blockPeak(ch[c], numFrames));

  // Analyzer feed: drop samples if the UI is not keeping up.
  if (analyzer_.availableToWrite() >= size_t(numFrames)) {
    float mono[512];
    for (int start = 0; start < numFrames; start += 512) {
      const int n = std::min(512, numFrames - start);
      for (int i = 0; i < n; ++i) {
        float s = 0.f;
        for (int c = 0; c < numChannels; ++c) s += ch[c][start + i];
        mono[i] = s / float(numChannels);
      }
      analyzer_.push(mono, size_t(n));
    }
  }
}

void Engine::processInterleaved(const float* in, float* out, int numChannels, int numFrames) {
  const int nc = std::min(numChannels, numChannels_);
  for (int start = 0; start < numFrames; start += maxFrames_) {
    const int n = std::min(maxFrames_, numFrames - start);
    const float* src = in + size_t(start) * size_t(numChannels);
    float* dst = out + size_t(start) * size_t(numChannels);
    for (int c = 0; c < nc; ++c) {
      float* s = scratchPtrs_[size_t(c)];
      for (int i = 0; i < n; ++i) s[i] = src[size_t(i) * size_t(numChannels) + size_t(c)];
    }
    processPlanar(scratchPtrs_.data(), nc, n);
    for (int i = 0; i < n; ++i) {
      for (int c = 0; c < nc; ++c) dst[size_t(i) * size_t(numChannels) + size_t(c)] = scratchPtrs_[size_t(c)][i];
      // Channels beyond what we process pass through untouched.
      for (int c = nc; c < numChannels; ++c)
        dst[size_t(i) * size_t(numChannels) + size_t(c)] = src[size_t(i) * size_t(numChannels) + size_t(c)];
    }
  }
}

Meters Engine::takeMeters() {
  Meters m;
  for (int c = 0; c < 2; ++c) {
    m.inPeak[c] = inPeak_[c].exchange(0.f, std::memory_order_relaxed);
    m.outPeak[c] = outPeak_[c].exchange(0.f, std::memory_order_relaxed);
  }
  m.gainReductionDb = limiter_.gainReductionDb();
  return m;
}

}  // namespace punch
