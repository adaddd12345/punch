#include "BassShakeRT.h"

#include <math.h>
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

enum { kChunkFrames = 256, kMaxChannels = 16 };

struct BSRenderContext {
  PunchEngine* engine;
  _Atomic uint32_t tapIndex;
  _Atomic float fadeTarget;  // 0 or 1
  _Atomic float fadeStep;    // gain change per frame
  float fadeGain;            // IO-thread owned
  _Atomic bool fadedOut;

  _Atomic uint64_t callbacks;
  _Atomic uint64_t frames;
  _Atomic uint64_t silentCallbacks;
  _Atomic uint64_t layoutErrors;
  _Atomic uint32_t inChannels;
  _Atomic uint32_t outChannels;
};

BSRenderContext* BSRenderContextCreate(PunchEngine* engine) {
  BSRenderContext* c = calloc(1, sizeof(BSRenderContext));
  if (!c) return NULL;
  c->engine = engine;
  atomic_store(&c->tapIndex, UINT32_MAX);
  atomic_store(&c->fadeTarget, 0.f);
  atomic_store(&c->fadeStep, 1.f);
  atomic_store(&c->fadedOut, true);
  c->fadeGain = 0.f;
  return c;
}

void BSRenderContextDestroy(BSRenderContext* ctx) { free(ctx); }

void BSRenderContextSetTapBufferIndex(BSRenderContext* ctx, uint32_t index) {
  atomic_store_explicit(&ctx->tapIndex, index, memory_order_relaxed);
}

static float stepFor(double sampleRate, double ms) {
  const double frames = fmax(1.0, sampleRate * ms * 0.001);
  return (float)(1.0 / frames);
}

void BSRenderContextFadeIn(BSRenderContext* ctx, double sampleRate, double ms) {
  atomic_store(&ctx->fadeStep, stepFor(sampleRate, ms));
  atomic_store(&ctx->fadedOut, false);
  atomic_store(&ctx->fadeTarget, 1.f);
}

void BSRenderContextFadeOut(BSRenderContext* ctx, double sampleRate, double ms) {
  atomic_store(&ctx->fadeStep, stepFor(sampleRate, ms));
  atomic_store(&ctx->fadeTarget, 0.f);
}

bool BSRenderContextIsFadedOut(const BSRenderContext* ctx) {
  return atomic_load((_Atomic bool*)&ctx->fadedOut);
}

BSRenderStats BSRenderContextStats(const BSRenderContext* ctx) {
  BSRenderContext* c = (BSRenderContext*)ctx;
  BSRenderStats s;
  s.callbacks = atomic_load_explicit(&c->callbacks, memory_order_relaxed);
  s.framesProcessed = atomic_load_explicit(&c->frames, memory_order_relaxed);
  s.silentCallbacks = atomic_load_explicit(&c->silentCallbacks, memory_order_relaxed);
  s.layoutErrors = atomic_load_explicit(&c->layoutErrors, memory_order_relaxed);
  s.lastInputChannels = atomic_load_explicit(&c->inChannels, memory_order_relaxed);
  s.lastOutputChannels = atomic_load_explicit(&c->outChannels, memory_order_relaxed);
  return s;
}

static void zeroOutput(AudioBufferList* out) {
  for (UInt32 b = 0; b < out->mNumberBuffers; ++b)
    if (out->mBuffers[b].mData) memset(out->mBuffers[b].mData, 0, out->mBuffers[b].mDataByteSize);
}

static void bump(_Atomic uint64_t* v) { atomic_fetch_add_explicit(v, 1, memory_order_relaxed); }

OSStatus BSIOProc(AudioObjectID device, const AudioTimeStamp* now, const AudioBufferList* input,
                  const AudioTimeStamp* inputTime, AudioBufferList* output, const AudioTimeStamp* outputTime,
                  void* clientData) {
  (void)device; (void)now; (void)inputTime; (void)outputTime;
  BSRenderContext* ctx = (BSRenderContext*)clientData;
  if (!ctx || !output || output->mNumberBuffers == 0) return noErr;
  bump(&ctx->callbacks);

  // ---- locate the tap buffer
  const AudioBuffer* tap = NULL;
  if (input && input->mNumberBuffers > 0) {
    uint32_t idx = atomic_load_explicit(&ctx->tapIndex, memory_order_relaxed);
    if (idx == UINT32_MAX || idx >= input->mNumberBuffers) idx = input->mNumberBuffers - 1;
    tap = &input->mBuffers[idx];
  }
  if (!tap || !tap->mData || tap->mNumberChannels == 0 || tap->mNumberChannels > kMaxChannels) {
    bump(&ctx->layoutErrors);
    zeroOutput(output);
    return noErr;
  }
  const UInt32 inCh = tap->mNumberChannels;
  const UInt32 inFrames = tap->mDataByteSize / (UInt32)(inCh * sizeof(float));

  UInt32 outChTotal = 0;
  UInt32 outFrames = UINT32_MAX;
  for (UInt32 b = 0; b < output->mNumberBuffers; ++b) {
    const AudioBuffer* ob = &output->mBuffers[b];
    if (!ob->mData || ob->mNumberChannels == 0) continue;
    outChTotal += ob->mNumberChannels;
    const UInt32 f = ob->mDataByteSize / (UInt32)(ob->mNumberChannels * sizeof(float));
    if (f < outFrames) outFrames = f;
  }
  atomic_store_explicit(&ctx->inChannels, inCh, memory_order_relaxed);
  atomic_store_explicit(&ctx->outChannels, outChTotal, memory_order_relaxed);
  zeroOutput(output);
  if (outChTotal == 0 || outFrames == UINT32_MAX) return noErr;
  const UInt32 frames = inFrames < outFrames ? inFrames : outFrames;

  // ---- watchdog signal: a live tap is essentially never bit-exact zero
  // for a whole cycle while something is playing.
  const float* src = (const float*)tap->mData;
  bool silent = true;
  for (UInt32 i = 0, n = frames * inCh; i < n; ++i) {
    if (src[i] != 0.f) { silent = false; break; }
  }
  if (silent) bump(&ctx->silentCallbacks);

  // ---- process in chunks and scatter into the device's buffer layout
  const float target = atomic_load_explicit(&ctx->fadeTarget, memory_order_relaxed);
  const float step = atomic_load_explicit(&ctx->fadeStep, memory_order_relaxed);
  float tmp[kChunkFrames * kMaxChannels];

  for (UInt32 start = 0; start < frames; start += kChunkFrames) {
    const UInt32 n = (frames - start) < kChunkFrames ? (frames - start) : kChunkFrames;
    punch_process_interleaved(ctx->engine, src + (size_t)start * inCh, tmp, (int)inCh, (int)n);

    // Fade ramp (start-up, rebuild, shutdown).
    float g = ctx->fadeGain;
    if (g != target || g != 1.f) {
      for (UInt32 i = 0; i < n; ++i) {
        if (g < target) g = fminf(target, g + step);
        else if (g > target) g = fmaxf(target, g - step);
        for (UInt32 c = 0; c < inCh; ++c) tmp[i * inCh + c] *= g;
      }
      ctx->fadeGain = g;
    }

    // Output channel k takes input channel k; a mono tap feeds every
    // channel; extra output channels stay silent.
    UInt32 k = 0;
    for (UInt32 b = 0; b < output->mNumberBuffers; ++b) {
      AudioBuffer* ob = &output->mBuffers[b];
      if (!ob->mData || ob->mNumberChannels == 0) continue;
      float* dst = (float*)ob->mData;
      const UInt32 och = ob->mNumberChannels;
      for (UInt32 c = 0; c < och; ++c, ++k) {
        int sc = k < inCh ? (int)k : (inCh == 1 ? 0 : -1);
        if (sc < 0) continue;
        for (UInt32 i = 0; i < n; ++i) dst[(size_t)(start + i) * och + c] = tmp[i * inCh + (UInt32)sc];
      }
    }
  }
  if (target == 0.f && ctx->fadeGain == 0.f) atomic_store_explicit(&ctx->fadedOut, true, memory_order_relaxed);
  atomic_fetch_add_explicit(&ctx->frames, frames, memory_order_relaxed);
  return noErr;
}

// ---------------------------------------------------------------- crash guard

static _Atomic AudioObjectID gGuardAggregate = kAudioObjectUnknown;
static _Atomic AudioObjectID gGuardTap = kAudioObjectUnknown;

void BSCrashGuardSet(AudioObjectID aggregate, AudioObjectID tap) {
  atomic_store(&gGuardAggregate, aggregate);
  atomic_store(&gGuardTap, tap);
}

void BSCrashGuardClear(void) { BSCrashGuardSet(kAudioObjectUnknown, kAudioObjectUnknown); }

static void guardTeardown(void) {
  const AudioObjectID agg = atomic_exchange(&gGuardAggregate, kAudioObjectUnknown);
  const AudioObjectID tap = atomic_exchange(&gGuardTap, kAudioObjectUnknown);
  if (agg != kAudioObjectUnknown) AudioHardwareDestroyAggregateDevice(agg);
  if (tap != kAudioObjectUnknown) {
    if (__builtin_available(macOS 14.2, *)) AudioHardwareDestroyProcessTap(tap);
  }
}

static void guardHandler(int sig) {
  guardTeardown();
  // Re-raise with the default action so crash reports / exit codes stay normal.
  signal(sig, SIG_DFL);
  raise(sig);
}

void BSCrashGuardInstall(void) {
  const int sigs[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP, SIGTERM, SIGINT, SIGHUP, SIGQUIT};
  for (size_t i = 0; i < sizeof sigs / sizeof sigs[0]; ++i) {
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = guardHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESETHAND;
    sigaction(sigs[i], &sa, NULL);
  }
  atexit(guardTeardown);
}
