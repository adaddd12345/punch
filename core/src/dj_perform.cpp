// DJ performance pads: Tape Stop, Chipmunk / Screw, Roll, Lofi, Pump.
// Real-time safe after prepare(): every buffer is sized for the rate there.
#include <algorithm>
#include <cmath>
#include <numbers>

#include "punch/fx.hpp"

namespace punch {

namespace {
float coeffFor(double seconds, double rate) { return float(1.0 - std::exp(-1.0 / (seconds * rate))); }
bool off(const Smoothed& s) { return s.settled() && s.current() == 0.f; }
// Uniform -1..1 from a xorshift32 state (deterministic hiss).
inline float noise(uint32_t& s) {
  s ^= s << 13;
  s ^= s >> 17;
  s ^= s << 5;
  return float(int32_t(s)) * (1.f / 2147483648.f);
}
}  // namespace

void DjPerform::Ring::alloc(int minSize) {
  int n = 1;
  while (n < minSize) n <<= 1;
  d.assign(size_t(n), 0.f);
  mask = n - 1;
}

float DjPerform::Ring::read(double pos) const {
  const double fl = std::floor(pos);
  const int i = int(fl);
  const float f = float(pos - fl);
  const float xm1 = d[size_t((i - 1) & mask)], x0 = d[size_t(i & mask)];
  const float x1 = d[size_t((i + 1) & mask)], x2 = d[size_t((i + 2) & mask)];
  const float c1 = 0.5f * (x1 - xm1);
  const float c2 = xm1 - 2.5f * x0 + 2.f * x1 - 0.5f * x2;
  const float c3 = 0.5f * (x2 - xm1) + 1.5f * (x0 - x1);
  return ((c3 * f + c2) * f + c1) * f + x0;
}

void DjPerform::prepare(double sampleRate, int numChannels) {
  sampleRate_ = sampleRate;
  numChannels_ = std::clamp(numChannels, 1, kMaxChannels);
  const double fs = sampleRate;
  // Roll's longest slice is an eighth note at 60 BPM (0.5 s).
  for (auto& r : hist_) r.alloc(int(0.55 * fs) + 16);
  for (auto& l : loop_) l.assign(size_t(0.5 * fs) + 16, 0.f);
  grain_ = 0.040 * fs;
  for (auto& r : pitchBuf_) r.alloc(int(grain_) + 16);
  // Linear slow-down over 1 s: the read head falls 0.5 s behind.
  tapeStopSamples_ = 1.0 * fs;
  for (auto& r : tapeBuf_) r.alloc(int(0.6 * fs) + 16);
  // Lofi: 4.5 ms base delay, +-1.5 ms wow at 0.5 Hz, +-0.1 ms flutter at 6 Hz.
  lofiBase_ = float(0.0045 * fs);
  wowDepth_ = float(0.0015 * fs);
  flutDepth_ = float(0.0001 * fs);
  wowInc_ = 0.5 / fs;
  flutInc_ = 6.0 / fs;
  for (auto& r : lofiBuf_) r.alloc(int(0.008 * fs) + 16);
  // 4th-order Butterworth low-pass at 3.5 kHz.
  lofiLp1_ = SvfCoeffs::make({FilterType::LowPass, 3500.0, 0.0, 0.5412, true}, fs);
  lofiLp2_ = SvfCoeffs::make({FilterType::LowPass, 3500.0, 0.0, 1.3066, true}, fs);
  // Pump: kick detector and duck shape.
  kickLp_ = SvfCoeffs::make({FilterType::LowPass, 150.0, 0.0, 0.7071, true}, fs);
  kickAtt_ = coeffFor(0.001, fs);
  kickRel_ = coeffFor(0.025, fs);
  kickSlowC_ = coeffFor(0.4, fs);
  refractory_ = int(0.12 * fs);
  duckAttack_ = std::max(1, int(0.004 * fs));

  rollMix_.prepare(fs, 3.0);
  pitchMix_.prepare(fs, 10.0);
  semis_.prepare(fs, 25.0);
  tapeMix_.prepare(fs, 8.0);  // ~30 ms to land back on live
  lofiMix_.prepare(fs, 25.0);
  pumpMix_.prepare(fs, 15.0);
  setParams(p_);
  for (auto* s : {&pitchMix_, &semis_, &tapeMix_, &lofiMix_, &pumpMix_}) s->snap(s->target());
  // Roll is never snapped on: after a rebuild the history is empty, so a
  // held Roll waits for a whole slice of audio and then fades in.
  rollMix_.snap(0.f);
  rollMix_.setTarget(p_.roll ? 1.f : 0.f);
  reset();
}

void DjPerform::reset() {
  for (auto* rs : {&hist_, &pitchBuf_, &tapeBuf_, &lofiBuf_})
    for (auto& r : *rs) std::fill(r.d.begin(), r.d.end(), 0.f);
  for (auto& l : loop_) std::fill(l.begin(), l.end(), 0.f);
  histW_ = pitchW_ = tapeW_ = lofiW_ = 0;
  histFilled_ = 0;
  rollLatched_ = false;
  rollSilent_.store(false, std::memory_order_relaxed);
  rollLen_ = rollMinLen_ = rollFade_ = rollBeat_ = 1;
  rollPos_ = rollElapsed_ = rollNextHalve_ = 0;
  pitchPhase_ = 0.0;
  pitchRunning_ = tapeRunning_ = lofiRunning_ = pumpRunning_ = false;
  tapeHeld_ = false;
  tapeT_ = tapeLag_ = 0.0;
  wowPh_ = flutPh_ = 0.0;
  for (auto& s : lofiS1_) s.reset();
  for (auto& s : lofiS2_) s.reset();
  for (int c = 0; c < kMaxChannels; ++c) noise_[size_t(c)] = 0x9E3779B9u * uint32_t(c + 1);
  kickS_.reset();
  kickFast_ = kickSlow_ = 0.f;
  kickAbove_ = false;
  sinceOnset_ = sinceSync_ = sinceTrigger_ = 1 << 30;
  lastIoi_ = 0;
  beatPhase_ = 0.0;
  locked_ = false;
  duckStart_ = duck_ = 0.f;
}

void DjPerform::setParams(const DjParams& p) {
  p_ = p;
  rollMix_.setTarget(p.roll ? 1.f : 0.f);
  // Chipmunk wins when both pitch pads are on.
  pitchMix_.setTarget(p.chipmunk || p.screw ? 1.f : 0.f);
  if (p.chipmunk) semis_.setTarget(7.f);
  else if (p.screw) semis_.setTarget(-5.f);  // else: keep the pitch while fading out
  tapeMix_.setTarget(p.tapeStop ? 1.f : 0.f);
  lofiMix_.setTarget(p.lofi ? 1.f : 0.f);
  pumpMix_.setTarget(p.pump ? 1.f : 0.f);
}

bool DjPerform::idle() const {
  return off(rollMix_) && off(pitchMix_) && off(tapeMix_) && off(lofiMix_) && off(pumpMix_) && !rollLatched_ &&
         !tapeRunning_;
}

void DjPerform::recordHistory(float* const* ch, int numChannels, int numFrames) {
  for (int c = 0; c < numChannels; ++c) {
    Ring& r = hist_[size_t(c)];
    for (int i = 0; i < numFrames; ++i) r.at(histW_ + i) = ch[c][i];
  }
  histW_ = (histW_ + numFrames) & hist_[0].mask;
  histFilled_ = std::min(histFilled_ + numFrames, 1 << 30);
}

int DjPerform::rollSliceLen() const {
  const double bpm = bpm_ > 0.0 ? std::clamp(bpm_, 60.0, 200.0) : 120.0;
  return std::min(std::max(8, int(std::lround(sampleRate_ * 60.0 / bpm))) / 2, int(loop_[0].size()));
}

void DjPerform::captureRoll() {
  const double bpm = bpm_ > 0.0 ? std::clamp(bpm_, 60.0, 200.0) : 120.0;
  rollBeat_ = std::max(8, int(std::lround(sampleRate_ * 60.0 / bpm)));
  rollLen_ = rollSliceLen();  // an eighth note
  rollMinLen_ = rollBeat_ / 8;                               // down to a 32nd
  rollFade_ = std::max(1, std::min(rollLen_ / 4, int(0.002 * sampleRate_)));
  rollPos_ = 0;
  rollElapsed_ = 0;
  rollNextHalve_ = rollBeat_;
  float peak = 0.f;
  for (int c = 0; c < numChannels_; ++c) {
    Ring& h = hist_[size_t(c)];
    float* l = loop_[size_t(c)].data();
    for (int k = 0; k < rollLen_; ++k) {
      l[k] = h.at(histW_ - rollLen_ + k);
      peak = std::max(peak, std::fabs(l[k]));
    }
  }
  rollSilent_.store(peak < 1e-6f, std::memory_order_relaxed);
}

void DjPerform::processPre(float* const* ch, int numChannels, int numFrames) {
  numChannels = std::min(numChannels, numChannels_);
  if (numFrames <= 0) return;
  if (!p_.roll && rollLatched_) {
    rollLatched_ = false;
    rollSilent_.store(false, std::memory_order_relaxed);
  }
  // Roll starts using the history up to the end of the previous block, but
  // only once it holds a whole slice (after a reset it's silence): until
  // then the audio passes through.
  if (p_.roll && !rollLatched_) {
    if (histFilled_ >= rollSliceLen()) {
      captureRoll();
      rollLatched_ = true;
      rollMix_.setTarget(1.f);
    } else {
      rollMix_.snap(0.f);
    }
  }
  if (idle()) {
    recordHistory(ch, numChannels, numFrames);
    return;
  }

  // Delay-line effects start from the recent past as this stage played it:
  // through Roll's loop while Roll is in (no jump back to the live input).
  const bool rollIn = rollLatched_ || !off(rollMix_);
  const float rmNow = rollMix_.current();
  const auto past = [&](int c, int k) {
    const float x = hist_[size_t(c)].at(histW_ - k);
    if (!rollIn || rmNow == 0.f) return x;
    const int pos = ((rollPos_ - k) % rollLen_ + rollLen_) % rollLen_;
    const float edge = float(std::min(pos, rollLen_ - 1 - pos)) + 0.5f;
    const float w = std::min(1.f, edge / float(rollFade_));
    return x + rmNow * (w * loop_[size_t(c)][size_t(pos)] - x);
  };
  const auto prime = [&](std::array<Ring, kMaxChannels>& buf, int& w, int count) {
    w = 0;
    for (int c = 0; c < numChannels; ++c)
      for (int k = 1; k <= count; ++k) buf[size_t(c)].at(-k) = past(c, k);
  };
  if (!pitchRunning_ && !off(pitchMix_)) {
    prime(pitchBuf_, pitchW_, pitchBuf_[0].mask);
    pitchPhase_ = 0.0;
    semis_.snap(semis_.target());
    pitchRunning_ = true;
  }
  if (p_.tapeStop && !tapeHeld_) {
    // Re-pressed while the last stop is still fading out: start a new one
    // if that one already reached the halt.
    if (!tapeRunning_ || tapeMix_.current() < 0.05f || tapeT_ >= tapeStopSamples_) {
      prime(tapeBuf_, tapeW_, 8);
      tapeT_ = tapeLag_ = 0.0;
    }
    tapeRunning_ = true;
  }
  tapeHeld_ = p_.tapeStop;
  if (!lofiRunning_ && !off(lofiMix_)) {
    prime(lofiBuf_, lofiW_, lofiBuf_[0].mask);
    for (auto& s : lofiS1_) s.reset();
    for (auto& s : lofiS2_) s.reset();
    lofiRunning_ = true;
  }
  recordHistory(ch, numChannels, numFrames);

  const bool rollOn = rollIn;
  const double tapeMaxLag = double(tapeBuf_[0].mask) - 8.0;
  constexpr float kHiss = 0.0017f;  // about -60 dBFS RMS before the low-pass
  constexpr float kTwoPi = 2.f * std::numbers::pi_v<float>;
  float v[kMaxChannels];

  for (int i = 0; i < numFrames; ++i) {
    for (int c = 0; c < numChannels; ++c) v[c] = ch[c][i];

    // Roll: loop the captured slice with short fades at its ends.
    if (rollOn) {
      const float rm = rollMix_.next();
      const float edge = float(std::min(rollPos_, rollLen_ - 1 - rollPos_)) + 0.5f;
      const float w = std::min(1.f, edge / float(rollFade_));
      for (int c = 0; c < numChannels; ++c) v[c] += rm * (w * loop_[size_t(c)][size_t(rollPos_)] - v[c]);
      if (rollElapsed_ < (1 << 30)) ++rollElapsed_;
      if (++rollPos_ >= rollLen_) {
        rollPos_ = 0;
        if (rollElapsed_ >= rollNextHalve_ && rollLen_ / 2 >= rollMinLen_) {
          rollLen_ /= 2;
          rollNextHalve_ += rollBeat_;
          rollFade_ = std::max(1, std::min(rollFade_, rollLen_ / 4));
        }
      }
    }

    // Pitch: two read heads sweep a 40 ms delay at (1 - ratio) per sample,
    // half a grain apart, Hann-crossfaded (weights sum to 1).
    if (pitchRunning_) {
      const float pm = pitchMix_.next();
      const float st = semis_.next();
      if (st != ratioFor_) {
        ratio_ = std::exp2(double(st) / 12.0);
        ratioFor_ = st;
      }
      pitchPhase_ += (1.0 - ratio_) / grain_;
      pitchPhase_ -= std::floor(pitchPhase_);
      const double phA = pitchPhase_;
      const double phB = phA < 0.5 ? phA + 0.5 : phA - 0.5;
      const float s = std::sin(std::numbers::pi_v<float> * float(phA));
      const float wA = s * s, wB = 1.f - wA;
      const double dA = 2.0 + phA * grain_, dB = 2.0 + phB * grain_;
      for (int c = 0; c < numChannels; ++c) {
        Ring& r = pitchBuf_[size_t(c)];
        r.at(pitchW_) = v[c];
        const float y = wA * r.read(double(pitchW_) - dA) + wB * r.read(double(pitchW_) - dB);
        v[c] += pm * (y - v[c]);
      }
      pitchW_ = (pitchW_ + 1) & pitchBuf_[0].mask;
    }

    // Tape stop: the read head slows linearly to a halt; the level fades
    // out over the last tenth of the speed so it ends in silence.
    if (tapeRunning_) {
      const float tm = tapeMix_.next();
      const double u = tapeT_ / tapeStopSamples_;
      const double speed = u < 1.0 ? 1.0 - u : 0.0;
      const float g = speed >= 0.1 ? 1.f : float(speed * speed * 100.0);
      tapeLag_ = std::min(tapeLag_ + (1.0 - speed), tapeMaxLag);
      tapeT_ += 1.0;
      for (int c = 0; c < numChannels; ++c) {
        Ring& r = tapeBuf_[size_t(c)];
        r.at(tapeW_) = v[c];
        const float y = g > 0.f ? g * r.read(double(tapeW_) - 2.0 - tapeLag_) : 0.f;
        v[c] += tm * (y - v[c]);
      }
      tapeW_ = (tapeW_ + 1) & tapeBuf_[0].mask;
    }

    // Lofi: wow & flutter, soft tape saturation, hiss, 3.5 kHz low-pass,
    // narrowed stereo.
    if (lofiRunning_) {
      const float lm = lofiMix_.next();
      wowPh_ += wowInc_;
      if (wowPh_ >= 1.0) wowPh_ -= 1.0;
      flutPh_ += flutInc_;
      if (flutPh_ >= 1.0) flutPh_ -= 1.0;
      const double d = double(lofiBase_ + wowDepth_ * std::sin(kTwoPi * float(wowPh_)) +
                              flutDepth_ * std::sin(kTwoPi * float(flutPh_)));
      float w[kMaxChannels];
      for (int c = 0; c < numChannels; ++c) {
        Ring& r = lofiBuf_[size_t(c)];
        r.at(lofiW_) = v[c];
        float y = r.read(double(lofiW_) - d);
        y = std::tanh(1.2f * y) * (1.f / 1.2f);
        y += kHiss * noise(noise_[size_t(c)]);
        w[c] = lofiS2_[size_t(c)].tick(lofiLp2_, lofiS1_[size_t(c)].tick(lofiLp1_, y));
      }
      if (numChannels >= 2) {
        const float m = 0.5f * (w[0] + w[1]), sd = 0.3f * (w[0] - w[1]);  // side x 0.6
        w[0] = m + sd;
        w[1] = m - sd;
      }
      for (int c = 0; c < numChannels; ++c) v[c] += lm * (w[c] - v[c]);
      lofiW_ = (lofiW_ + 1) & lofiBuf_[0].mask;
    }

    for (int c = 0; c < numChannels; ++c) ch[c][i] = v[c];
  }

  if (pitchRunning_ && off(pitchMix_)) pitchRunning_ = false;
  if (tapeRunning_ && !p_.tapeStop && off(tapeMix_)) tapeRunning_ = false;
  if (lofiRunning_ && off(lofiMix_)) lofiRunning_ = false;
}

void DjPerform::processPost(float* const* ch, int numChannels, int numFrames) {
  numChannels = std::min(numChannels, numChannels_);
  if (!pumpRunning_) {
    if (off(pumpMix_)) return;
    // Fresh start: free-running until the first kick lands.
    pumpRunning_ = true;
    kickS_.reset();
    kickFast_ = kickSlow_ = 0.f;
    kickAbove_ = false;
    sinceOnset_ = sinceSync_ = sinceTrigger_ = 1 << 30;
    lastIoi_ = 0;
    beatPhase_ = 0.0;
    locked_ = false;
    duck_ = duckStart_ = 0.f;
  }
  constexpr float kDepth = 1.f - 0.3548f;  // -9 dB
  constexpr int kBig = 1 << 30;
  const double fs = sampleRate_;
  const double beat = bpm_ > 0.0 ? fs * 60.0 / std::clamp(bpm_, 60.0, 200.0) : 0.0;
  const int nc2 = std::min(numChannels, 2);
  for (int i = 0; i < numFrames; ++i) {
    const float pm = pumpMix_.next();
    // Kick detector: 150 Hz low-pass envelope against its slow average.
    float mono = 0.f;
    for (int c = 0; c < nc2; ++c) mono += ch[c][i];
    mono /= float(std::max(1, nc2));
    const float a = std::fabs(kickS_.tick(kickLp_, mono));
    kickFast_ += (a - kickFast_) * (a > kickFast_ ? kickAtt_ : kickRel_);
    kickSlow_ += (kickFast_ - kickSlow_) * kickSlowC_;
    const bool above = kickFast_ > 1.8f * kickSlow_ + 1e-4f;
    const bool onset = above && !kickAbove_ && sinceOnset_ > refractory_;
    if (above) kickAbove_ = true;
    else if (kickFast_ < 1.2f * kickSlow_) kickAbove_ = false;
    if (onset) {
      lastIoi_ = sinceOnset_ < kBig ? sinceOnset_ : 0;
      sinceOnset_ = 0;
    }

    bool trigger = false;
    int release;
    if (beat > 0.0) {
      // Beat clock at the detected tempo; kicks pull it into phase.
      beatPhase_ += 1.0 / beat;
      if (beatPhase_ >= 1.0) {
        beatPhase_ -= 1.0;
        trigger = true;
      }
      if (onset) {
        const double err = beatPhase_ > 0.5 ? beatPhase_ - 1.0 : beatPhase_;
        if (!locked_) {
          if (double(sinceTrigger_) > 0.5 * beat) trigger = true;
          beatPhase_ = 0.0;
          locked_ = true;
          sinceSync_ = 0;
        } else if (std::fabs(err) < 0.25) {
          beatPhase_ -= 0.3 * err;
          if (beatPhase_ < 0.0) beatPhase_ += 1.0;
          sinceSync_ = 0;
        }
      }
      if (double(sinceSync_) > 4.0 * beat) locked_ = false;
      release = int(0.6 * beat);
    } else {
      // No tempo yet: duck on each detected kick.
      trigger = onset;
      release = lastIoi_ > 0 ? std::clamp(int(0.6 * lastIoi_), int(0.12 * fs), int(0.6 * fs)) : int(0.3 * fs);
    }
    if (trigger) {
      duckStart_ = duck_;
      sinceTrigger_ = 0;
      duckRelease_ = std::max(1, release);
    }
    if (sinceTrigger_ < duckAttack_) {
      duck_ = duckStart_ + (1.f - duckStart_) * float(sinceTrigger_) / float(duckAttack_);
    } else {
      const float r = float(sinceTrigger_ - duckAttack_) / float(duckRelease_);
      duck_ = r < 1.f ? 1.f - r * r * (3.f - 2.f * r) : 0.f;
    }
    if (sinceOnset_ < kBig) ++sinceOnset_;
    if (sinceSync_ < kBig) ++sinceSync_;
    if (sinceTrigger_ < kBig) ++sinceTrigger_;

    const float g = 1.f - pm * kDepth * duck_;
    for (int c = 0; c < numChannels; ++c) ch[c][i] *= g;
  }
  if (off(pumpMix_)) pumpRunning_ = false;
}

}  // namespace punch
