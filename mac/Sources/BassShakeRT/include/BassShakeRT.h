// Real-time render callback for the tap → aggregate → output pipeline.
//
// Written in C on purpose: nothing on the Core Audio IO thread may allocate,
// lock, log, or touch Swift/ObjC reference counting. Swift only creates the
// context, hands BSIOProc to AudioDeviceCreateIOProcID, and polls the
// atomic counters from the main thread.
#ifndef BASS_SHAKE_RT_H
#define BASS_SHAKE_RT_H

#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#include "punch/punch_c.h"

#ifdef __cplusplus
extern "C" {
#endif

CF_ASSUME_NONNULL_BEGIN

typedef struct BSRenderContext BSRenderContext;

BSRenderContext* _Nullable BSRenderContextCreate(PunchEngine* engine);
void BSRenderContextDestroy(BSRenderContext* ctx);

// Index of the tap's buffer in the aggregate's input AudioBufferList. Input
// streams of real sub-devices come first, taps after them. Pass UINT32_MAX
// to use the last input buffer.
void BSRenderContextSetTapBufferIndex(BSRenderContext* ctx, uint32_t index);

// Optional group fan-out, configured before IO starts. Each physical output
// channel takes a source channel, or -1 for silence. No allocation in IO.
// Returns false if the map exceeds the supported size or has invalid entries.
bool BSRenderContextSetOutputMap(BSRenderContext* ctx, const int32_t* channels, uint32_t count);

// Before starting a group IOProc, disable physical microphone input streams.
// Aggregate creation may ignore channels-in=0; only the appended tap streams
// should run. This function allocates and must never be called from IO.
OSStatus BSConfigureTapOnlyInputs(AudioObjectID device, AudioDeviceIOProcID proc, uint32_t tapStreams);

// Ramp output from silence over `ms` (start-up / after rebuild) so the
// switch from the unprocessed to the processed signal never clicks.
void BSRenderContextFadeIn(BSRenderContext* ctx, double sampleRate, double ms);
// Ramp to silence; poll BSRenderContextIsFadedOut() before stopping IO.
void BSRenderContextFadeOut(BSRenderContext* ctx, double sampleRate, double ms);
bool BSRenderContextIsFadedOut(const BSRenderContext* ctx);

// Health counters for the main-thread watchdog.
typedef struct {
  uint64_t callbacks;        // IO cycles seen
  uint64_t framesProcessed;
  uint64_t silentCallbacks;  // tap buffer was bit-exact 0.0 for the whole cycle
  uint64_t layoutErrors;     // tap buffer missing / unexpected format
  uint32_t lastInputChannels;
  uint32_t lastOutputChannels;
  uint64_t deadOutputCallbacks;  // tap had sound but what we wrote was silent / non-finite
} BSRenderStats;

BSRenderStats BSRenderContextStats(const BSRenderContext* ctx);

// Optional diagnostics, configured once before IO starts. Disabled by default.
// Uses raw host-clock ticks and actual frame counts; never captures audio.
bool BSRenderContextEnableTiming(BSRenderContext* ctx, double sampleRate);
enum { BSRenderTimingBucketCount = 16 };
typedef struct {
  bool enabled;
  double nanosecondsPerTick;
  uint64_t callbacks;
  uint64_t totalTicks;
  uint64_t maxTicks;
  uint64_t overBudgetCallbacks;
  // Bucket i=0..14: elapsed <= 2^(i+3) microseconds. Bucket 15: overflow.
  uint64_t buckets[BSRenderTimingBucketCount];
} BSRenderTiming;
// Cumulative, approximate snapshot while IO runs (no reset or RT-side locks).
BSRenderTiming BSRenderContextTiming(const BSRenderContext* ctx);

// The AudioDeviceIOProc. clientData must be a BSRenderContext*. Nullability
// matches Core Audio's AudioDeviceIOProc typedef so Swift can pass it
// directly as a @convention(c) function.
OSStatus BSIOProc(AudioObjectID device, const AudioTimeStamp* now, const AudioBufferList* input,
                  const AudioTimeStamp* inputTime, AudioBufferList* output, const AudioTimeStamp* outputTime,
                  void* _Nullable clientData);

// ---- crash guard
// Record the live tap/aggregate IDs for normal exit and watchdog rescue.
// Signal handlers exit/re-raise without calling HAL (it is not signal-safe);
// coreaudiod releases a dead client's private objects. Install once at launch.
void BSCrashGuardInstall(void);
// Production pipeline registry. Owners must be nonzero and strictly increase
// between pipelines. Publish the tap first, then add its aggregate with the
// same owner. False means this publication was refused: the caller owns only
// newly-created, unpublished IDs and must dispose of those itself.
// A retired/claimed owner can never republish; no owner can publish while
// rescue destruction is in flight (until it outlives the ~500 ms bound). All functions below are control-thread-only.
bool BSCrashGuardSetOwned(AudioObjectID aggregate, AudioObjectID tap, uint64_t owner);
// Atomically claims only the requested owner; true means teardown attempted.
// False also means publication is
// currently in progress; the watchdog may retry. No HAL call holds a mutex.
bool BSCrashGuardFailOpenOwned(uint64_t owner);
// Release/Clear wait (bounded, ~500 ms) for this owner's in-flight rescue
// destruction. True: callers may free callback state. False: the HAL destroy
// failed or has not returned in time (wedged coreaudiod) and the IOProc may
// still run, so the caller must leak the render context rather than free it.
// Waits release the registry mutex and never block indefinitely.
bool BSCrashGuardReleaseOwned(uint64_t owner, AudioObjectID aggregate, AudioObjectID tap,
                              bool* ownsAggregate, bool* ownsTap);
bool BSCrashGuardClearOwned(uint64_t owner);

void BSCrashGuardSet(AudioObjectID aggregate, AudioObjectID tap);
void BSCrashGuardClear(void);
// Hands this pipeline's IDs back from the guard. *owns… is false for an ID
// BSCrashGuardFailOpen already destroyed (the caller must not touch it again:
// Core Audio may have reused the number).
void BSCrashGuardRelease(AudioObjectID aggregate, AudioObjectID tap, bool* ownsAggregate, bool* ownsTap);
// Rescue path (never the IO thread, never main): destroys the guarded
// aggregate and tap now so the original audio plays unprocessed. Used when
// the audio queue is wedged in a HAL call. True if ownership was claimed and
// teardown was attempted; a HAL error is not a confirmed successful destroy.
bool BSCrashGuardFailOpen(void);
bool BSCrashGuardHoldsTap(void);
// Extra taps destroyed by the same guard: the Live Channels per-app mute
// taps (CATapMuteBehavior.muted silences an app whether or not anyone reads
// the tap, so one left behind would keep that app silent). A small fixed
// table; Add returns false when it is full (the tap still works, it is just
// not crash-guarded). Remove is a no-op for an unknown ID.
enum { BSCrashGuardMaxExtraTaps = 32 };
bool BSCrashGuardAddTap(AudioObjectID tap);
void BSCrashGuardRemoveTap(AudioObjectID tap);

// ---- Live Channels level meter
// One private aggregate holds one non-muting tap per playing process.
// BSMeterIOProc never writes audio (it zeroes the output buffers); it only
// stores the peak |sample| of each tap's buffer(s) into per-slot atomics
// that Swift drains (~30 Hz) with BSMeterContextTakePeak.
enum { BSMeterMaxSlots = 64, BSMeterMaxBuffers = 256 };

typedef struct BSMeterContext BSMeterContext;

BSMeterContext* _Nullable BSMeterContextCreate(void);
void BSMeterContextDestroy(BSMeterContext* ctx);

// Maps the LAST `count` buffers of the aggregate's input list to meter slots
// (taps are appended after any real sub-device input streams, in tap-list
// order). slots[i] is the slot of the i-th of those buffers, or -1 to
// ignore it. A non-interleaved tap contributes one buffer per channel, all
// mapped to the same slot. Call before AudioDeviceStart, never while IO runs.
void BSMeterContextSetLayout(BSMeterContext* ctx, const int32_t* slots, uint32_t count);

// Linear peak (max |sample|, 0...) of `slot` since the previous call, then
// resets it. Lock-free; safe from any one non-IO thread.
float BSMeterContextTakePeak(BSMeterContext* ctx, uint32_t slot);
uint64_t BSMeterContextCallbacks(const BSMeterContext* ctx);
uint64_t BSMeterContextLayoutErrors(const BSMeterContext* ctx);

// The AudioDeviceIOProc. clientData must be a BSMeterContext*.
OSStatus BSMeterIOProc(AudioObjectID device, const AudioTimeStamp* now, const AudioBufferList* input,
                       const AudioTimeStamp* inputTime, AudioBufferList* output, const AudioTimeStamp* outputTime,
                       void* _Nullable clientData);

CF_ASSUME_NONNULL_END

#ifdef __cplusplus
}
#endif

#endif
