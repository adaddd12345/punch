#include "BassShakeRT.h"

#include <math.h>
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stddef.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <time.h>
#include <errno.h>
#include <os/log.h>

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

  bool timingEnabled;  // immutable while IO runs
  double nanosecondsPerTick, ticksPerFrame;
  uint64_t timingLimits[BSRenderTimingBucketCount - 1];
  _Atomic uint64_t timingCallbacks, timingTotalTicks, timingMaxTicks, timingOverBudget;
  _Atomic uint64_t timingBuckets[BSRenderTimingBucketCount];
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

bool BSRenderContextEnableTiming(BSRenderContext* ctx, double sampleRate) {
  if (!ctx || !isfinite(sampleRate) || sampleRate <= 0.0) return false;
  mach_timebase_info_data_t timebase;
  if (mach_timebase_info(&timebase) != KERN_SUCCESS || !timebase.numer || !timebase.denom) return false;
  if (!atomic_is_lock_free(&ctx->timingCallbacks)) return false;
  ctx->nanosecondsPerTick = (double)timebase.numer / (double)timebase.denom;
  ctx->ticksPerFrame = 1e9 / (ctx->nanosecondsPerTick * sampleRate);
  if (!isfinite(ctx->ticksPerFrame) || ctx->ticksPerFrame <= 0.0) return false;
  for (unsigned i = 0; i < BSRenderTimingBucketCount - 1; ++i)
    ctx->timingLimits[i] = (uint64_t)ceil((double)(UINT64_C(1) << (i + 3)) * 1000.0 / ctx->nanosecondsPerTick);
  ctx->timingEnabled = true;
  return true;
}

BSRenderTiming BSRenderContextTiming(const BSRenderContext* ctx) {
  BSRenderTiming s = {0};
  s.enabled = ctx->timingEnabled;
  s.nanosecondsPerTick = ctx->nanosecondsPerTick;
  s.callbacks = atomic_load_explicit(&ctx->timingCallbacks, memory_order_relaxed);
  s.totalTicks = atomic_load_explicit(&ctx->timingTotalTicks, memory_order_relaxed);
  s.maxTicks = atomic_load_explicit(&ctx->timingMaxTicks, memory_order_relaxed);
  s.overBudgetCallbacks = atomic_load_explicit(&ctx->timingOverBudget, memory_order_relaxed);
  for (unsigned i = 0; i < BSRenderTimingBucketCount; ++i)
    s.buckets[i] = atomic_load_explicit(&ctx->timingBuckets[i], memory_order_relaxed);
  return s;
}

// These counters have one writer (this IOProc), so relaxed load/store suffices
// and avoids compare/exchange retry loops. Readers never modify them.
static void recordTiming(BSRenderContext* ctx, uint64_t begin, UInt32 frames) {
  const uint64_t elapsed = mach_absolute_time() - begin;
  const uint64_t maximum = atomic_load_explicit(&ctx->timingMaxTicks, memory_order_relaxed);
  if (elapsed > maximum) atomic_store_explicit(&ctx->timingMaxTicks, elapsed, memory_order_relaxed);
  const uint64_t total = atomic_load_explicit(&ctx->timingTotalTicks, memory_order_relaxed);
  atomic_store_explicit(&ctx->timingTotalTicks, total + elapsed, memory_order_relaxed);
  if (frames && (double)elapsed > ctx->ticksPerFrame * (double)frames) {
    const uint64_t over = atomic_load_explicit(&ctx->timingOverBudget, memory_order_relaxed);
    atomic_store_explicit(&ctx->timingOverBudget, over + 1, memory_order_relaxed);
  }
  unsigned bucket = 0;
  while (bucket < BSRenderTimingBucketCount - 1 && elapsed > ctx->timingLimits[bucket]) ++bucket;
  const uint64_t hits = atomic_load_explicit(&ctx->timingBuckets[bucket], memory_order_relaxed);
  atomic_store_explicit(&ctx->timingBuckets[bucket], hits + 1, memory_order_relaxed);
  const uint64_t count = atomic_load_explicit(&ctx->timingCallbacks, memory_order_relaxed);
  atomic_store_explicit(&ctx->timingCallbacks, count + 1, memory_order_relaxed);
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
  const uint64_t timingBegin = ctx->timingEnabled ? mach_absolute_time() : 0;
  UInt32 timingFrames = 0;
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
    goto finished;
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
  if (outChTotal == 0 || outFrames == UINT32_MAX) goto finished;
  if (ctx->outputMapCount && ctx->outputMapCount != outChTotal) {
    bump(&ctx->layoutErrors);
    bump(&ctx->deadOutputCallbacks);
    goto finished;
  }
  const UInt32 frames = inFrames < outFrames ? inFrames : outFrames;
  timingFrames = frames;

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
finished:
  if (timingBegin) recordTiming(ctx, timingBegin, timingFrames);
  return noErr;
}

// ---------------------------------------------------------------- crash guard

// Declared in AudioHardwareTapping.h, which is Objective-C only (its create
// call takes a CATapDescription). Destroy is plain C; weak-import it so this
// file stays C and loads on any macOS.
extern OSStatus AudioHardwareDestroyProcessTap(AudioObjectID inTapID) __attribute__((weak_import));

// This registry is control-thread-only. Pair publication/claim is serialized,
// while atexit can atomically take the pair without acquiring a possibly held
// mutex. No IOProc enters this code and no HAL call holds the registry mutex.
_Static_assert(sizeof(AudioObjectID) == sizeof(uint32_t), "packed HAL IDs");
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "crash guard needs lock-free ID pair");
static _Atomic uint64_t gGuardIDs;
static pthread_mutex_t gGuardMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gGuardCompleted = PTHREAD_COND_INITIALIZER;
static uint64_t gGuardOwner;
static bool gGuardRetired = true;
static uint64_t gGuardDestroyingOwner;
// When the in-flight rescue destroy began (mach_absolute_time). A destroy that
// outlives kGuardWaitNanos no longer blocks cleanup or new pipelines: a wedged
// coreaudiod must not strand audioQueue (fail open, see guardWaitForOwner).
static uint64_t gGuardDestroyStarted;
// Owner whose rescue destroy failed or never finished in time: its IOProc may
// still be called, so its callback context must be leaked, never freed.
static uint64_t gGuardUnsafeOwner;
enum { kGuardWaitMillis = 500 };
static const uint64_t kGuardWaitNanos = (uint64_t)kGuardWaitMillis * 1000000ull;

static uint64_t guardNanosSince(uint64_t start) {
  static mach_timebase_info_data_t tb;
  if (tb.denom == 0) mach_timebase_info(&tb);
  return (mach_absolute_time() - start) * tb.numer / tb.denom;
}
static bool guardDestroyStale(void) {
  return gGuardDestroyingOwner && guardNanosSince(gGuardDestroyStarted) >= kGuardWaitNanos;
}

static uint64_t guardIDs(AudioObjectID aggregate, AudioObjectID tap) {
  return ((uint64_t)aggregate << 32) | tap;
}
static AudioObjectID guardAggregate(uint64_t ids) { return (AudioObjectID)(ids >> 32); }
static AudioObjectID guardTap(uint64_t ids) { return (AudioObjectID)ids; }

#ifdef BS_GUARD_TESTING
// Deterministic interleavings in the standalone fake-HAL regression only.
extern void BSGuardTestPublishing(void);
extern void BSGuardTestWaiting(void);
#endif

bool BSCrashGuardSetOwned(AudioObjectID aggregate, AudioObjectID tap, uint64_t owner) {
  if (!owner || tap == kAudioObjectUnknown) return false;
  pthread_mutex_lock(&gGuardMutex);
#ifdef BS_GUARD_TESTING
  BSGuardTestPublishing();
#endif
  const uint64_t old = atomic_load(&gGuardIDs);
  const bool newer = owner > gGuardOwner && old == 0;
  const bool same = owner == gGuardOwner && !gGuardRetired &&
      guardTap(old) == tap &&
      (guardAggregate(old) == kAudioObjectUnknown || guardAggregate(old) == aggregate);
  // A rescue destroy stuck past the bound no longer blocks a new owner: its
  // IDs are already out of the registry and the new pair is independent.
  const bool accepted = (!gGuardDestroyingOwner || (newer && guardDestroyStale())) && (newer || same);
  if (accepted) {
    gGuardOwner = owner;
    gGuardRetired = false;
    atomic_store(&gGuardIDs, guardIDs(aggregate, tap));
  }
  pthread_mutex_unlock(&gGuardMutex);
  return accepted;
}

// Returns true when this owner's callback state may be freed. Bounded: if the
// rescue destroy has not returned within kGuardWaitMillis (coreaudiod wedged,
// exactly when rescue fires) the wait fails open and returns false, marking
// the owner unsafe so the caller leaks its context instead of blocking forever.
static bool guardWaitForOwner(uint64_t owner) {
  if (!owner) return true;
  if (gGuardDestroyingOwner == owner) {
    struct timespec deadline;
    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_nsec += (long)(kGuardWaitMillis % 1000) * 1000000L;
    deadline.tv_sec += kGuardWaitMillis / 1000 + deadline.tv_nsec / 1000000000L;
    deadline.tv_nsec %= 1000000000L;
    while (gGuardDestroyingOwner == owner) {
#ifdef BS_GUARD_TESTING
      BSGuardTestWaiting();
#endif
      // timedwait releases the mutex. The claimant can complete HAL teardown
      // and signal us; callback context / engine state remain alive meanwhile.
      // Also stop on elapsed monotonic time, so a wall-clock jump can't stretch it.
      if (pthread_cond_timedwait(&gGuardCompleted, &gGuardMutex, &deadline) == ETIMEDOUT ||
          guardDestroyStale()) {
        if (gGuardDestroyingOwner != owner) break;
        gGuardUnsafeOwner = owner;
        os_log_error(OS_LOG_DEFAULT, "BassShake crash guard: rescue destroy still pending after %d ms; "
                     "failing open and leaking pipeline %llu", kGuardWaitMillis, (unsigned long long)owner);
        return false;
      }
    }
  }
  return gGuardUnsafeOwner != owner;
}

static void guardReleaseLocked(AudioObjectID aggregate, AudioObjectID tap,
                               bool* ownsAggregate, bool* ownsTap) {
  uint64_t ids = atomic_load(&gGuardIDs);
  *ownsAggregate = aggregate != kAudioObjectUnknown && guardAggregate(ids) == aggregate;
  *ownsTap = tap != kAudioObjectUnknown && guardTap(ids) == tap;
  if (*ownsAggregate) ids &= UINT32_MAX;
  if (*ownsTap) ids &= (UINT64_MAX << 32);
  atomic_store(&gGuardIDs, ids);
  if (!ids) gGuardRetired = true;
}

bool BSCrashGuardReleaseOwned(uint64_t owner, AudioObjectID aggregate, AudioObjectID tap,
                              bool* ownsAggregate, bool* ownsTap) {
  pthread_mutex_lock(&gGuardMutex);
  const bool safe = guardWaitForOwner(owner);
  *ownsAggregate = *ownsTap = false;
  if (owner && owner == gGuardOwner) guardReleaseLocked(aggregate, tap, ownsAggregate, ownsTap);
  pthread_mutex_unlock(&gGuardMutex);
  return safe;
}

bool BSCrashGuardClearOwned(uint64_t owner) {
  pthread_mutex_lock(&gGuardMutex);
  const bool safe = guardWaitForOwner(owner);
  if (owner && owner == gGuardOwner) {
    atomic_store(&gGuardIDs, 0);
    gGuardRetired = true;
  }
  pthread_mutex_unlock(&gGuardMutex);
  return safe;
}

static bool guardFailOpen(uint64_t owner, bool requireOwner) {
  // Rescue must not wait behind publication or another rescue. A later tick
  // can retry; failed claims must not latch the Swift watchdog as rescued.
  if (pthread_mutex_trylock(&gGuardMutex) != 0) return false;
  const uint64_t ids = atomic_load(&gGuardIDs);
  if (!ids || gGuardDestroyingOwner || (requireOwner && (!owner || owner != gGuardOwner))) {
    pthread_mutex_unlock(&gGuardMutex);
    return false;
  }
  const uint64_t claimed = gGuardOwner;
  gGuardDestroyingOwner = claimed;
  gGuardDestroyStarted = mach_absolute_time();
  gGuardRetired = true;
  atomic_store(&gGuardIDs, 0);
  pthread_mutex_unlock(&gGuardMutex);

  OSStatus aggregateStatus = noErr;
  if (guardAggregate(ids) != kAudioObjectUnknown)
    aggregateStatus = AudioHardwareDestroyAggregateDevice(guardAggregate(ids));
  if (guardTap(ids) != kAudioObjectUnknown && AudioHardwareDestroyProcessTap != NULL)
    AudioHardwareDestroyProcessTap(guardTap(ids));

  pthread_mutex_lock(&gGuardMutex);
  // Always lift the barrier once the destroy attempt returns. Failure does not
  // prove IO stopped, so mark the owner unsafe: waiters return false and the
  // caller leaks the context the HAL may still call. Unknown object is safe:
  // a daemon restart or prior teardown already removed the device.
  if (aggregateStatus != noErr && aggregateStatus != kAudioHardwareBadObjectError) {
    gGuardUnsafeOwner = claimed;
    os_log_error(OS_LOG_DEFAULT, "BassShake crash guard: rescue destroy failed (%d); leaking pipeline %llu",
                 (int)aggregateStatus, (unsigned long long)claimed);
  }
  if (gGuardDestroyingOwner == claimed) gGuardDestroyingOwner = 0;
  pthread_cond_broadcast(&gGuardCompleted);
  pthread_mutex_unlock(&gGuardMutex);
  return true;
}

bool BSCrashGuardFailOpenOwned(uint64_t owner) { return guardFailOpen(owner, true); }

// Legacy entry points remain for C clients; the app uses the owned variants.
void BSCrashGuardSet(AudioObjectID aggregate, AudioObjectID tap) {
  pthread_mutex_lock(&gGuardMutex);
  guardWaitForOwner(gGuardDestroyingOwner);
  if (!gGuardOwner) gGuardOwner = 1;
  atomic_store(&gGuardIDs, guardIDs(aggregate, tap));
  gGuardRetired = aggregate == kAudioObjectUnknown && tap == kAudioObjectUnknown;
  pthread_mutex_unlock(&gGuardMutex);
}
void BSCrashGuardClear(void) { BSCrashGuardSet(kAudioObjectUnknown, kAudioObjectUnknown); }
void BSCrashGuardRelease(AudioObjectID aggregate, AudioObjectID tap, bool* ownsAggregate, bool* ownsTap) {
  pthread_mutex_lock(&gGuardMutex);
  guardWaitForOwner(gGuardDestroyingOwner);
  guardReleaseLocked(aggregate, tap, ownsAggregate, ownsTap);
  pthread_mutex_unlock(&gGuardMutex);
}
bool BSCrashGuardFailOpen(void) { return guardFailOpen(0, false); }
bool BSCrashGuardHoldsTap(void) { return guardTap(atomic_load(&gGuardIDs)) != kAudioObjectUnknown; }

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
  const uint64_t ids = atomic_exchange(&gGuardIDs, 0);
  const AudioObjectID agg = guardAggregate(ids);
  const AudioObjectID tap = guardTap(ids);
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
