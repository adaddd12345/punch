// CPU cost of the full chain, reported as a fraction of real time.
#include <chrono>
#include <cmath>
#include <cstdio>
#include <random>
#include <vector>

#include "punch/engine.hpp"

int main() {
  constexpr double fs = 48000;
  constexpr int block = 512;
  punch::Engine e;
  auto& p = e.edit();
  p.eq.numBands = 16;
  for (int i = 0; i < 16; ++i) p.eq.bands[size_t(i)] = {punch::FilterType::Bell, 25.0 * std::pow(2.0, i * 0.66), 2.0, 1.2, true};
  p.bass.enabled = true;
  p.bass.amount = 0.6f;
  p.stereo.enabled = true;
  p.stereo.width = 1.4f;
  p.crossfeed.enabled = true;
  p.crossfeed.amount = 0.3f;
  p.outputGainDb = 6.f;
  e.prepare(fs, 2, block);

  std::mt19937 rng(7);
  std::uniform_real_distribution<float> ud(-0.5f, 0.5f);
  std::vector<float> buf(block * 2);
  for (auto& v : buf) v = ud(rng);

  const int seconds = 60;
  const int iters = int(seconds * fs / block);
  const auto t0 = std::chrono::steady_clock::now();
  for (int i = 0; i < iters; ++i) {
    if (i % 200 == 0) {  // simulate a user dragging a band
      e.edit().eq.bands[3].gainDb = float((i / 200) % 12) - 6.f;
      e.publish();
    }
    e.processInterleaved(buf.data(), buf.data(), 2, block);
  }
  const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  std::printf("16-band EQ + bass + width + crossfeed + limiter, stereo 48k, block %d\n", block);
  std::printf("%d s of audio in %.3f s  ->  %.3f%% of one core (%.1f us per block, budget %.0f us)\n", seconds, secs,
              100.0 * secs / seconds, 1e6 * secs / iters, 1e6 * block / fs);
  return 0;
}
