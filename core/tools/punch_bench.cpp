// Offline throughput and targeted plumbing benchmarks. These measure CPU
// work, not real Core Audio scheduling deadlines or battery consumption.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <random>
#include <string_view>
#include <vector>

#include "punch/analysis.hpp"
#include "punch/engine.hpp"

namespace {

using Clock = std::chrono::steady_clock;

void configureBands(punch::Engine& e) {
  e.edit().eq.numBands = 16;
  for (int i = 0; i < 16; ++i)
    e.edit().eq.bands[size_t(i)] = {punch::FilterType::Bell, 25.0 * std::pow(2.0, i * 0.66), 2.0, 1.2, true};
}

void controlBenchmark() {
  punch::Engine e;
  configureBands(e);
  e.prepare(48000, 2, 256);
  for (bool changeEq : {false, true}) {
    std::vector<double> timings;
    for (int round = 0; round < 9; ++round) {
      const auto begin = Clock::now();
      for (int i = 0; i < 1000; ++i) {
        if (changeEq) e.edit().eq.bands[3].gainDb = double(i % 13) - 6.0;
        else e.edit().outputGainDb = float(i % 13);
        e.publish();
      }
      timings.push_back(std::chrono::duration<double, std::micro>(Clock::now() - begin).count() / 1000.0);
    }
    std::sort(timings.begin(), timings.end());
    std::printf("16-band %s publish: median %.3f us, range %.3f..%.3f (9 x 1000 calls)\n",
                changeEq ? "EQ" : "non-EQ", timings[4], timings.front(), timings.back());
  }
}

void limiterBenchmark() {
  constexpr int block = 256, iterations = 48000 * 120 / block;
  punch::Limiter limiter;
  limiter.prepare(48000, 2, 5.f);
  limiter.setParams({-1.f, 80.f, true});
  std::vector<float> source(block * 2), work(block * 2);
  std::mt19937 rng(7);
  std::uniform_real_distribution<float> noise(-1.5f, 1.5f);
  for (auto& x : source) x = noise(rng);
  float* ch[2] = {work.data(), work.data() + block};
  std::vector<double> timings;
  for (int round = 0; round < 9; ++round) {
    const auto begin = Clock::now();
    for (int i = 0; i < iterations; ++i) {
      std::copy(source.begin(), source.end(), work.begin());
      limiter.process(ch, 2, block);
    }
    timings.push_back(std::chrono::duration<double, std::micro>(Clock::now() - begin).count() / iterations);
  }
  std::sort(timings.begin(), timings.end());
  std::printf("Limiter stereo 48k/256: median %.3f us/block, range %.3f..%.3f (9 x 120 s audio)\n",
              timings[4], timings.front(), timings.back());
}

void callbackBenchmark() {
  constexpr int iterations = 5000;
  for (double fs : {48000.0, 192000.0}) {
    for (int block : {64, 256, 1024}) {
      for (bool shaker : {false, true}) {
        punch::Engine e;
        configureBands(e);
        auto& p = e.edit();
        p.bass.enabled = true;
        p.bass.amount = 0.6f;
        p.bassShaker = shaker;
        p.stereo = {1.4f, 180.f, true};
        p.crossfeed = {0.3f, 700.f, true};
        p.outputGainDb = 6.f;
        e.prepare(fs, 2, block);
        std::vector<float> input(size_t(block) * 2), output(input.size()), mono(size_t(block), 0.f);
        std::mt19937 rng(7);
        std::uniform_real_distribution<float> noise(-0.5f, 0.5f);
        for (auto& x : input) x = noise(rng);
        std::vector<double> timings;
        timings.reserve(iterations);
        for (int i = -128; i < iterations; ++i) {
          if (i >= 0 && i % 200 == 0) {
            p.eq.bands[3].gainDb = double((i / 200) % 12) - 6.0;
            e.publish(); // control work is timed separately by --control
          }
          const auto begin = Clock::now();
          e.processInterleaved(input.data(), output.data(), 2, block);
          const double us = std::chrono::duration<double, std::micro>(Clock::now() - begin).count();
          if (i >= 0) timings.push_back(us);
          // Keep the feed live, as when the UI consumes it. Otherwise the
          // queue fills and this benchmark silently stops measuring downmix.
          e.analyzerFeed().pop(mono.data(), mono.size());
        }
        std::sort(timings.begin(), timings.end());
        std::printf("%s %g Hz/%d frames: p50 %.2f, p95 %.2f, p99 %.2f, max %.2f us; budget %.2f us\n",
                    shaker ? "shaker" : "classic", fs, block, timings[iterations / 2],
                    timings[iterations * 95 / 100], timings[iterations * 99 / 100], timings.back(),
                    1e6 * block / fs);
      }
    }
  }
}

}  // namespace

int main(int argc, char** argv) {
  if (argc > 1) {
    const std::string_view mode(argv[1]);
    if (mode == "--control") controlBenchmark();
    else if (mode == "--limiter") limiterBenchmark();
    else if (mode == "--callbacks") callbackBenchmark();
    else {
      std::fprintf(stderr, "Usage: punch_bench [--control|--limiter|--callbacks]\n");
      return 2;
    }
    return 0;
  }
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
  const auto input = buf;
  std::vector<float> feed(block);

  const int seconds = 60;
  const int iters = int(seconds * fs / block);
  const auto t0 = std::chrono::steady_clock::now();
  for (int i = 0; i < iters; ++i) {
    if (i % 200 == 0) {  // simulate a user dragging a band
      e.edit().eq.bands[3].gainDb = float((i / 200) % 12) - 6.f;
      e.publish();
    }
    e.processInterleaved(input.data(), buf.data(), 2, block);
    e.analyzerFeed().pop(feed.data(), feed.size());
  }
  const double secs = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  std::printf("16-band EQ + bass + width + crossfeed + limiter, stereo 48k, block %d\n", block);
  std::printf("%d s of audio in %.3f s  ->  %.3f%% of one core (%.1f us per block, budget %.0f us)\n", seconds, secs,
              100.0 * secs / seconds, 1e6 * secs / iters, 1e6 * block / fs);

  // Analysis (meant for the analyzer-feed thread, mono, same rate).
  punch::TempoTracker tempo;
  punch::BassPitchTracker pitch;
  tempo.prepare(fs);
  pitch.prepare(fs);
  std::vector<float> mono(block);
  for (int i = 0; i < block; ++i) mono[size_t(i)] = buf[size_t(2 * i)];
  const auto t1 = std::chrono::steady_clock::now();
  for (int i = 0; i < iters; ++i) tempo.process(mono.data(), block);
  const auto t2 = std::chrono::steady_clock::now();
  for (int i = 0; i < iters; ++i) pitch.process(mono.data(), block);
  const auto t3 = std::chrono::steady_clock::now();
  const double tSecs = std::chrono::duration<double>(t2 - t1).count();
  const double pSecs = std::chrono::duration<double>(t3 - t2).count();
  std::printf("TempoTracker mono 48k: %.3f%% of one core; BassPitchTracker: %.3f%%\n", 100.0 * tSecs / seconds,
              100.0 * pSecs / seconds);
  return 0;
}
