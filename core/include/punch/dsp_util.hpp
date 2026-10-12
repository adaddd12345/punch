#pragma once

#include <cmath>
#include <cstdint>

#if defined(__aarch64__) || defined(_M_ARM64)
#define PUNCH_ARM64 1
#elif defined(__x86_64__) || defined(_M_X64) || defined(__SSE__)
#include <xmmintrin.h>
#define PUNCH_X86 1
#endif

namespace punch {

inline float dbToGain(float db) { return std::pow(10.f, db * 0.05f); }
inline float gainToDb(float g) { return 20.f * std::log10(g > 1e-9f ? g : 1e-9f); }

// Denormals in IIR feedback paths (decaying filter state after silence) can
// cost 10-100x per operation. Set flush-to-zero for the scope of an IO cycle.
// Core Audio IOProc threads do not guarantee FTZ is set.
class ScopedFlushDenormals {
 public:
  ScopedFlushDenormals() {
#if PUNCH_ARM64
    asm volatile("mrs %0, fpcr" : "=r"(saved_));
    const std::uint64_t fz = std::uint64_t(1) << 24;
    asm volatile("msr fpcr, %0" ::"r"(saved_ | fz));
#elif PUNCH_X86
    saved_ = _mm_getcsr();
    _mm_setcsr(unsigned(saved_) | 0x8040);  // FTZ | DAZ
#endif
  }
  ~ScopedFlushDenormals() {
#if PUNCH_ARM64
    asm volatile("msr fpcr, %0" ::"r"(saved_));
#elif PUNCH_X86
    _mm_setcsr(unsigned(saved_));
#endif
  }
  ScopedFlushDenormals(const ScopedFlushDenormals&) = delete;
  ScopedFlushDenormals& operator=(const ScopedFlushDenormals&) = delete;

 private:
  std::uint64_t saved_ = 0;
};

// One-pole exponential smoother for gains/mix amounts. timeMs is the time to
// reach ~63% of a step.
class Smoothed {
 public:
  void prepare(double sampleRate, double timeMs) {
    coeff_ = float(1.0 - std::exp(-1.0 / (0.001 * timeMs * sampleRate)));
  }
  void setTarget(float t) { target_ = t; }
  void snap(float v) { current_ = target_ = v; }
  float target() const { return target_; }
  float current() const { return current_; }
  bool settled() const { return current_ == target_; }
  inline float next() {
    const float d = target_ - current_;
    // Land exactly on the target so "settled" fast paths engage and
    // neutral settings become bit-transparent.
    // (Also land when the step has fallen below float resolution, which
    // happens near targets >= ~0.5 well before |d| < 1e-5.)
    const float n = current_ + coeff_ * d;
    current_ = (std::fabs(d) < 1e-5f || n == current_) ? target_ : n;
    return current_;
  }

 private:
  float coeff_ = 1.f;
  float current_ = 0.f;
  float target_ = 0.f;
};

}  // namespace punch
