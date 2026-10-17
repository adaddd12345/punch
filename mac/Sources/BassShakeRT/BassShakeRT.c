#include "BassShakeRT.h"

#include <math.h>
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>

enum { kChunkFrames = 256, kMaxChannels = 16 };

struct BSRenderContext {
  PunchEngine* engine;
  uint32_t outputMapCount;  // immutable while IO runs
  int32_t outputMap[128];
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
  _Atomic uint64_t deadOutputCallbacks;
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

bool BSRenderContextSetOutputMap(BSRenderContext* ctx, const int32_t* channels, uint32_t count) {
  if (count > 128) return false;
  for (uint32_t i = 0; i < count; ++i)
    if (channels[i] < -1 || channels[i] >= kMaxChannels) return false;
  if (count) memcpy(ctx->outputMap, channels, count * sizeof(int32_t));
  ctx->outputMapCount = count;
  return true;
}

OSStatus BSConfigureTapOnlyInputs(AudioObjectID device, AudioDeviceIOProcID proc, uint32_t tapStreams) {
  AudioObjectPropertyAddress address = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain };
  UInt32 bytes = 0;
  OSStatus status = AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &bytes);
  if (status) return status;
  UInt32 count = bytes / sizeof(AudioStreamID);
  if (count < tapStreams) return kAudioHardwareIllegalOperationError;
  if (!count) return noErr;
  if (count > 1024) return kAudioHardwareIllegalOperationError;
  UInt32 size = (UInt32)offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + count * sizeof(UInt32);
  AudioHardwareIOProcStreamUsage* usage = calloc(1, size);
  if (!usage) return kAudioHardwareUnspecifiedError;
  usage->mIOProc = (void*)proc;
  usage->mNumberStreams = count;
  for (UInt32 i = count - tapStreams; i < count; ++i) usage->mStreamIsOn[i] = 1;
  address.mSelector = kAudioDevicePropertyIOProcStreamUsage;
  status = AudioObjectSetPropertyData(device, &address, 0, NULL, size, usage);
  free(usage);
  return status;
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
  s.deadOutputCallbacks = atomic_load_explicit(&c->deadOutputCallbacks, memory_order_relaxed);
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
    // More channels than we handle (big pro interfaces): count it as dead
    // output so the watchdog steps aside instead of leaving the Mac silent.
    if (tap && tap->mNumberChannels > kMaxChannels) bump(&ctx->deadOutputCallbacks);
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
  if (ctx->outputMapCount && ctx->outputMapCount != outChTotal) {
    bump(&ctx->layoutErrors);
    bump(&ctx->deadOutputCallbacks);
    return noErr;
  }
  const UInt32 frames = inFrames < outFrames ? inFrames : outFrames;

  // ---- watchdog signal: a live tap is essentially never bit-exact zero
  // for a whole cycle while something is playing.
  const float* src = (const float*)tap->mData;
  float inPeak = 0.f;
  for (UInt32 i = 0, n = frames * inCh; i < n; ++i) {
    const float a = fabsf(src[i]);
    if (a > inPeak) inPeak = a;
  }
  const bool silent = inPeak == 0.f;
  if (silent) bump(&ctx->silentCallbacks);

  // ---- process in chunks and scatter into the device's buffer layout
  const float target = atomic_load_explicit(&ctx->fadeTarget, memory_order_relaxed);
  const float step = atomic_load_explicit(&ctx->fadeStep, memory_order_relaxed);
  float tmp[kChunkFrames * kMaxChannels];
  float outPeak = 0.f;

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
    for (UInt32 i = 0, m = n * inCh; i < m; ++i) {
      const float a = fabsf(tmp[i]);
      if (!(a <= 1e30f)) { outPeak = INFINITY; break; }  // NaN / Inf
      if (a > outPeak) outPeak = a;
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
        int sc = ctx->outputMapCount ? ctx->outputMap[k] : (k < inCh ? (int)k : (inCh == 1 ? 0 : -1));
        if (inCh == 1 && sc >= 0) sc = 0;
        if (sc < 0 || sc >= (int)inCh) continue;
        for (UInt32 i = 0; i < n; ++i) dst[(size_t)(start + i) * och + c] = tmp[i * inCh + (UInt32)sc];
      }
    }
  }
  if (target == 0.f && ctx->fadeGain == 0.f) atomic_store_explicit(&ctx->fadedOut, true, memory_order_relaxed);
  // Watchdog signal: sound came in but nothing usable went out (and we're
  // not deliberately fading). The Swift side steps aside if this persists.
  // Exactly zero only: the engine's quietest legitimate setting (sleep fade,
  // -60 dB floor) still leaves non-zero samples; the Swift side additionally
  // ignores states that are silent by design (all DJ kills, sleep fade).
  // Only clearly audible input counts (dither and reverb tails can sit
  // below what survives processing).
  if (inPeak > 1e-4f && target == 1.f && (outPeak == 0.f || isinf(outPeak))) bump(&ctx->deadOutputCallbacks);
  atomic_fetch_add_explicit(&ctx->frames, frames, memory_order_relaxed);
  return noErr;
}

// ---------------------------------------------------------------- crash guard

// Declared in AudioHardwareTapping.h, which is Objective-C only (its create
// call takes a CATapDescription). Destroy is plain C; weak-import it so this
// file stays C and loads on any macOS.
extern OSStatus AudioHardwareDestroyProcessTap(AudioObjectID inTapID) __attribute__((weak_import));

static _Atomic AudioObjectID gGuardAggregate = kAudioObjectUnknown;
static _Atomic AudioObjectID gGuardTap = kAudioObjectUnknown;

void BSCrashGuardSet(AudioObjectID aggregate, AudioObjectID tap) {
  atomic_store(&gGuardAggregate, aggregate);
  atomic_store(&gGuardTap, tap);
}

void BSCrashGuardClear(void) { BSCrashGuardSet(kAudioObjectUnknown, kAudioObjectUnknown); }

void BSCrashGuardRelease(AudioObjectID aggregate, AudioObjectID tap, bool* ownsAggregate, bool* ownsTap) {
  AudioObjectID a = aggregate, t = tap;
  *ownsAggregate = aggregate != kAudioObjectUnknown && atomic_compare_exchange_strong(&gGuardAggregate, &a, kAudioObjectUnknown);
  *ownsTap = tap != kAudioObjectUnknown && atomic_compare_exchange_strong(&gGuardTap, &t, kAudioObjectUnknown);
}

bool BSCrashGuardFailOpen(void) {
  const AudioObjectID agg = atomic_exchange(&gGuardAggregate, kAudioObjectUnknown);
  const AudioObjectID tap = atomic_exchange(&gGuardTap, kAudioObjectUnknown);
  if (agg != kAudioObjectUnknown) AudioHardwareDestroyAggregateDevice(agg);
  if (tap != kAudioObjectUnknown && AudioHardwareDestroyProcessTap != NULL) AudioHardwareDestroyProcessTap(tap);
  return agg != kAudioObjectUnknown || tap != kAudioObjectUnknown;
}

bool BSCrashGuardHoldsTap(void) { return atomic_load(&gGuardTap) != kAudioObjectUnknown; }

static _Atomic AudioObjectID gGuardExtraTaps[BSCrashGuardMaxExtraTaps];  // zero == kAudioObjectUnknown

bool BSCrashGuardAddTap(AudioObjectID tap) {
  if (tap == kAudioObjectUnknown) return false;
  for (int i = 0; i < BSCrashGuardMaxExtraTaps; ++i) {
    AudioObjectID expected = kAudioObjectUnknown;
    if (atomic_compare_exchange_strong(&gGuardExtraTaps[i], &expected, tap)) return true;
  }
  return false;
}

void BSCrashGuardRemoveTap(AudioObjectID tap) {
  if (tap == kAudioObjectUnknown) return;
  for (int i = 0; i < BSCrashGuardMaxExtraTaps; ++i) {
    AudioObjectID expected = tap;
    if (atomic_compare_exchange_strong(&gGuardExtraTaps[i], &expected, kAudioObjectUnknown)) return;
  }
}

static void guardTeardown(void) {
  const AudioObjectID agg = atomic_exchange(&gGuardAggregate, kAudioObjectUnknown);
  const AudioObjectID tap = atomic_exchange(&gGuardTap, kAudioObjectUnknown);
  if (agg != kAudioObjectUnknown) AudioHardwareDestroyAggregateDevice(agg);
  if (tap != kAudioObjectUnknown && AudioHardwareDestroyProcessTap != NULL) AudioHardwareDestroyProcessTap(tap);
  for (int i = 0; i < BSCrashGuardMaxExtraTaps; ++i) {
    const AudioObjectID t = atomic_exchange(&gGuardExtraTaps[i], kAudioObjectUnknown);
    if (t != kAudioObjectUnknown && AudioHardwareDestroyProcessTap != NULL) AudioHardwareDestroyProcessTap(t);
  }
}

static void guardHandler(int sig) {
  // Polite signals (quit, Ctrl-C, logout): the process is healthy, tear down.
  // Crash signals: don't call into Core Audio from a crashed thread (it may
  // be the IO thread, and HAL calls there can deadlock, leaving the process
  // hung with the tap muting the Mac). Just die: coreaudiod releases a dead
  // client's private taps and aggregates, and the next launch sweeps leftovers.
  // Polite signals: exit immediately too. HAL calls aren't async-signal-safe
  // (they can deadlock inside a handler); coreaudiod frees a dead client's
  // taps and aggregates, and the next launch sweeps any leftovers. (A normal
  // Quit goes through applicationWillTerminate, not here.)
  if (sig == SIGTERM || sig == SIGINT || sig == SIGHUP || sig == SIGQUIT) _exit(0);
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

// ---------------------------------------------------------------- level meter

struct BSMeterContext {
  _Atomic float peaks[BSMeterMaxSlots];
  int32_t layout[BSMeterMaxBuffers];  // written before IO starts, then read-only
  uint32_t layoutCount;
  _Atomic uint64_t callbacks;
  _Atomic uint64_t layoutErrors;
};

BSMeterContext* BSMeterContextCreate(void) {
  BSMeterContext* c = calloc(1, sizeof(BSMeterContext));
  if (!c) return NULL;
  for (int i = 0; i < BSMeterMaxSlots; ++i) atomic_init(&c->peaks[i], 0.f);
  for (int i = 0; i < BSMeterMaxBuffers; ++i) c->layout[i] = -1;
  return c;
}

void BSMeterContextDestroy(BSMeterContext* ctx) { free(ctx); }

void BSMeterContextSetLayout(BSMeterContext* ctx, const int32_t* slots, uint32_t count) {
  if (count > BSMeterMaxBuffers) count = BSMeterMaxBuffers;
  for (uint32_t i = 0; i < count; ++i) {
    const int32_t s = slots[i];
    ctx->layout[i] = (s >= 0 && s < BSMeterMaxSlots) ? s : -1;
  }
  ctx->layoutCount = count;
  atomic_thread_fence(memory_order_release);
}

float BSMeterContextTakePeak(BSMeterContext* ctx, uint32_t slot) {
  if (slot >= BSMeterMaxSlots) return 0.f;
  return atomic_exchange_explicit(&ctx->peaks[slot], 0.f, memory_order_relaxed);
}

uint64_t BSMeterContextCallbacks(const BSMeterContext* ctx) {
  return atomic_load_explicit(&((BSMeterContext*)ctx)->callbacks, memory_order_relaxed);
}

uint64_t BSMeterContextLayoutErrors(const BSMeterContext* ctx) {
  return atomic_load_explicit(&((BSMeterContext*)ctx)->layoutErrors, memory_order_relaxed);
}

OSStatus BSMeterIOProc(AudioObjectID device, const AudioTimeStamp* now, const AudioBufferList* input,
                       const AudioTimeStamp* inputTime, AudioBufferList* output, const AudioTimeStamp* outputTime,
                       void* clientData) {
  (void)device; (void)now; (void)inputTime; (void)outputTime;
  // Never contribute sound: the aggregate's clock device is the real output.
  if (output) zeroOutput(output);
  BSMeterContext* ctx = (BSMeterContext*)clientData;
  if (!ctx) return noErr;
  bump(&ctx->callbacks);
  atomic_thread_fence(memory_order_acquire);
  const uint32_t count = ctx->layoutCount;
  if (!input || count == 0) return noErr;

  uint32_t n = input->mNumberBuffers;
  uint32_t first = 0;   // first mapped layout entry
  uint32_t base = 0;    // first input buffer that is a tap buffer
  if (n >= count) {
    base = n - count;
  } else {
    // Fewer buffers than expected: align to the end, skip the missing ones.
    bump(&ctx->layoutErrors);
    first = count - n;
  }
  for (uint32_t i = first; i < count; ++i) {
    const int32_t slot = ctx->layout[i];
    if (slot < 0) continue;
    const AudioBuffer* b = &input->mBuffers[base + (i - first)];
    if (!b->mData || b->mDataByteSize < sizeof(float)) continue;
    // Layout agnostic: the peak over every float in the buffer.
    const float* src = (const float*)b->mData;
    const uint32_t samples = b->mDataByteSize / (uint32_t)sizeof(float);
    float peak = 0.f;
    for (uint32_t k = 0; k < samples; ++k) {
      const float a = fabsf(src[k]);
      if (a > peak) peak = a;  // NaN compares false and is ignored
    }
    if (peak <= 0.f) continue;
    _Atomic float* dst = &ctx->peaks[slot];
    float old = atomic_load_explicit(dst, memory_order_relaxed);
    while (peak > old &&
           !atomic_compare_exchange_weak_explicit(dst, &old, peak, memory_order_relaxed, memory_order_relaxed)) {
    }
  }
  return noErr;
}
