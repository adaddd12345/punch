#include "punch/punch_c.h"

#include <algorithm>
#include <cstring>
#include <vector>

#include "punch/autoeq.hpp"
#include "punch/engine.hpp"

struct PunchEngine {
  punch::Engine engine;
};

using punch::EngineParams;

extern "C" {

PunchEngine* punch_engine_create(void) { return new PunchEngine(); }
void punch_engine_destroy(PunchEngine* e) { delete e; }

void punch_engine_prepare(PunchEngine* e, double sample_rate, int num_channels, int max_frames) {
  e->engine.prepare(sample_rate, num_channels, max_frames);
}

int punch_engine_latency_frames(const PunchEngine* e) { return e->engine.latencyFrames(); }
int punch_max_eq_bands(void) { return punch::kMaxEqBands; }

void punch_set_num_bands(PunchEngine* e, int n) { e->engine.edit().eq.numBands = std::clamp(n, 0, punch::kMaxEqBands); }

void punch_set_band(PunchEngine* e, int index, PunchFilterType type, double freq_hz, double gain_db, double q,
                    bool enabled) {
  if (index < 0 || index >= punch::kMaxEqBands) return;
  auto& eq = e->engine.edit().eq;
  eq.bands[size_t(index)] = {static_cast<punch::FilterType>(type), freq_hz, gain_db, q, enabled};
  eq.numBands = std::max(eq.numBands, index + 1);
}

void punch_set_preamp_db(PunchEngine* e, float db) { e->engine.edit().eq.preampDb = db; }
void punch_set_auto_preamp(PunchEngine* e, bool on) { e->engine.edit().autoPreamp = on; }

void punch_set_bass(PunchEngine* e, bool enabled, float amount, float cutoff_hz) {
  auto& b = e->engine.edit().bass;
  b.enabled = enabled;
  b.amount = amount;
  b.cutoffHz = cutoff_hz;
}

void punch_set_stereo_width(PunchEngine* e, bool enabled, float width) {
  auto& s = e->engine.edit().stereo;
  s.enabled = enabled;
  s.width = width;
}

void punch_set_crossfeed(PunchEngine* e, bool enabled, float amount) {
  auto& c = e->engine.edit().crossfeed;
  c.enabled = enabled;
  c.amount = amount;
}

void punch_set_output_gain_db(PunchEngine* e, float db) { e->engine.edit().outputGainDb = db; }

void punch_set_limiter(PunchEngine* e, bool enabled, float ceiling_db, float release_ms) {
  auto& l = e->engine.edit().limiter;
  l.enabled = enabled;
  l.ceilingDb = ceiling_db;
  l.releaseMs = release_ms;  // other limiter fields (bass priority) are kept
}

void punch_set_bypass(PunchEngine* e, bool bypass) { e->engine.edit().bypass = bypass; }
void punch_set_bass_priority(PunchEngine* e, float crossover_hz) {
  e->engine.edit().limiter.bassPriorityHz = std::max(0.f, crossover_hz);
}

void punch_set_limiter_shape(PunchEngine* e, float slow_release_ms, float clip_knee_db) {
  auto& l = e->engine.edit().limiter;
  l.slowReleaseMs = std::max(0.f, slow_release_ms);
  l.clipKneeDb = std::max(0.f, clip_knee_db);
}
void punch_set_boost_leveler(PunchEngine* e, bool on) { e->engine.edit().boostLeveler = on; }
double punch_eq_peak_boost_db(const PunchEngine* e) {
  const EngineParams& p = e->engine.pending();
  return punch::eqPeakBoostDb({&p.correction, &p.eq}, e->engine.sampleRate()) + double(p.correction.preampDb) +
         double(p.eq.preampDb);
}

void punch_set_compressor(PunchEngine* e, bool enabled, float threshold_db, float ratio, float attack_ms,
                          float release_ms, float makeup_db, float sidechain_hp_hz) {
  e->engine.edit().compressor = {threshold_db, ratio, attack_ms, release_ms, 6.f, makeup_db, sidechain_hp_hz, enabled};
}

void punch_set_saturator(PunchEngine* e, bool enabled, float drive_db, float mix, float tone_hz, float asymmetry,
                         float crossover_hz) {
  e->engine.edit().saturator = {drive_db, mix, tone_hz, asymmetry, crossover_hz, enabled};
}

void punch_set_ambience(PunchEngine* e, bool enabled, float mix, float size, float damping_hz) {
  e->engine.edit().ambience = {mix, size, damping_hz, enabled, 1.f};
}

void punch_set_bass_character(PunchEngine* e, int kind, float amount) {
  auto& b = e->engine.edit().bassCharacter;
  b.kind = static_cast<punch::BassCharacterKind>(std::clamp(kind, 0, 2));
  b.amount = amount;
}

void punch_set_late_night(PunchEngine* e, bool on, float haze) {
  auto& l = e->engine.edit().lateNight;
  l.enabled = on;
  l.haze = haze;
}

void punch_set_noise(PunchEngine* e, bool enabled, int color, float level_db) {
  e->engine.edit().noise = {static_cast<punch::NoiseColor>(std::clamp(color, 0, 2)), level_db, enabled};
}

void punch_set_loudness_guard(PunchEngine* e, bool enabled, float over_db, float max_cut_db) {
  e->engine.edit().guard = {over_db, max_cut_db, enabled};
}
float punch_loudness_guard_cut_db(const PunchEngine* e) { return e->engine.loudnessGuardCutDb(); }

void punch_set_spike_guard(PunchEngine* e, bool enabled) { e->engine.edit().spike.enabled = enabled; }
void punch_set_hearing(PunchEngine* e, bool enabled, const float* left6, const float* right6) {
  auto& h = e->engine.edit().hearing;
  h.enabled = enabled;
  for (int b = 0; b < punch::kHearingBands; ++b) {
    h.gainDb[0][b] = left6 ? std::clamp(left6[b], 0.f, punch::kHearingMaxDb) : 0.f;
    h.gainDb[1][b] = right6 ? std::clamp(right6[b], 0.f, punch::kHearingMaxDb) : 0.f;
  }
}
uint32_t punch_spike_guard_events(const PunchEngine* e) { return e->engine.spikeEvents(); }

void punch_set_dj(PunchEngine* e, bool low_kill, bool mid_kill, bool high_kill, float filter, bool echo, bool crush,
                  bool drive) {
  auto& d = e->engine.edit().dj;
  d.lowKill = low_kill;
  d.midKill = mid_kill;
  d.highKill = high_kill;
  d.filter = filter;
  d.echo = echo;
  d.crush = crush;
  d.drive = drive;
}

void punch_set_dj_fx(PunchEngine* e, bool tape_stop, bool chipmunk, bool screw, bool roll, bool lofi, bool pump) {
  auto& d = e->engine.edit().dj;
  d.tapeStop = tape_stop;
  d.chipmunk = chipmunk;
  d.screw = screw;
  d.roll = roll;
  d.lofi = lofi;
  d.pump = pump;
}

void punch_set_dj_track_tempo(PunchEngine* e, bool on) { e->engine.edit().dj.trackTempo = on; }
float punch_dj_bpm(const PunchEngine* e) { return e->engine.djBpm(); }
bool punch_dj_roll_silent(const PunchEngine* e) { return e->engine.djRollSilent(); }

void punch_set_correction_num_bands(PunchEngine* e, int n) {
  e->engine.edit().correction.numBands = std::clamp(n, 0, punch::kMaxEqBands);
}

void punch_set_correction_band(PunchEngine* e, int index, PunchFilterType type, double freq_hz, double gain_db,
                               double q, bool enabled) {
  if (index < 0 || index >= punch::kMaxEqBands) return;
  auto& eq = e->engine.edit().correction;
  eq.bands[size_t(index)] = {static_cast<punch::FilterType>(type), freq_hz, gain_db, q, enabled};
  eq.numBands = std::max(eq.numBands, index + 1);
}
void punch_engine_publish(PunchEngine* e) { e->engine.publish(); }
double punch_effective_preamp_db(const PunchEngine* e) { return e->engine.effectivePreampDb(); }

int punch_load_equalizer_apo(PunchEngine* e, const char* text, size_t len) {
  const auto r = punch::parseEqualizerApo(std::string_view(text, len));
  if (!r.ok()) return -1;
  e->engine.edit().eq = r.params;
  return r.params.numBands;
}

size_t punch_export_equalizer_apo(const PunchEngine* e, char* buf, size_t buf_len) {
  const std::string s = punch::formatEqualizerApo(e->engine.pending().eq);
  if (buf && buf_len > 0) {
    const size_t n = std::min(s.size(), buf_len - 1);
    std::memcpy(buf, s.data(), n);
    buf[n] = '\0';
  }
  return s.size();
}

void punch_eq_curve(const PunchEngine* e, double lo_hz, double hi_hz, double* out_db, size_t n) {
  std::vector<double> v(n);
  punch::eqResponseCurve(e->engine.pending().eq, e->engine.sampleRate(), lo_hz, hi_hz, v);
  std::copy(v.begin(), v.end(), out_db);
}

void punch_process_interleaved(PunchEngine* e, const float* in, float* out, int num_channels, int num_frames) {
  e->engine.processInterleaved(in, out, num_channels, num_frames);
}

void punch_process_planar(PunchEngine* e, float* const* channels, int num_channels, int num_frames) {
  e->engine.processPlanar(channels, num_channels, num_frames);
}

PunchMeters punch_take_meters(PunchEngine* e) {
  const punch::Meters m = e->engine.takeMeters();
  PunchMeters out;
  out.in_peak[0] = m.inPeak[0];
  out.in_peak[1] = m.inPeak[1];
  out.out_peak[0] = m.outPeak[0];
  out.out_peak[1] = m.outPeak[1];
  out.gain_reduction_db = m.gainReductionDb;
  out.out_rms[0] = m.outRms[0];
  out.out_rms[1] = m.outRms[1];
  return out;
}

size_t punch_read_analyzer(PunchEngine* e, float* out, size_t max) { return e->engine.analyzerFeed().pop(out, max); }

}  // extern "C"
