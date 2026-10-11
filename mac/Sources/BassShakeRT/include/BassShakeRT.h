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
} BSRenderStats;

BSRenderStats BSRenderContextStats(const BSRenderContext* ctx);

// The AudioDeviceIOProc. clientData must be a BSRenderContext*. Nullability
// matches Core Audio's AudioDeviceIOProc typedef so Swift can pass it
// directly as a @convention(c) function.
OSStatus BSIOProc(AudioObjectID device, const AudioTimeStamp* now, const AudioBufferList* input,
                  const AudioTimeStamp* inputTime, AudioBufferList* output, const AudioTimeStamp* outputTime,
                  void* _Nullable clientData);

// ---- crash guard
// A muted process tap that outlives us would silence the whole Mac. We
// record the live tap/aggregate IDs here and tear them down from fatal and
// termination signal handlers (best effort; Core Audio calls are not
// async-signal-safe, but the process is dying anyway — FineTune does the
// same). Install once at launch.
void BSCrashGuardInstall(void);
void BSCrashGuardSet(AudioObjectID aggregate, AudioObjectID tap);
void BSCrashGuardClear(void);
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
