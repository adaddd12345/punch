/* Verifies the C header is valid C and the API links without C++. */
#include <math.h>
#include <stdio.h>
#include <string.h>

#include "punch/punch_c.h"

int main(void) {
  PunchEngine* e = punch_engine_create();
  const char* apo = "Preamp: -3 dB\nFilter 1: ON PK Fc 1000 Hz Gain 3 dB Q 1.0\n";
  if (punch_load_equalizer_apo(e, apo, strlen(apo)) != 1) return 1;
  punch_set_bass(e, true, 0.5f, 120.f);
  punch_engine_prepare(e, 48000.0, 2, 512);
  float buf[512 * 2];
  /* Several blocks: the output is delayed by the look-ahead latency. */
  for (int b = 0; b < 4; ++b) {
    for (int i = 0; i < 512; ++i) buf[2 * i] = buf[2 * i + 1] = 0.5f * sinf((float)(b * 512 + i) * 0.1f);
    punch_process_interleaved(e, buf, buf, 2, 512);
  }
  PunchMeters m = punch_take_meters(e);
  char out[256];
  size_t need = punch_export_equalizer_apo(e, out, sizeof out);
  double curve[8];
  punch_eq_curve(e, 20.0, 20000.0, curve, 8);
  const PunchEQBand band = {PUNCH_BELL, 1000.0, 3.0, 1.0, true};
  double stateless_curve[8];
  punch_eq_curve_for_bands(&band, 1, 48000.0, -3.f, 20.0, 20000.0, stateless_curve, 8);
  for (int i = 0; i < 8; ++i) if (curve[i] != stateless_curve[i]) return 2;
  printf("in %.3f out %.3f latency %d preamp %.2f export %zu bytes\n", m.in_peak[0], m.out_peak[0],
         punch_engine_latency_frames(e), punch_effective_preamp_db(e), need);
  punch_engine_destroy(e);
  return (m.out_peak[0] > 0.f && need > 0) ? 0 : 1;
}
