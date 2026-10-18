// Focused UI interpolation check against the same transfer evaluator as audio.
// clang++ -std=c++20 -O2 -I core/include mac/scripts/eq-response-check.cpp -o /tmp/eq-response-check
#include "punch/svf.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <vector>

int main() {
  constexpr std::array<int, 3> counts{1024, 2048, 4096};
  constexpr int denseCount = 65537;
  constexpr double maxErrorDb = 0.15;
  struct Worst { double error = 0, rate = 0, center = 0, frequency = 0, q = 0; int type = 0; };
  std::array<Worst, counts.size()> worst{};
  for (double rate : {44100.0, 48000.0, 96000.0}) {
    for (auto type : {punch::FilterType::Bell, punch::FilterType::LowShelf, punch::FilterType::HighShelf}) {
      for (double center : {80.0, 997.0, 8000.0, 16000.0, 18000.0, 18500.0, 19300.0, 19700.0, 19900.0, 20000.0}) {
        for (double gain : {-12.0, 12.0}) {
          for (double q : {1.0, 6.0, 20.0}) {
            const auto coeff = punch::SvfCoeffs::make({type, center, gain, q, true}, rate);
            std::array<std::vector<double>, counts.size()> grid;
            for (size_t ci = 0; ci < counts.size(); ++ci) {
              const int count = std::min(16384, int(std::ceil(counts[ci] * std::max(1.0, q / 6))));
              grid[ci].resize(size_t(count));
              for (int i = 0; i < count; ++i) {
                const double hz = 20 * std::pow(1000.0, double(i) / (count - 1));
                grid[ci][size_t(i)] = coeff.magnitudeDb(hz, rate);
              }
            }
            for (int i = 0; i < denseCount; ++i) {
              const double u = double(i) / (denseCount - 1);
              const double hz = 20 * std::pow(1000.0, u);
              const double exact = coeff.magnitudeDb(hz, rate);
              for (size_t ci = 0; ci < counts.size(); ++ci) {
                const double t = u * (grid[ci].size() - 1);
                const size_t left = size_t(t), right = std::min(left + 1, grid[ci].size() - 1);
                const double drawn = grid[ci][left] + (grid[ci][right] - grid[ci][left]) * (t - left);
                const double error = std::abs(exact - drawn);
                if (error > worst[ci].error) worst[ci] = {error, rate, center, hz, q, int(type)};
              }
            }
          }
        }
      }
    }
  }
  for (size_t ci = 0; ci < counts.size(); ++ci) {
    const auto& w = worst[ci];
    std::printf("%d base samples, Q-scaled: worst %.6f dB; fs %.0f, type %d, Q %.0f, center %.0f Hz, evaluated %.2f Hz\n",
                counts[ci], w.error, w.rate, w.type, w.q, w.center, w.frequency);
  }
  if (worst.back().error > maxErrorDb) {
    std::fprintf(stderr, "4096-point graph exceeds %.2f dB interpolation budget\n", maxErrorDb);
    return 1;
  }
  std::puts("PASS: per-band Q1/Q6/Q20 bell/shelf interpolation at 44.1/48/96 kHz stays within 0.15 dB.");
}
