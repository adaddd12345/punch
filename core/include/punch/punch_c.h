/* Plain C surface of the DSP core, imported by the Swift app through a
 * module map. Control functions: call from one thread (main). Process
 * functions: call only from the Core Audio IO thread. */
#ifndef PUNCH_C_H
#define PUNCH_C_H

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PunchEngine PunchEngine;

typedef enum {
  PUNCH_BELL = 0,
  PUNCH_LOW_SHELF,
  PUNCH_HIGH_SHELF,
  PUNCH_LOW_PASS,
  PUNCH_HIGH_PASS,
  PUNCH_BAND_PASS,
  PUNCH_NOTCH,
} PunchFilterType;

typedef struct {
  float in_peak[2];
  float out_peak[2];
  float gain_reduction_db;
  float out_rms[2]; /* short-term output RMS (about 50 ms), linear */
} PunchMeters;

PunchEngine* punch_engine_create(void);
void punch_engine_destroy(PunchEngine* e);

/* Must not run concurrently with process calls (stop the IOProc first). */
void punch_engine_prepare(PunchEngine* e, double sample_rate, int num_channels, int max_frames);
int punch_engine_latency_frames(const PunchEngine* e);
int punch_max_eq_bands(void);

/* --- control: edit pending params, then punch_engine_publish() --- */
void punch_set_num_bands(PunchEngine* e, int n);
void punch_set_band(PunchEngine* e, int index, PunchFilterType type, double freq_hz, double gain_db, double q,
                    bool enabled);
void punch_set_preamp_db(PunchEngine* e, float db);
void punch_set_auto_preamp(PunchEngine* e, bool on);
void punch_set_bass(PunchEngine* e, bool enabled, float amount, float cutoff_hz);
void punch_set_stereo_width(PunchEngine* e, bool enabled, float width);
void punch_set_crossfeed(PunchEngine* e, bool enabled, float amount);
void punch_set_output_gain_db(PunchEngine* e, float db);
/* Master fade (Lights Out): a last gain after the limiter, also in bypass.
 * Moves linearly in dB to target_db over ramp_ms; at or below -90 dB the
 * output is exactly silent. 0 dB settled = bit-exact. */
void punch_set_master_fade(PunchEngine* e, float target_db, float ramp_ms);
/* Where the master fade stands now (dB). Any thread. */
double punch_master_fade_db(const PunchEngine* e);
void punch_set_limiter(PunchEngine* e, bool enabled, float ceiling_db, float release_ms);
void punch_set_bypass(PunchEngine* e, bool bypass);
/* Bass-priority limiting: below crossover_hz the bass is limited against the
 * room the rest of the mix leaves (mids never duck for the bass), and bass
 * boosts no longer cost auto-headroom. 0 = off. */
void punch_set_bass_priority(PunchEngine* e, float crossover_hz);
/* Limiter shape: program-dependent slow release (ms, 0 = off) and a soft
 * clipper knee below the ceiling (dB, 0 = off). Kept by punch_set_limiter. */
void punch_set_limiter_shape(PunchEngine* e, float slow_release_ms, float clip_knee_db);
/* Boost leveler: a positive output gain only uses the headroom the music
 * leaves under the limiter ceiling (slow peak estimate). Off = bit-exact. */
void punch_set_boost_leveler(PunchEngine* e, bool on);
/* Peak gain (dB) of the pending correction + user EQ, their preamps
 * included. Control thread. */
double punch_eq_peak_boost_db(const PunchEngine* e);

/* Character stages (modes / genre presets). */
void punch_set_compressor(PunchEngine* e, bool enabled, float threshold_db, float ratio, float attack_ms,
                          float release_ms, float makeup_db, float sidechain_hp_hz);
void punch_set_saturator(PunchEngine* e, bool enabled, float drive_db, float mix, float tone_hz, float asymmetry,
                         float crossover_hz);
void punch_set_ambience(PunchEngine* e, bool enabled, float mix, float size, float damping_hz);
/* Bass character, after the user EQ: kind 0 off, 1 Distort (driven, distorted
 * 808), 2 Punch (boom-bap transient snap + warmth). amount 0..1 (glides).
 * Only the low band changes and the lows end up mono. Off = bit-exact. */
void punch_set_bass_character(PunchEngine* e, int kind, float amount);
/* Late Night: mellow, underwater master tone (low-pass 5 -> 2.5 kHz with
 * haze 0..1, warm shelf, tape drive, glue compression, short room). Fades in
 * and out over ~300 ms; caps Distort's drive while on. Off = bit-exact. */
void punch_set_late_night(PunchEngine* e, bool on, float haze);
/* color: 0 white, 1 pink, 2 brown. level_db is RMS dBFS. */
void punch_set_noise(PunchEngine* e, bool enabled, int color, float level_db);
/* Night Guard: turns down anything more than over_db louder than the running
 * average (e.g. a loud title sequence after quiet dialogue). */
void punch_set_loudness_guard(PunchEngine* e, bool enabled, float over_db, float max_cut_db);
float punch_loudness_guard_cut_db(const PunchEngine* e);
/// Ear Protector: sudden blasts drop ~20 dB for 3 s. Events counts trips.
void punch_set_spike_guard(PunchEngine* e, bool enabled);
// Hearing Fit: per-ear boosts (dB, clamped 0..10) at 250,500,1k,2k,4k,8k Hz.
// left6/right6 may be NULL (= flat). Call punch_engine_publish() after.
void punch_set_hearing(PunchEngine* e, bool enabled, const float* left6, const float* right6);
uint32_t punch_spike_guard_events(const PunchEngine* e);
/* DJ effects. filter: -1..1 (<0 low-pass sweep, >0 high-pass sweep, 0 off). */
void punch_set_dj(PunchEngine* e, bool low_kill, bool mid_kill, bool high_kill, float filter, bool echo, bool crush,
                  bool drive);
/* DJ performance pads (each glides in/out; all off = bit-exact).
 * tape_stop: slows to a halt over 1 s; release crossfades back to live.
 * chipmunk: +7 semitones; screw: -5 semitones (chipmunk wins if both).
 * roll: loops the last 1/8 note at the detected tempo (120 BPM if unknown),
 *       halving to 1/16 then 1/32 every beat held.
 * lofi: cassette wow & flutter, saturation, 3.5 kHz low-pass, narrow, hiss.
 * pump: ducks -9 dB on every beat (follows kicks when the tempo is unknown). */
void punch_set_dj_fx(PunchEngine* e, bool tape_stop, bool chipmunk, bool screw, bool roll, bool lofi, bool pump);
/* Keep the tempo tracker running with no DJ effect on (e.g. while the DJ
 * panel is showing) so Roll and Pump know the BPM on the first press. */
void punch_set_dj_track_tempo(PunchEngine* e, bool on);
/* Detected tempo in BPM (0 = unknown / unsure). Any thread. */
float punch_dj_bpm(const PunchEngine* e);
/* True while Roll loops a slice that is pure silence (expected silent output). Any thread. */
bool punch_dj_roll_silent(const PunchEngine* e);

/* Correction stage (applied before the user EQ): headphone correction or
 * additive layers like Studio Ears. */
void punch_set_correction_num_bands(PunchEngine* e, int n);
void punch_set_correction_band(PunchEngine* e, int index, PunchFilterType type, double freq_hz, double gain_db,
                               double q, bool enabled);
void punch_engine_publish(PunchEngine* e);
/* Preamp actually applied after auto-preamp compensation (valid after publish). */
double punch_effective_preamp_db(const PunchEngine* e);

/* Replace EQ bands + preamp from Equalizer APO / AutoEq text. Returns the
 * number of bands loaded, or -1 if nothing usable was found. Does not
 * publish. */
int punch_load_equalizer_apo(PunchEngine* e, const char* text, size_t len);
/* Writes NUL-terminated text into buf. Returns required length excluding NUL. */
size_t punch_export_equalizer_apo(const PunchEngine* e, char* buf, size_t buf_len);

/* Response of the pending EQ (incl. preamp) on a log grid, for drawing. */
void punch_eq_curve(const PunchEngine* e, double lo_hz, double hi_hz, double* out_db, size_t n);

/* --- real-time --- */
void punch_process_interleaved(PunchEngine* e, const float* in, float* out, int num_channels, int num_frames);
void punch_process_planar(PunchEngine* e, float* const* channels, int num_channels, int num_frames);

/* --- metering (UI thread) --- */
PunchMeters punch_take_meters(PunchEngine* e);
/* Pops up to max mono post-FX samples for the spectrum analyzer. */
size_t punch_read_analyzer(PunchEngine* e, float* out, size_t max);

#ifdef __cplusplus
}
#endif

#endif /* PUNCH_C_H */
