// Offline renderer: runs a WAV file through the exact real-time engine in
// IO-sized blocks. Useful for A/B listening and regression tests without a Mac.
//
//   punch_render in.wav out.wav [--apo profile.txt] [--bass 0..1] [--width 0..2]
//                [--crossfeed 0..1] [--gain dB] [--block N]
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>

#include "punch/autoeq.hpp"
#include "punch/engine.hpp"
#include "wav.hpp"

int main(int argc, char** argv) {
  if (argc < 3) {
    std::fprintf(stderr, "usage: %s in.wav out.wav [--apo file] [--bass x] [--width x] [--crossfeed x] [--gain dB] [--block N]\n", argv[0]);
    return 2;
  }
  wav::Audio a;
  std::string err;
  if (!wav::read(argv[1], a, err)) { std::fprintf(stderr, "%s\n", err.c_str()); return 1; }

  punch::Engine e;
  int block = 512;
  for (int i = 3; i + 1 < argc; i += 2) {
    const std::string k = argv[i];
    const char* v = argv[i + 1];
    if (k == "--apo") {
      std::ifstream f(v);
      std::stringstream ss;
      ss << f.rdbuf();
      const auto r = punch::parseEqualizerApo(ss.str());
      if (!r.ok()) { std::fprintf(stderr, "no filters in %s\n", v); return 1; }
      e.edit().eq = r.params;
    } else if (k == "--bass") {
      e.edit().bass.enabled = true;
      e.edit().bass.amount = std::strtof(v, nullptr);
    } else if (k == "--width") {
      e.edit().stereo.enabled = true;
      e.edit().stereo.width = std::strtof(v, nullptr);
    } else if (k == "--crossfeed") {
      e.edit().crossfeed.enabled = true;
      e.edit().crossfeed.amount = std::strtof(v, nullptr);
    } else if (k == "--gain") {
      e.edit().outputGainDb = std::strtof(v, nullptr);
    } else if (k == "--block") {
      block = std::max(16, std::atoi(v));
    } else {
      std::fprintf(stderr, "unknown option %s\n", k.c_str());
      return 2;
    }
  }
  e.prepare(a.sampleRate, a.channels, block);
  const int frames = a.frames();
  for (int s = 0; s < frames; s += block) {
    float* p = a.samples.data() + size_t(s) * size_t(a.channels);
    e.processInterleaved(p, p, a.channels, std::min(block, frames - s));
  }
  if (!wav::writeFloat(argv[2], a)) { std::fprintf(stderr, "cannot write %s\n", argv[2]); return 1; }
  const auto m = e.takeMeters();
  std::printf("%d frames @ %d Hz, %d ch, preamp %.2f dB, latency %d frames, peak out %.3f\n", frames, a.sampleRate,
              a.channels, e.effectivePreampDb(), e.latencyFrames(), std::max(m.outPeak[0], m.outPeak[1]));
  return 0;
}
