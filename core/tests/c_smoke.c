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
  for (int i = 0; i < 512; ++i) buf[2 * i] = buf[2 * i + 1] = 0.5f * sinf((float)i * 0.1f);
  punch_process_interleaved(e, buf, buf, 2, 512);
  PunchMeters m = punch_take_meters(e);
  char out[256];
  size_t need = punch_export_equalizer_apo(e, out, sizeof out);
  double curve[8];
  punch_eq_curve(e, 20.0, 20000.0, curve, 8);
  printf("in %.3f out %.3f latency %d preamp %.2f export %zu bytes\n", m.in_peak[0], m.out_peak[0],
         punch_engine_latency_frames(e), punch_effective_preamp_db(e), need);
  punch_engine_destroy(e);
  return (m.out_peak[0] > 0.f && need > 0) ? 0 : 1;
}
