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

typedef struct BSRenderContext BSRenderContext;

BSRenderContext* BSRenderContextCreate(PunchEngine* engine);
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

// The AudioDeviceIOProc. clientData must be a BSRenderContext*.
OSStatus BSIOProc(AudioObjectID device, const AudioTimeStamp* now, const AudioBufferList* input,
                  const AudioTimeStamp* inputTime, AudioBufferList* output, const AudioTimeStamp* outputTime,
                  void* clientData);

// ---- crash guard
// A muted process tap that outlives us would silence the whole Mac. We
// record the live tap/aggregate IDs here and tear them down from fatal and
// termination signal handlers (best effort; Core Audio calls are not
// async-signal-safe, but the process is dying anyway — FineTune does the
// same). Install once at launch.
void BSCrashGuardInstall(void);
void BSCrashGuardSet(AudioObjectID aggregate, AudioObjectID tap);
void BSCrashGuardClear(void);

#ifdef __cplusplus
}
#endif

#endif
