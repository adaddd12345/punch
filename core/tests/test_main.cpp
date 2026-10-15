// Self-contained test runner (no third-party deps so it builds anywhere).
#include <algorithm>
#include <atomic>
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <limits>
#include <new>
#include <numbers>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "punch/analysis.hpp"
#include "punch/autoeq.hpp"
#include "punch/character.hpp"
#include "punch/engine.hpp"
#include "punch/flavor.hpp"
#include "punch/fx.hpp"
#include "punch/lockfree.hpp"
#include "punch/punch_c.h"
#include "punch/svf.hpp"

// ---------------------------------------------------------------------------
// Allocation tracker: proves the audio path never touches the heap.
static std::atomic<bool> g_trackAllocs{false};
static std::atomic<int> g_allocCount{0};
void* operator new(std::size_t n) {
  if (g_trackAllocs.load(std::memory_order_relaxed)) g_allocCount.fetch_add(1);
  if (void* p = std::malloc(n ? n : 1)) return p;
  throw std::bad_alloc();
}
void operator delete(void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }

// ---------------------------------------------------------------------------
static int g_failures = 0;
static int g_checks = 0;
#define CHECK(cond)                                                              \
  do {                                                                           \
    ++g_checks;                                                                  \
    if (!(cond)) {                                                               \
      ++g_failures;                                                              \
      std::printf("  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);              \
    }                                                                            \
  } while (0)
#define CHECK_NEAR(a, b, tol)                                                    \
  do {                                                                           \
    ++g_checks;                                                                  \
    const double va_ = (a), vb_ = (b);                                           \
    if (!(std::fabs(va_ - vb_) <= (tol))) {                                      \
      ++g_failures;                                                              \
      std::printf("  FAIL %s:%d: %s = %g, expected %g (tol %g)\n", __FILE__,     \
                  __LINE__, #a, va_, vb_, double(tol));                          \
    }                                                                            \
  } while (0)

struct TestCase { const char* name; std::function<void()> fn; };
static std::vector<TestCase>& registry() { static std::vector<TestCase> r; return r; }
struct Registrar { Registrar(const char* n, std::function<void()> f) { registry().push_back({n, std::move(f)}); } };
#define TEST(name) static void name(); static Registrar reg_##name(#name, name); static void name()

using namespace punch;

// Measures steady-state gain (dB) of a mono processor at `hz`.
template <typename Fn>
static double measureGainDb(double hz, double fs, Fn&& process) {
  const int n = int(fs);  // 1 s
  std::vector<float> x(size_t(n), 0.f);
  for (int i = 0; i < n; ++i) x[size_t(i)] = 0.25f * float(std::sin(2.0 * std::numbers::pi * hz * i / fs));
  process(x.data(), n);
  // RMS over the last half (after transients).
  double in2 = 0, out2 = 0;
  for (int i = n / 2; i < n; ++i) {
    const double s = 0.25 * std::sin(2.0 * std::numbers::pi * hz * i / fs);
    in2 += s * s;
    out2 += double(x[size_t(i)]) * double(x[size_t(i)]);
  }
  return 10.0 * std::log10(out2 / in2);
}

// ---------------------------------------------------------------------------
TEST(svf_bell_hits_gain_at_center) {
  for (double fs : {44100.0, 48000.0, 96000.0}) {
    for (double g : {-12.0, -3.0, 6.0, 12.0}) {
      const auto c = SvfCoeffs::make({FilterType::Bell, 1000, g, 1.4, true}, fs);
      CHECK_NEAR(c.magnitudeDb(1000, fs), g, 1e-6);
      CHECK_NEAR(c.magnitudeDb(20, fs), 0.0, 0.05);
    }
  }
}

TEST(svf_shelves_and_cuts_asymptotes) {
  const double fs = 48000;
  const auto ls = SvfCoeffs::make({FilterType::LowShelf, 200, 8, 0.7071, true}, fs);
  CHECK_NEAR(ls.magnitudeDb(10, fs), 8.0, 0.05);
  CHECK_NEAR(ls.magnitudeDb(200, fs), 4.0, 0.01);  // half gain at fc
  CHECK_NEAR(ls.magnitudeDb(15000, fs), 0.0, 0.05);
  const auto hs = SvfCoeffs::make({FilterType::HighShelf, 5000, -6, 0.7071, true}, fs);
  CHECK_NEAR(hs.magnitudeDb(20000, fs), -6.0, 0.2);
  CHECK_NEAR(hs.magnitudeDb(5000, fs), -3.0, 0.01);
  CHECK_NEAR(hs.magnitudeDb(30, fs), 0.0, 0.01);
  const auto lp = SvfCoeffs::make({FilterType::LowPass, 1000, 0, 0.7071, true}, fs);
  CHECK_NEAR(lp.magnitudeDb(1000, fs), -3.0103, 0.01);
  const auto hp = SvfCoeffs::make({FilterType::HighPass, 1000, 0, 0.7071, true}, fs);
  CHECK_NEAR(hp.magnitudeDb(1000, fs), -3.0103, 0.01);
  CHECK(hp.magnitudeDb(100, fs) < -39.0);
  const auto no = SvfCoeffs::make({FilterType::Notch, 1000, 0, 4, true}, fs);
  CHECK(no.magnitudeDb(1000, fs) < -100.0);
}

// The analytic magnitude used for the UI and auto-preamp must match what
// the sample-domain filter actually does.
TEST(svf_measured_matches_analytic) {
  struct Case { FilterSpec spec; double fs; double hz; };
  const Case cases[] = {
      {{FilterType::Bell, 1000, 9, 2.0, true}, 48000, 1000},
      {{FilterType::Bell, 1000, 9, 2.0, true}, 48000, 1300},
      {{FilterType::LowShelf, 80, 10, 0.7, true}, 96000, 40},   // low fc @ high fs in float
      {{FilterType::HighShelf, 8000, -7, 0.7, true}, 44100, 15000},
      {{FilterType::LowPass, 18000, 0, 0.9, true}, 44100, 19000},  // near Nyquist
      {{FilterType::HighPass, 30, 0, 0.7071, true}, 96000, 25},
  };
  for (const auto& tc : cases) {
    const auto c = SvfCoeffs::make(tc.spec, tc.fs);
    SvfState st;
    const double measured = measureGainDb(tc.hz, tc.fs, [&](float* x, int n) {
      for (int i = 0; i < n; ++i) x[i] = st.tick(c, x[i]);
    });
    CHECK_NEAR(measured, c.magnitudeDb(tc.hz, tc.fs), 0.05);
  }
}

TEST(eq_auto_preamp_prevents_clipping) {
  Engine e;
  e.edit().eq.numBands = 2;
  e.edit().eq.bands[0] = {FilterType::Bell, 100, 12, 1.0, true};
  e.edit().eq.bands[1] = {FilterType::Bell, 150, 6, 1.0, true};
  e.edit().autoPreamp = true;
  e.edit().limiter.enabled = false;
  e.prepare(48000, 2, 512);
  CHECK(e.effectivePreampDb() < -12.0);
  // Full-scale sine at the combined response peak.
  const double fs = 48000;
  double peakHz = 100, best = -1e9;
  for (double hz = 60; hz < 250; hz += 0.5) {
    const double db = eqResponseDb(e.pending().eq, fs, hz);
    if (db > best) { best = db; peakHz = hz; }
  }
  const int n = 48000;
  std::vector<float> buf(size_t(n) * 2);
  for (int i = 0; i < n; ++i)
    buf[size_t(i) * 2] = buf[size_t(i) * 2 + 1] = float(std::sin(2 * std::numbers::pi * peakHz * i / fs));
  e.processInterleaved(buf.data(), buf.data(), 2, n);
  float peak = 0;
  for (int i = n / 2; i < n; ++i) peak = std::max(peak, std::fabs(buf[size_t(i) * 2]));
  CHECK(peak <= 1.001f);
  CHECK(peak > 0.97f);  // and we didn't over-attenuate
}

TEST(eq_glide_is_smooth_and_converges) {
  ParametricEq eq;
  const double fs = 48000;
  eq.prepare(fs, 1);
  EqParams p;
  p.numBands = 1;
  p.bands[0] = {FilterType::Bell, 200, 0, 1.0, true};
  eq.setParams(p);
  eq.snapToTargets();
  // Abrupt +15 dB / 10x frequency jump while a sine plays.
  const int n = 48000;
  std::vector<float> x(size_t(n), 0.f);
  for (int i = 0; i < n; ++i) x[size_t(i)] = 0.5f * float(std::sin(2 * std::numbers::pi * 1000 * i / fs));
  float* ch[1] = {x.data()};
  eq.process(ch, 1, 4800);
  p.bands[0] = {FilterType::Bell, 2000, 15, 4.0, true};
  eq.setParams(p);
  eq.process(ch, 1, n);  // re-process a fresh second (state continuous)
  float maxStep = 0;
  for (int i = 1; i < n; ++i) maxStep = std::max(maxStep, std::fabs(x[size_t(i)] - x[size_t(i - 1)]));
  CHECK(std::isfinite(maxStep));
  CHECK(maxStep < 0.35f);  // a 1 kHz sine at 0.5..2.8 amplitude steps <= ~0.37/sample at 48k
  // Converged: response at 1 kHz now matches target.
  ParametricEq ref;
  SvfState st;
  const auto target = SvfCoeffs::make(p.bands[0], fs);
  const double measured = measureGainDb(1000, fs, [&](float* y, int m) {
    float* c1[1] = {y};
    eq.process(c1, 1, m);
  });
  (void)ref; (void)st;
  CHECK_NEAR(measured, target.magnitudeDb(1000, fs), 0.05);
}

TEST(eq_disable_band_fades_to_flat) {
  ParametricEq eq;
  const double fs = 48000;
  eq.prepare(fs, 1);
  EqParams p;
  p.numBands = 1;
  p.bands[0] = {FilterType::Bell, 1000, 10, 1.0, true};
  eq.setParams(p);
  eq.snapToTargets();
  p.bands[0].enabled = false;
  eq.setParams(p);
  const double measured = measureGainDb(1000, fs, [&](float* y, int m) {
    float* c1[1] = {y};
    eq.process(c1, 1, m);
  });
  CHECK_NEAR(measured, 0.0, 0.01);
}

TEST(limiter_never_exceeds_ceiling) {
  Limiter lim;
  const double fs = 48000;
  lim.prepare(fs, 2);
  LimiterParams lp;
  lp.ceilingDb = -1.0f;
  lim.setParams(lp);
  std::mt19937 rng(1234);
  std::normal_distribution<float> nd(0.f, 1.f);
  const int n = 48000 * 3;
  std::vector<float> l(size_t(n), 0.f), r(size_t(n), 0.f);
  for (int i = 0; i < n; ++i) {
    // Bursty program material up to ~+18 dBFS peaks with sudden transients.
    const float env = (i / 4000) % 3 == 0 ? 4.f : 0.3f;
    l[size_t(i)] = env * nd(rng);
    r[size_t(i)] = env * nd(rng) * 0.5f;
  }
  float* ch[2] = {l.data(), r.data()};
  for (int s = 0; s < n; s += 257) lim.process(ch, 2, std::min(257, n - s)), ch[0] += 257, ch[1] += 257;
  const float ceiling = dbToGain(-1.f);
  float peak = 0;
  for (int i = 0; i < n; ++i) peak = std::max({peak, std::fabs(l[size_t(i)]), std::fabs(r[size_t(i)])});
  CHECK(peak <= ceiling * 1.00001f);
  CHECK(peak > ceiling * 0.95f);
}

TEST(limiter_is_transparent_below_ceiling) {
  Limiter lim;
  lim.prepare(48000, 1);
  const int L = lim.latencyFrames();
  CHECK(L == 72);
  const int n = 4096;
  std::vector<float> x(size_t(n), 0.f), y;
  for (int i = 0; i < n; ++i) x[size_t(i)] = 0.5f * float(std::sin(i * 0.05));
  y = x;
  float* ch[1] = {y.data()};
  lim.process(ch, 1, n);
  for (int i = L; i < n; ++i) CHECK(y[size_t(i)] == x[size_t(i - L)]);
  CHECK(lim.gainReductionDb() == 0.f);
}

TEST(bass_enhancer_adds_harmonics) {
  BassEnhancer be;
  const double fs = 48000;
  be.prepare(fs, 1);
  be.setParams({1.0f, 120.f, 4.f, true});
  const int n = 48000;
  std::vector<float> x(size_t(n), 0.f);
  for (int i = 0; i < n; ++i) x[size_t(i)] = 0.3f * float(std::sin(2 * std::numbers::pi * 50 * i / fs));
  float* ch[1] = {x.data()};
  be.process(ch, 1, n);
  // Goertzel-style correlation at 100/150 Hz over the last half.
  auto energyAt = [&](double hz) {
    double re = 0, im = 0;
    for (int i = n / 2; i < n; ++i) {
      re += x[size_t(i)] * std::cos(2 * std::numbers::pi * hz * i / fs);
      im += x[size_t(i)] * std::sin(2 * std::numbers::pi * hz * i / fs);
    }
    return std::sqrt(re * re + im * im) / (n / 2);
  };
  CHECK(energyAt(100) > 0.005 || energyAt(150) > 0.005);
  CHECK(energyAt(50) > 0.12);  // fundamental preserved
}

TEST(stereo_width_zero_is_mono) {
  StereoWidener w;
  w.prepare(48000);
  w.setParams({0.f, 180.f, true});
  std::vector<float> l(2048), r(2048);
  float* ch[2] = {l.data(), r.data()};
  for (int blk = 0; blk < 12; ++blk) {  // ~0.5 s: smoother fully lands on target
    for (int i = 0; i < 2048; ++i) {
      const int t = blk * 2048 + i;
      l[size_t(i)] = float(std::sin(t * 0.1));
      r[size_t(i)] = float(std::cos(t * 0.07));
    }
    w.process(ch, 2, 2048);
  }
  for (int i = 0; i < 2048; ++i) CHECK_NEAR(l[size_t(i)], r[size_t(i)], 1e-6);
}

TEST(engine_bypass_is_neutral) {
  Engine e;
  e.edit().eq.numBands = 1;
  e.edit().eq.bands[0] = {FilterType::Bell, 1000, 9, 1.0, true};
  e.edit().bass = {0.8f, 120.f, 4.f, true};
  e.edit().stereo = {1.6f, 180.f, true};
  e.edit().outputGainDb = 6.f;
  e.prepare(48000, 2, 512);
  e.edit().bypass = true;
  e.publish();
  const int n = 48000;
  std::vector<float> in(size_t(n) * 2), out(size_t(n) * 2);
  for (int i = 0; i < n; ++i) {
    in[size_t(i) * 2] = 0.3f * float(std::sin(i * 0.031));
    in[size_t(i) * 2 + 1] = 0.3f * float(std::sin(i * 0.017));
  }
  for (int s = 0; s < n; s += 512) e.processInterleaved(&in[size_t(s) * 2], &out[size_t(s) * 2], 2, std::min(512, n - s));
  const int L = e.latencyFrames();
  double maxErr = 0;
  for (int i = n / 2; i < n; ++i)
    for (int c = 0; c < 2; ++c)
      maxErr = std::max(maxErr, double(std::fabs(out[size_t(i) * 2 + size_t(c)] - in[size_t(i - L) * 2 + size_t(c)])));
  CHECK(maxErr < 1e-4);
}

// Boost leveler: +12 dB on a loud master (Limit off, safety-net limiter)
// only uses the headroom there is, so the kicks don't pump the mix; a
// quiet track gets the whole Boost.
static std::vector<double> levelerRun(bool leveler, float amp, bool kicks, double* peakOut) {
  Engine e;
  e.edit().autoPreamp = false;
  e.edit().outputGainDb = 12.f;
  e.edit().boostLeveler = leveler;
  e.edit().limiter = {-1.f, 80.f, true, 600.f, 1.f, 0.f};
  e.prepare(48000, 2, 512);
  const int fs = 48000, n = fs * 6, beat = fs / 2, kick = fs / 10;
  std::vector<float> buf(size_t(n) * 2);
  for (int i = 0; i < n; ++i) {
    const double t = double(i) / fs;
    double x = amp * std::sin(2.0 * std::numbers::pi * 1000.0 * t);
    if (kicks && i % beat < kick) x += 0.5 * std::sin(2.0 * std::numbers::pi * 60.0 * t) * (1.0 - double(i % beat) / kick);
    buf[size_t(i) * 2] = buf[size_t(i) * 2 + 1] = float(x);
  }
  for (int s = 0; s < n; s += 512) e.processInterleaved(&buf[size_t(s) * 2], &buf[size_t(s) * 2], 2, std::min(512, n - s));
  const int L = e.latencyFrames();
  double peak = 0;
  for (int i = 2 * fs; i < n; ++i) peak = std::max(peak, double(std::fabs(buf[size_t(i) * 2])));
  *peakOut = peak;
  // Gain (dB) on the 1 kHz tone (quadrature demodulation, 20 ms windows),
  // through the kicks and between them, after 2 s.
  std::vector<double> gains;
  const int win = fs / 50;
  for (int w = 2 * fs; w + win <= n; w += win) {
    double re = 0, im = 0;
    for (int i = w; i < w + win; ++i) {
      const double ph = 2.0 * std::numbers::pi * 1000.0 * double(i - L) / fs;
      re += double(buf[size_t(i) * 2]) * std::sin(ph);
      im += double(buf[size_t(i) * 2]) * std::cos(ph);
    }
    gains.push_back(20.0 * std::log10(2.0 * std::hypot(re, im) / win / amp));
  }
  return gains;
}

TEST(engine_boost_leveler) {
  const double ceiling = std::pow(10.0, -1.0 / 20.0);
  for (bool lev : {false, true}) {
    double peak = 0;
    const auto g = levelerRun(lev, 0.5f, true, &peak);
    const double lo = *std::min_element(g.begin(), g.end()), hi = *std::max_element(g.begin(), g.end());
    std::printf("  loud +12 dB, leveler %d: tone gain %.1f..%.1f dB, peak %.3f\n", int(lev), lo, hi, peak);
    CHECK(peak <= ceiling + 1e-4);
    if (lev) {
      CHECK(hi - lo < 2.5);  // the kicks barely duck the rest of the mix
      CHECK(lo > -1.5);      // and it never drops far below the original level
    }
  }
  double peak = 0;
  const auto q = levelerRun(true, 0.03f, false, &peak);
  for (double v : q) CHECK_NEAR(v, 12.0, 0.3);  // quiet: the whole Boost
}

TEST(engine_output_rms_meter) {
  Engine e;
  e.edit().limiter.enabled = false;
  e.prepare(48000, 2, 512);
  const int n = 48000;
  std::vector<float> buf(size_t(n) * 2);
  for (int i = 0; i < n; ++i)
    buf[size_t(i) * 2] = buf[size_t(i) * 2 + 1] = 0.5f * float(std::sin(2.0 * std::numbers::pi * 1000.0 * i / 48000.0));
  for (int s = 0; s < n; s += 512) e.processInterleaved(&buf[size_t(s) * 2], &buf[size_t(s) * 2], 2, std::min(512, n - s));
  double ms = 0;
  const int tail = 4800;  // last 100 ms of the output
  for (int i = n - tail; i < n; ++i) ms += double(buf[size_t(i) * 2]) * double(buf[size_t(i) * 2]);
  const double measured = std::sqrt(ms / tail);
  const Meters m = e.takeMeters();
  CHECK(measured > 0.1);
  CHECK(std::fabs(double(m.outRms[0]) - measured) < 0.05 * measured);
  CHECK(std::fabs(double(m.outRms[1]) - measured) < 0.05 * measured);
  // A level, not an accumulator: reading it again does not reset it.
  CHECK(e.takeMeters().outRms[0] == m.outRms[0]);

  std::fill(buf.begin(), buf.end(), 0.f);
  for (int s = 0; s < n; s += 512) e.processInterleaved(&buf[size_t(s) * 2], &buf[size_t(s) * 2], 2, std::min(512, n - s));
  const Meters z = e.takeMeters();
  CHECK(z.outRms[0] < 1e-3f);
  CHECK(z.outRms[1] < 1e-3f);
}

TEST(engine_process_is_allocation_free) {
  Engine e;
  e.edit().eq.numBands = 10;
  for (int i = 0; i < 10; ++i) e.edit().eq.bands[size_t(i)] = {FilterType::Bell, 31.25 * std::pow(2.0, i), 3.0, 1.4, true};
  e.edit().bass.enabled = true;
  e.edit().stereo.enabled = true;
  e.edit().crossfeed.enabled = true;
  e.edit().compressor.enabled = true;
  e.edit().saturator = {12.f, 0.5f, 12000.f, 0.2f, 120.f, true};
  e.edit().ambience = {0.3f, 0.5f, 7000.f, true};
  e.edit().noise = {NoiseColor::Pink, -40.f, true};
  e.edit().dj = {true, false, false, -0.5f, true, true, true};
  e.edit().guard = {8.f, 20.f, true};
  e.edit().bassCharacter = {BassCharacterKind::Distort, 0.7f, 1.f};
  e.edit().lateNight = {true, 0.5f};
  e.prepare(48000, 2, 1024);
  std::vector<float> buf(2048 * 2, 0.1f);
  e.edit().eq.bands[3].gainDb = -4;
  e.publish();  // control thread work happens before tracking
  g_allocCount = 0;
  g_trackAllocs = true;
  for (int k = 0; k < 50; ++k) e.processInterleaved(buf.data(), buf.data(), 2, 2048);  // > maxFrames: chunks
  (void)e.takeMeters();
  g_trackAllocs = false;
  CHECK(g_allocCount.load() == 0);
  // The Bass Shaker path too.
  e.edit().bass.amount = 0.8f;
  e.edit().bassShaker = true;
  e.publish();
  g_allocCount = 0;
  g_trackAllocs = true;
  for (int k = 0; k < 50; ++k) e.processInterleaved(buf.data(), buf.data(), 2, 2048);
  g_trackAllocs = false;
  CHECK(g_allocCount.load() == 0);
}

TEST(triple_buffer_threaded) {
  struct Snap { int a; int b; int c; };
  TripleBuffer<Snap> tb(Snap{0, 0, 0});
  std::atomic<bool> done{false};
  std::thread writer([&] {
    for (int i = 1; i <= 200000; ++i) tb.write(Snap{i, -i, i * 2});
    done = true;
  });
  int last = 0;
  bool consistent = true, monotonic = true;
  Snap s{0, 0, 0};
  while (!done.load()) {
    tb.read(s);
    if (s.b != -s.a || s.c != 2 * s.a) consistent = false;
    if (s.a < last) monotonic = false;
    last = s.a;
  }
  writer.join();
  tb.read(s);
  CHECK(consistent);
  CHECK(monotonic);
  CHECK(s.a == 200000);
}

TEST(spsc_ring_threaded) {
  SpscRing<int> ring(1000);
  constexpr int kTotal = 500000;
  std::thread producer([&] {
    int next = 0;
    while (next < kTotal) {
      int chunk[37];
      int n = 0;
      for (; n < 37 && next + n < kTotal; ++n) chunk[n] = next + n;
      next += int(ring.push(chunk, size_t(n)));
    }
  });
  int expected = 0;
  bool ordered = true;
  while (expected < kTotal) {
    int out[64];
    const size_t n = ring.pop(out, 64);
    for (size_t i = 0; i < n; ++i) ordered &= out[i] == expected++;
  }
  producer.join();
  CHECK(ordered);
}

TEST(autoeq_parse_and_roundtrip) {
  const char* txt =
      "Preamp: -6.2 dB\r\n"
      "Filter 1: ON LSC Fc 105 Hz Gain 6.5 dB Q 0.70\n"
      "Filter 2: ON PK Fc 2363 Hz Gain 3.2 dB Q 2.12\n"
      "# comment\n"
      "Filter 3: OFF HSC Fc 10000 Hz Gain -2.1 dB Q 0.70\n"
      "Filter 4: ON XX Fc 10 Hz Gain 1 dB Q 1\n"
      "Filter: ON PK Fc 500 Hz Gain -1 dB BW Oct 1.0\n";
  const auto r = parseEqualizerApo(txt);
  CHECK(r.ok());
  CHECK(r.params.numBands == 4);
  CHECK(r.skippedLines == 1);
  CHECK_NEAR(r.params.preampDb, -6.2, 1e-6);
  CHECK(r.params.bands[0].type == FilterType::LowShelf);
  CHECK_NEAR(r.params.bands[1].freqHz, 2363, 1e-9);
  CHECK_NEAR(r.params.bands[1].q, 2.12, 1e-9);
  CHECK(!r.params.bands[2].enabled);
  CHECK_NEAR(r.params.bands[3].q, 1.4142, 1e-3);  // 1 octave
  const auto again = parseEqualizerApo(formatEqualizerApo(r.params));
  CHECK(again.params.numBands == 4);
  for (int i = 0; i < 4; ++i) {
    CHECK(again.params.bands[size_t(i)].type == r.params.bands[size_t(i)].type);
    CHECK_NEAR(again.params.bands[size_t(i)].gainDb, r.params.bands[size_t(i)].gainDb, 0.05);
  }
}

TEST(engine_survives_hostile_input) {
  Engine e;
  e.edit().eq.numBands = 1;
  e.edit().eq.bands[0] = {FilterType::Bell, 1e9, 1e3, -5, true};  // clamped
  e.prepare(44100, 2, 256);
  std::vector<float> buf(256 * 2, 0.f);
  buf[0] = 1e6f;  // absurd spike
  e.processInterleaved(buf.data(), buf.data(), 2, 256);
  for (int k = 0; k < 20; ++k) e.processInterleaved(buf.data(), buf.data(), 2, 256);
  bool finite = true;
  for (float v : buf) finite &= std::isfinite(v) && std::fabs(v) <= 1.f;
  CHECK(finite);
}

TEST(compressor_static_curve) {
  CHECK_NEAR(Compressor::computeGainDb(-30, -18, 4, 6), 0.0, 1e-6);       // below knee
  CHECK_NEAR(Compressor::computeGainDb(-6, -18, 4, 6), -9.0, 1e-4);       // 12 dB over at 4:1
  CHECK_NEAR(Compressor::computeGainDb(-18, -18, 4, 6), -0.5625, 1e-4);   // mid-knee
  CHECK(Compressor::computeGainDb(-17, -18, 4, 0) < 0.f);
}

TEST(compressor_reduces_loud_signal) {
  Compressor c;
  c.prepare(48000);
  c.setParams({-20.f, 4.f, 5.f, 100.f, 0.f, 0.f, 0.f, true});
  std::vector<float> x(48000);
  for (int i = 0; i < 48000; ++i) x[size_t(i)] = 0.5f * float(std::sin(i * 0.05));  // ~-6 dBFS peak
  float* ch[1] = {x.data()};
  c.process(ch, 1, 48000);
  float peak = 0;
  for (int i = 24000; i < 48000; ++i) peak = std::max(peak, std::fabs(x[size_t(i)]));
  // 14 dB over threshold at 4:1 -> ~10.5 dB reduction (peak detector, some ripple).
  CHECK(20 * std::log10(peak) < -14.0);
  CHECK(c.gainReductionDb() < -8.f);
}

TEST(saturator_adds_harmonics_and_stays_bounded) {
  Saturator s;
  const double fs = 48000;
  s.prepare(fs, 1);
  s.setParams({18.f, 1.f, 16000.f, 0.3f, 0.f, true});
  const int n = 48000;
  std::vector<float> x(size_t(n), 0.f);
  for (int i = 0; i < n; ++i) x[size_t(i)] = 0.5f * float(std::sin(2 * std::numbers::pi * 200 * i / fs));
  float* ch[1] = {x.data()};
  s.process(ch, 1, n);
  auto mag = [&](double hz) {
    double re = 0, im = 0;
    for (int i = n / 2; i < n; ++i) { re += x[size_t(i)] * std::cos(2 * std::numbers::pi * hz * i / fs); im += x[size_t(i)] * std::sin(2 * std::numbers::pi * hz * i / fs); }
    return std::sqrt(re * re + im * im) / (n / 2);
  };
  CHECK(mag(400) > 0.01);  // even harmonic from asymmetry
  CHECK(mag(600) > 0.01);  // odd harmonic
  bool ok = true;
  for (float v : x) ok &= std::isfinite(v) && std::fabs(v) < 1.6f;
  CHECK(ok);
}

TEST(saturator_off_is_transparent) {
  Saturator s;
  s.prepare(48000, 1);
  s.setParams({18.f, 1.f, 16000.f, 0.3f, 0.f, false});
  std::vector<float> x(1024), y;
  for (int i = 0; i < 1024; ++i) x[size_t(i)] = float(std::sin(i * 0.1));
  y = x;
  float* ch[1] = {y.data()};
  s.process(ch, 1, 1024);
  for (int i = 0; i < 1024; ++i) CHECK(y[size_t(i)] == x[size_t(i)]);
}

TEST(noise_level_matches_request) {
  for (int color = 0; color < 3; ++color) {
    NoiseBed nb;
    nb.prepare(48000);
    nb.setParams({static_cast<NoiseColor>(color), -30.f, true});
    std::vector<float> l(96000, 0.f), r(96000, 0.f);
    float* ch[2] = {l.data(), r.data()};
    nb.process(ch, 2, 96000);
    double acc = 0, corr = 0;
    for (int i = 48000; i < 96000; ++i) { acc += double(l[size_t(i)]) * l[size_t(i)]; corr += double(l[size_t(i)]) * r[size_t(i)]; }
    const double rmsDb = 10 * std::log10(acc / 48000);
    CHECK_NEAR(rmsDb, -30.0, 1.5);
    CHECK(std::fabs(corr / acc) < 0.2);  // decorrelated stereo
  }
}

TEST(ambience_tail_decays) {
  Ambience a;
  a.prepare(48000);
  a.setParams({1.f, 0.6f, 7000.f, true});
  std::vector<float> l(48000, 0.f), r(48000, 0.f);
  l[0] = r[0] = 1.f;
  float* ch[2] = {l.data(), r.data()};
  a.process(ch, 2, 48000);
  double early = 0, late = 0;
  for (int i = 100; i < 4800; ++i) early += double(l[size_t(i)]) * l[size_t(i)];
  for (int i = 24000; i < 48000; ++i) late += double(l[size_t(i)]) * l[size_t(i)];
  CHECK(early > 1e-3);            // reflections present
  CHECK(late < early * 1e-6);     // and gone after 0.5 s
}

TEST(saturator_split_band_keeps_sub_clean) {
  Saturator s;
  const double fs = 48000;
  s.prepare(fs, 1);
  s.setParams({24.f, 1.f, 16000.f, 0.0f, 120.f, true});
  const int n = 48000;
  std::vector<float> x(size_t(n), 0.f);
  for (int i = 0; i < n; ++i) x[size_t(i)] = 0.5f * float(std::sin(2 * std::numbers::pi * 40 * i / fs));
  float* ch[1] = {x.data()};
  s.process(ch, 1, n);
  auto mag = [&](double hz) {
    double re = 0, im = 0;
    for (int i = n / 2; i < n; ++i) { re += x[size_t(i)] * std::cos(2 * std::numbers::pi * hz * i / fs); im += x[size_t(i)] * std::sin(2 * std::numbers::pi * hz * i / fs); }
    return std::sqrt(re * re + im * im) / (n / 2);
  };
  // A 40 Hz 808-like tone stays essentially intact: barely touched by the highs-only saturator.
  CHECK(mag(40) > 0.2);
  CHECK(mag(120) < 0.03);
}

// ---- bass-priority limiting ("something is fighting the EQ")

static void bassHeavyEngine(Engine& e, bool bassPriority) {
  e.prepare(48000, 2, 512);
  auto& p = e.edit();
  p.eq.numBands = 1;
  p.eq.bands[0] = {FilterType::LowShelf, 100, 10, 0.71, true};
  p.autoPreamp = false;
  p.limiter = {-1.f, 80.f, true, 0.f, 0.f, bassPriority ? 150.f : 0.f};
  e.publish();
}

// Kick-like 50 Hz bursts near full scale plus a steady 1 kHz tone.
static std::vector<float> kickAndTone(int n, double fs) {
  std::vector<float> x(size_t(n), 0.f);
  for (int i = 0; i < n; ++i) {
    const double t = i / fs, tk = std::fmod(t, 0.5);
    x[size_t(i)] = float(0.8 * std::sin(2 * std::numbers::pi * 50 * t) * std::exp(-tk / 0.15) +
                         0.1 * std::sin(2 * std::numbers::pi * 1000 * t));
  }
  return x;
}

static double toneDipDb(const std::vector<float>& y, double fs, int from) {
  SvfCoeffs bp = SvfCoeffs::make({FilterType::BandPass, 1000, 0, 12, true}, fs);
  SvfState s1, s2;
  std::vector<double> env;
  const int w = int(0.01 * fs);
  double acc = 0;
  int k = 0;
  for (size_t i = 0; i < y.size(); ++i) {
    const float v = s2.tick(bp, s1.tick(bp, y[i]));
    if (int(i) < from) continue;
    acc += double(v) * v;
    if (++k == w) { env.push_back(10 * std::log10(acc / w + 1e-20)); acc = 0; k = 0; }
  }
  std::sort(env.begin(), env.end());
  return env[env.size() / 2] - env[env.size() / 50];
}

static std::vector<float> runMono(Engine& e, std::vector<float> x) {
  std::vector<float> r = x;
  for (size_t s = 0; s < x.size(); s += 512) {
    float* p[2] = {x.data() + s, r.data() + s};
    e.processPlanar(p, 2, int(std::min<size_t>(512, x.size() - s)));
  }
  return x;
}

TEST(bass_priority_never_exceeds_ceiling) {
  Engine e;
  bassHeavyEngine(e, true);
  const double fs = 48000;
  std::mt19937 rng(3);
  std::uniform_real_distribution<float> u(-0.2f, 0.2f);
  auto x = kickAndTone(48000 * 3, fs);
  for (auto& v : x) v += u(rng);
  const auto y = runMono(e, x);
  float peak = 0;
  for (float v : y) peak = std::max(peak, std::fabs(v));
  CHECK(peak <= dbToGain(-1.f) + 1e-4f);
}

TEST(bass_priority_does_not_duck_the_mids) {
  const double fs = 48000;
  const auto x = kickAndTone(48000 * 4, fs);
  Engine plain, bp;
  bassHeavyEngine(plain, false);
  bassHeavyEngine(bp, true);
  const double dipPlain = toneDipDb(runMono(plain, x), fs, 48000);
  const double dipBp = toneDipDb(runMono(bp, x), fs, 48000);
  // A full-band limiter pulls the steady tone down on every kick; the
  // bass-priority limiter takes the reduction from the bass alone.
  CHECK(dipPlain > 3.0);
  CHECK(dipBp < 1.0);
}

// ---- Night Guard and DJ effects

static double rmsDbRange(const std::vector<float>& x, size_t a, size_t b) {
  double s = 0;
  for (size_t i = a; i < b; ++i) s += double(x[i]) * x[i];
  return 10 * std::log10(s / double(b - a) + 1e-20);
}

TEST(night_guard_tames_a_loud_title_sequence) {
  // 20 s of quiet "dialogue" (-32 dBFS noise), then 10 s of loud "titles"
  // (-12 dBFS): a 20 dB jump. With an 8 dB allowance, the titles should land
  // no more than ~8-9 dB above the dialogue; the dialogue is untouched.
  const double fs = 48000;
  LoudnessGuard g;
  g.prepare(fs);
  g.setParams({8.f, 20.f, true});
  std::mt19937 rng(11);
  std::normal_distribution<float> nd(0.f, 1.f);
  const size_t n = size_t(30 * fs), loudAt = size_t(20 * fs);
  std::vector<float> l(n), r(n);
  for (size_t i = 0; i < n; ++i) {
    const float a = i < loudAt ? dbToGain(-32.f) : dbToGain(-12.f);
    l[i] = a * nd(rng);
    r[i] = a * nd(rng);
  }
  const std::vector<float> in = l;
  for (size_t s = 0; s < n; s += 512) {
    float* p[2] = {l.data() + s, r.data() + s};
    g.process(p, 2, int(std::min<size_t>(512, n - s)));
  }
  const double quietIn = rmsDbRange(in, size_t(10 * fs), loudAt);
  const double quietOut = rmsDbRange(l, size_t(10 * fs), loudAt);
  const double loudOut = rmsDbRange(l, loudAt + size_t(1 * fs), n);
  CHECK(std::fabs(quietOut - quietIn) < 0.5);
  CHECK(loudOut - quietOut < 9.5);
  CHECK(loudOut - quietOut > 6.0);  // still clearly louder, not flattened
}

TEST(ear_protector_ducks_a_sudden_blast_but_not_music) {
  const double fs = 48000;
  SpikeGuard g;
  g.prepare(fs);
  SpikeGuardParams sp;
  sp.enabled = true;
  g.setParams(sp);
  std::mt19937 rng(5);
  std::normal_distribution<float> nd(0.f, 1.f);
  // 4 s of steady loud-ish music (noise at -16 dBFS RMS): must never trip.
  const size_t n1 = size_t(4 * fs), n2 = size_t(2 * fs);
  std::vector<float> l(n1 + n2), r(n1 + n2);
  for (size_t i = 0; i < n1; ++i) l[i] = r[i] = dbToGain(-40.f) * nd(rng);
  for (size_t i = 0; i < n1; ++i) if (i > size_t(fs)) l[i] = r[i] = dbToGain(-16.f) * nd(rng) * 0.25f;
  // Then a full-scale blast.
  for (size_t i = n1; i < n1 + n2; ++i) l[i] = r[i] = float(std::sin(0.05 * double(i)));
  for (size_t s = 0; s < l.size(); s += 512) {
    float* p[2] = {l.data() + s, r.data() + s};
    g.process(p, 2, int(std::min<size_t>(512, l.size() - s)));
  }
  CHECK(g.events() == 1);
  const double blastOut = rmsDbRange(l, n1 + size_t(0.05 * fs), n1 + size_t(1.5 * fs));
  CHECK(blastOut < -3.0 - 15.0);  // a -3 dBFS RMS sine, cut by ~20 dB
}

TEST(ear_protector_off_is_transparent) {
  SpikeGuard g;
  g.prepare(48000);
  std::vector<float> l(9600, 0.f), r(9600, 0.f);
  for (size_t i = 4800; i < l.size(); ++i) l[i] = r[i] = float(std::sin(0.05 * double(i)));
  const auto ref = l;
  float* p[2] = {l.data(), r.data()};
  g.process(p, 2, int(l.size()));
  CHECK(l == ref);
}

TEST(night_guard_off_is_transparent) {
  LoudnessGuard g;
  g.prepare(48000);
  std::vector<float> l(4800), r(4800);
  for (size_t i = 0; i < l.size(); ++i) l[i] = r[i] = float(std::sin(0.01 * double(i)));
  const auto ref = l;
  float* p[2] = {l.data(), r.data()};
  g.process(p, 2, int(l.size()));
  CHECK(l == ref);
}

TEST(dj_idle_is_bit_exact) {
  DjFx d;
  d.prepare(48000, 2);
  std::vector<float> l(4800), r(4800);
  for (size_t i = 0; i < l.size(); ++i) l[i] = r[i] = float(0.5 * std::sin(0.03 * double(i)));
  const auto ref = l;
  float* p[2] = {l.data(), r.data()};
  d.process(p, 2, int(l.size()));
  CHECK(l == ref);
}

static double toneMag(const std::vector<float>& x, double hz, double fs, size_t from) {
  double re = 0, im = 0;
  for (size_t i = from; i < x.size(); ++i) {
    re += x[i] * std::cos(2 * std::numbers::pi * hz * double(i) / fs);
    im += x[i] * std::sin(2 * std::numbers::pi * hz * double(i) / fs);
  }
  return std::sqrt(re * re + im * im) / double(x.size() - from);
}

TEST(dj_low_kill_removes_bass_keeps_mids) {
  const double fs = 48000;
  DjFx d;
  d.prepare(fs, 2);
  DjParams p;
  p.lowKill = true;
  d.setParams(p);
  const size_t n = size_t(fs);
  std::vector<float> l(n), r(n);
  for (size_t i = 0; i < n; ++i)
    l[i] = r[i] = float(0.4 * std::sin(2 * std::numbers::pi * 50 * double(i) / fs) +
                        0.2 * std::sin(2 * std::numbers::pi * 1000 * double(i) / fs));
  for (size_t s = 0; s < n; s += 512) {
    float* q[2] = {l.data() + s, r.data() + s};
    d.process(q, 2, int(std::min<size_t>(512, n - s)));
  }
  CHECK(toneMag(l, 50, fs, n / 2) < 0.4 / 2 * 0.1);      // > 20 dB down
  CHECK(std::fabs(toneMag(l, 1000, fs, n / 2) - 0.1) < 0.012);  // mids within ~1 dB
}

TEST(dj_lowpass_sweep_cuts_highs) {
  const double fs = 48000;
  DjFx d;
  d.prepare(fs, 2);
  DjParams p;
  p.filter = -0.8f;
  d.setParams(p);
  const size_t n = size_t(fs);
  std::vector<float> l(n), r(n);
  for (size_t i = 0; i < n; ++i) l[i] = r[i] = float(0.3 * std::sin(2 * std::numbers::pi * 8000 * double(i) / fs));
  for (size_t s = 0; s < n; s += 512) {
    float* q[2] = {l.data() + s, r.data() + s};
    d.process(q, 2, int(std::min<size_t>(512, n - s)));
  }
  CHECK(toneMag(l, 8000, fs, n / 2) < 0.15 * 0.05);
}

// ---------------------------------------------------------------------------
// Tempo and bass-pitch analysis.

// Synthetic drum loop: kick on every beat, optional closed hats on the
// off-beat eighths and a snare on 2 and 4.
static std::vector<float> drumLoop(double bpm, double fs, double seconds, bool hats) {
  const int n = int(fs * seconds);
  std::vector<float> x(size_t(n), 0.f);
  std::mt19937 rng(3);
  std::uniform_real_distribution<float> ud(-1.f, 1.f);
  const double beat = 60.0 / bpm;
  float hpPrev = 0.f, hpOut = 0.f;
  for (int i = 0; i < n; ++i) {
    const double t = i / fs;
    const int b = int(t / beat);
    const double tb = t - b * beat;  // time since the beat
    // Kick: pitch-swept sine, 150 -> 50 Hz.
    const double f = 50.0 + 100.0 * std::exp(-tb / 0.02);
    double s = 0.8 * std::sin(2.0 * std::numbers::pi * f * tb) * std::exp(-tb / 0.12);
    const float nz = ud(rng);
    hpOut = 0.9f * (hpOut + nz - hpPrev);  // crude high-pass for hats
    hpPrev = nz;
    if (hats) {
      const double te = std::fmod(t + 0.5 * beat, 0.5 * beat * 2.0);  // off-beat eighth
      if (te < 0.5 * beat) s += 0.25 * hpOut * std::exp(-te / 0.015);
      if (b % 2 == 1) s += 0.35 * nz * std::exp(-tb / 0.06);  // snare on 2 and 4
    }
    x[size_t(i)] = float(s);
  }
  return x;
}

static double runTempo(const std::vector<float>& x, double fs, double* conf) {
  TempoTracker t;
  t.prepare(fs);
  for (size_t i = 0; i < x.size(); i += 512) t.process(x.data() + i, std::min<size_t>(512, x.size() - i));
  *conf = t.confidence();
  return t.bpm();
}

TEST(tempo_120_kick_pattern) {
  double conf = 0;
  const double bpm = runTempo(drumLoop(120.0, 48000, 10.0, false), 48000, &conf);
  std::printf("  120 bpm kick -> %.2f bpm, confidence %.2f\n", bpm, conf);
  CHECK_NEAR(bpm, 120.0, 1.0);  // not 60 or 240
  CHECK(conf > 0.6);
}

TEST(tempo_128_with_hats) {
  for (double fs : {44100.0, 48000.0}) {
    double conf = 0;
    const double bpm = runTempo(drumLoop(128.0, fs, 10.0, true), fs, &conf);
    std::printf("  128 bpm kick+hats+snare @%.0f -> %.2f bpm, confidence %.2f\n", fs, bpm, conf);
    CHECK_NEAR(bpm, 128.0, 1.0);
    CHECK(conf > 0.5);
  }
}

TEST(tempo_noise_has_low_confidence) {
  std::mt19937 rng(11);
  std::uniform_real_distribution<float> ud(-0.3f, 0.3f);
  std::vector<float> x(size_t(48000 * 10));
  for (auto& v : x) v = ud(rng);
  double conf = 1;
  runTempo(x, 48000, &conf);
  std::printf("  white noise -> tempo confidence %.2f\n", conf);
  CHECK(conf < 0.3);
}

static void runPitch(BassPitchTracker& p, double hz, double fs, bool harmonics) {
  p.prepare(fs);
  std::vector<float> x(static_cast<size_t>(fs));  // 1 s
  for (size_t i = 0; i < x.size(); ++i) {
    const double ph = 2.0 * std::numbers::pi * hz * double(i) / fs;
    double s = std::sin(ph);
    if (harmonics) s += 0.6 * std::sin(2 * ph + 0.3) + 0.4 * std::sin(3 * ph + 1.1) + 0.25 * std::sin(4 * ph);
    x[i] = float(0.3 * s);
  }
  for (size_t i = 0; i < x.size(); i += 512) p.process(x.data() + i, std::min<size_t>(512, x.size() - i));
}

TEST(bass_pitch_e1_and_a1) {
  struct Case { double hz; int midi; const char* name; double fs; };
  for (const Case& c : {Case{41.2034, 28, "E1", 48000}, Case{55.0, 33, "A1", 48000},
                        Case{41.2034, 28, "E1", 44100}, Case{55.0, 33, "A1", 44100}}) {
    BassPitchTracker p;
    runPitch(p, c.hz, c.fs, true);
    std::printf("  %.2f Hz @%.0f -> %.2f Hz %s %+.1f cents, confidence %.2f\n", c.hz, c.fs, p.hz(), p.noteName(),
                p.cents(), p.confidence());
    CHECK(p.midiNote() == c.midi);
    CHECK(std::string(p.noteName()) == c.name);
    CHECK(std::fabs(p.cents()) < 10.0);
    CHECK(p.confidence() > 0.8);
  }
  BassPitchTracker pure;  // a bare sine too, and a higher bass note
  runPitch(pure, 98.0, 48000, false);
  CHECK(pure.midiNote() == 43);  // G2
}

TEST(bass_pitch_noise_has_low_confidence) {
  BassPitchTracker p;
  p.prepare(48000);
  std::mt19937 rng(5);
  std::uniform_real_distribution<float> ud(-0.3f, 0.3f);
  std::vector<float> x(48000);
  for (auto& v : x) v = ud(rng);
  p.process(x.data(), x.size());
  std::printf("  white noise -> pitch confidence %.2f, hz %.1f\n", p.confidence(), p.hz());
  CHECK(p.confidence() < 0.5);
  CHECK(p.hz() == 0.0);
}

TEST(analysis_process_is_allocation_free) {
  TempoTracker t;
  BassPitchTracker p;
  t.prepare(48000);
  p.prepare(48000);
  const auto x = drumLoop(120.0, 48000, 5.0, true);
  g_allocCount = 0;
  g_trackAllocs = true;
  for (size_t i = 0; i < x.size(); i += 256) {
    t.process(x.data() + i, std::min<size_t>(256, x.size() - i));
    p.process(x.data() + i, std::min<size_t>(256, x.size() - i));
  }
  g_trackAllocs = false;
  CHECK(g_allocCount.load() == 0);
}

// ---- review regressions

TEST(smoothed_lands_exactly_on_large_targets) {
  for (double fs : {48000.0, 192000.0}) {
    Smoothed sm;
    sm.prepare(fs, 30.0);
    sm.snap(2.f);
    sm.setTarget(1.f);
    for (int i = 0; i < int(fs); ++i) sm.next();
    CHECK(sm.current() == 1.f);
    CHECK(sm.settled());
  }
}

TEST(limit_toggle_keeps_latency_and_never_jumps) {
  const double fs = 48000;
  Engine e;
  e.prepare(fs, 2, 512);
  e.edit().limiter = {-1.f, 80.f, true, 0.f, 0.f, 150.f};
  e.publish();
  const int lat = e.latencyFrames();
  const size_t n = size_t(fs);
  std::vector<float> l(n), r(n);
  for (size_t i = 0; i < n; ++i) l[i] = r[i] = float(0.5 * std::sin(2 * std::numbers::pi * 997 * double(i) / fs));
  float maxStep = 0, prev = 0;
  for (size_t s = 0; s < n; s += 512) {
    if (s == n / 2) {  // switch Limit off mid-stream
      e.edit().limiter.enabled = false;
      e.publish();
    }
    float* p[2] = {l.data() + s, r.data() + s};
    e.processPlanar(p, 2, int(std::min<size_t>(512, n - s)));
    for (size_t i = s; i < std::min(n, s + 512); ++i) {
      if (i > size_t(lat) + 10) maxStep = std::max(maxStep, std::fabs(l[i] - prev));
      prev = l[i];
    }
  }
  CHECK(e.latencyFrames() == lat);
  // A 997 Hz sine at 0.5 changes by at most ~0.066 per sample.
  CHECK(maxStep < 0.08f);
}

TEST(dj_filter_through_centre_does_not_click) {
  const double fs = 48000;
  DjFx d;
  d.prepare(fs, 2);
  const size_t n = size_t(fs);
  std::vector<float> l(n), r(n);
  for (size_t i = 0; i < n; ++i) l[i] = r[i] = float(0.5 * std::sin(2 * std::numbers::pi * 100 * double(i) / fs));
  float maxStep = 0, prev = 0;
  for (size_t s = 0; s < n; s += 256) {
    DjParams p;
    p.filter = s < n / 2 ? -0.4f : 0.4f;  // jump across centre
    d.setParams(p);
    float* q[2] = {l.data() + s, r.data() + s};
    d.process(q, 2, int(std::min<size_t>(256, n - s)));
    for (size_t i = s; i < std::min(n, s + 256); ++i) {
      if (i > 2000) maxStep = std::max(maxStep, std::fabs(l[i] - prev));
      prev = l[i];
    }
  }
  CHECK(maxStep < 0.02f);  // 100 Hz at 0.5: ~0.0065 per sample
}

// --- DJ performance pads ---------------------------------------------------

// Runs a DjFx over a stereo signal in 512-frame blocks.
static void runDj(DjFx& d, std::vector<float>& l, std::vector<float>& r) {
  for (size_t s = 0; s < l.size(); s += 512) {
    float* q[2] = {l.data() + s, r.data() + s};
    d.process(q, 2, int(std::min<size_t>(512, l.size() - s)));
  }
}

static std::vector<float> sine(double hz, double fs, size_t n, double amp) {
  std::vector<float> x(n);
  for (size_t i = 0; i < n; ++i) x[i] = float(amp * std::sin(2 * std::numbers::pi * hz * double(i) / fs));
  return x;
}

TEST(dj_pads_off_are_bit_exact) {
  const double fs = 48000;
  DjFx d;
  d.prepare(fs, 2);
  DjParams p;
  p.trackTempo = true;  // the tracker only listens
  d.setParams(p);
  auto l = sine(220, fs, 24000, 0.5), r = sine(330, fs, 24000, 0.5);
  const auto l0 = l, r0 = r;
  runDj(d, l, r);
  CHECK(l == l0 && r == r0);
  // Every pad on, then off again: once settled the stage is transparent.
  p.tapeStop = p.chipmunk = p.screw = p.roll = p.lofi = p.pump = true;
  d.setParams(p);
  runDj(d, l, r);
  p = DjParams{};
  d.setParams(p);
  l = l0; r = r0;
  runDj(d, l, r);
  l = l0; r = r0;
  runDj(d, l, r);
  CHECK(l == l0 && r == r0);
}

TEST(dj_pads_stay_finite) {
  for (double fs : {44100.0, 192000.0}) {
    DjFx d;
    d.prepare(fs, 2);
    std::mt19937 rng(5);
    std::uniform_real_distribution<float> ud(-1.f, 1.f);
    const size_t n = size_t(fs * 0.5);
    bool ok = true;
    float peak = 0.f;
    for (int round = 0; round < 8; ++round) {
      DjParams p;
      p.tapeStop = round & 1;
      p.chipmunk = round & 2;
      p.screw = round != 0;
      p.roll = round & 4;
      p.lofi = p.pump = round != 3;
      d.setParams(p);
      std::vector<float> l(n), r(n);
      for (size_t i = 0; i < n; ++i) {
        const bool loud = round % 2 == 0 || i < n / 2;  // half the time silence
        l[i] = loud ? ud(rng) : 0.f;
        r[i] = loud ? ud(rng) : 0.f;
      }
      runDj(d, l, r);
      for (size_t i = 0; i < n; ++i)
        for (float v : {l[i], r[i]}) {
          ok &= std::isfinite(v) && std::fpclassify(v) != FP_SUBNORMAL;
          peak = std::max(peak, std::fabs(v));
        }
    }
    CHECK(ok);
    CHECK(peak < 4.f);
  }
}

TEST(dj_tape_stop_reaches_silence_and_returns) {
  const double fs = 48000;
  DjFx d;
  d.prepare(fs, 2);
  DjParams p;
  p.tapeStop = true;
  d.setParams(p);
  auto l = sine(440, fs, size_t(1.3 * fs), 0.5), r = l;
  runDj(d, l, r);
  float early = 0.f, late = 0.f;
  for (size_t i = size_t(0.1 * fs); i < size_t(0.3 * fs); ++i) early = std::max(early, std::fabs(l[i]));
  for (size_t i = size_t(1.1 * fs); i < l.size(); ++i) late = std::max(late, std::fabs(l[i]));
  CHECK(early > 0.3f);   // still playing (slower) at first
  CHECK(late < 1e-4f);   // stopped
  // Release: mostly back on live in ~30 ms, then exactly (bit-exact) by ~0.1 s.
  d.setParams({});
  auto l2 = sine(440, fs, size_t(0.2 * fs), 0.5), r2 = l2;
  const auto ref = l2;
  runDj(d, l2, r2);
  double err = 0;
  for (size_t i = size_t(0.03 * fs); i < size_t(0.04 * fs); ++i) err = std::max(err, double(std::fabs(l2[i] - ref[i])));
  CHECK(err < 0.02);
  err = 0;
  for (size_t i = size_t(0.12 * fs); i < l2.size(); ++i) err = std::max(err, double(std::fabs(l2[i] - ref[i])));
  CHECK(err == 0.0);
}

TEST(dj_pitch_shift_moves_a_sine) {
  const double fs = 48000;
  for (int up = 0; up < 2; ++up) {
    DjFx d;
    d.prepare(fs, 2);
    DjParams p;
    (up ? p.chipmunk : p.screw) = true;
    d.setParams(p);
    auto l = sine(440, fs, size_t(fs), 0.5), r = l;
    runDj(d, l, r);
    const double want = 440.0 * std::exp2((up ? 7.0 : -5.0) / 12.0);
    // Strongest frequency in the second half (5 Hz grid).
    double best = 0, bestMag = 0;
    for (double hz = 200; hz <= 900; hz += 5) {
      const double m = toneMag(l, hz, fs, l.size() / 2);
      if (m > bestMag) bestMag = m, best = hz;
    }
    const double atDry = toneMag(l, 440, fs, l.size() / 2);
    std::printf("  %s: want %.0f Hz, peak %.0f Hz (%.3f), 440 Hz %.3f\n", up ? "chipmunk" : "screw", want, best,
                bestMag, atDry);
    CHECK(std::fabs(best - want) < 0.03 * want);
    CHECK(bestMag > 4.0 * atDry);  // the original pitch is gone
  }
}

TEST(night_guard_recovers_at_192k) {
  const double fs = 192000;
  LoudnessGuard g;
  g.prepare(fs);
  g.setParams({8.f, 20.f, true});
  std::mt19937 rng(5);
  std::normal_distribution<float> nd(0.f, 1.f);
  // 10 s quiet, then a sustained louder programme: the average must climb
  // so the cut eases off (it froze at 192 kHz in float).
  std::vector<float> l(4096), r(4096);
  float cutAt30 = 0, cutAtEnd = 0;
  const int blocks = int(fs * 400 / 4096);
  for (int b = 0; b < blocks; ++b) {
    const double t = double(b) * 4096 / fs;
    const float a = t < 10 ? dbToGain(-32.f) : dbToGain(-12.f);
    for (size_t i = 0; i < l.size(); ++i) { l[i] = a * nd(rng); r[i] = a * nd(rng); }
    float* p[2] = {l.data(), r.data()};
    g.process(p, 2, 4096);
    if (t < 30) cutAt30 = g.cutDb();
    cutAtEnd = g.cutDb();
  }
  CHECK(cutAt30 < -6.f);     // it acted on the jump
  CHECK(cutAtEnd > -2.5f);   // and let go as the new level became normal
}

static double toneRmsRatio(HearingFit& h, int c, double hz, double fs) {
  const int n = 24000;
  std::vector<float> l(n), r(n);
  for (int i = 0; i < n; ++i) l[size_t(i)] = r[size_t(i)] = 0.1f * float(std::sin(2 * 3.14159265358979 * hz * i / fs));
  float* p[2] = {l.data(), r.data()};
  for (int s = 0; s < n; s += 256) { float* q[2] = {p[0] + s, p[1] + s}; h.process(q, 2, std::min(256, n - s)); }
  double a = 0, b = 0;
  const auto& y = c == 0 ? l : r;
  for (int i = n / 2; i < n; ++i) { a += double(y[size_t(i)]) * y[size_t(i)]; const double x = 0.1 * std::sin(2 * 3.14159265358979 * hz * i / fs); b += x * x; }
  return 10 * std::log10(a / b);
}

TEST(hearing_disabled_is_bit_exact) {
  HearingFit h;
  h.prepare(48000);
  HearingParams p;
  p.enabled = false;
  for (auto& ch : p.gainDb) for (auto& g : ch) g = 8.f;
  h.setParams(p);
  std::vector<float> l(512), r(512);
  for (int i = 0; i < 512; ++i) { l[size_t(i)] = float(std::sin(i * 0.1)); r[size_t(i)] = float(std::cos(i * 0.07)); }
  auto l0 = l, r0 = r;
  float* q[2] = {l.data(), r.data()};
  h.process(q, 2, 512);
  CHECK(l == l0 && r == r0);
  // Also bit-exact after turning on then off again once settled.
  p.enabled = true; h.setParams(p); h.process(q, 2, 512);
  p.enabled = false; h.setParams(p);
  for (int k = 0; k < 200; ++k) h.process(q, 2, 512);
  l = l0; r = r0;
  h.process(q, 2, 512);
  CHECK(l == l0 && r == r0);
}

TEST(hearing_left_right_independent_and_capped) {
  HearingFit h;
  h.prepare(48000);
  HearingParams p;
  p.enabled = true;
  p.gainDb[0][4] = 6.f;   // left +6 at 4 kHz
  p.gainDb[1][2] = 25.f;  // right: request beyond cap at 1 kHz
  h.setParams(p);
  h.snapToTargets();
  CHECK_NEAR(h.magnitudeDb(0, 4000), 6.0, 0.6);
  CHECK_NEAR(h.magnitudeDb(1, 4000), 0.0, 1.5);
  CHECK_NEAR(h.magnitudeDb(0, 1000), 0.0, 0.5);
  CHECK(h.magnitudeDb(1, 1000) <= 10.6);
  CHECK(h.magnitudeDb(1, 1000) > 9.0);
  HearingFit h2; h2.prepare(48000); h2.setParams(p);
  CHECK_NEAR(toneRmsRatio(h2, 0, 4000, 48000), 6.0, 0.7);
  HearingFit h3; h3.prepare(48000); h3.setParams(p);
  CHECK_NEAR(toneRmsRatio(h3, 0, 1000, 48000), 0.0, 0.5);
  HearingFit h4; h4.prepare(48000); h4.setParams(p);
  CHECK(toneRmsRatio(h4, 1, 1000, 48000) <= 10.6);
  // Negative requests clamp to 0 (boost-only).
  HearingParams n; n.enabled = true; n.gainDb[0][3] = -9.f;
  HearingFit h5; h5.prepare(48000); h5.setParams(n); h5.snapToTargets();
  CHECK(!h5.active());
}

TEST(engine_hearing_c_api) {
  PunchEngine* e = punch_engine_create();
  punch_engine_prepare(e, 48000, 2, 256);
  const float L[6] = {0, 0, 0, 0, 30, 0}, R[6] = {0, 0, 0, 0, 0, 0};
  punch_set_hearing(e, true, L, R);
  punch_engine_publish(e);
  punch_set_hearing(e, false, nullptr, nullptr);
  punch_engine_publish(e);
  punch_engine_destroy(e);
  CHECK(true);
}

// ---------------------------------------------------------------------------
// Bass character (Distort / Punch) and Late Night.

// Stereo pink-ish noise (Kellet), decorrelated, scaled to `rmsDb` dBFS.
static std::vector<float> pinkStereo(int n, float rmsDb, unsigned seed) {
  std::vector<float> out(size_t(n) * 2);
  std::mt19937 rng(seed);
  std::uniform_real_distribution<float> ud(-1.f, 1.f);
  for (int c = 0; c < 2; ++c) {
    float b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0;
    for (int i = 0; i < n; ++i) {
      const float w = ud(rng);
      b0 = 0.99886f * b0 + w * 0.0555179f; b1 = 0.99332f * b1 + w * 0.0750759f;
      b2 = 0.96900f * b2 + w * 0.1538520f; b3 = 0.86650f * b3 + w * 0.3104856f;
      b4 = 0.55000f * b4 + w * 0.5329522f; b5 = -0.7616f * b5 - w * 0.0168980f;
      out[size_t(i) * 2 + size_t(c)] = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362f;
      b6 = w * 0.115926f;
    }
  }
  double s = 0;
  for (float v : out) s += double(v) * v;
  const float g = dbToGain(rmsDb) / float(std::sqrt(s / double(out.size())));
  for (float& v : out) v *= g;
  return out;
}

// Runs an interleaved stereo buffer through a planar processor in blocks.
template <typename P>
static void runStereo(P& proc, std::vector<float>& buf, int block = 256) {
  const int n = int(buf.size() / 2);
  std::vector<float> l(static_cast<size_t>(block)), r(static_cast<size_t>(block));
  for (int s = 0; s < n; s += block) {
    const int m = std::min(block, n - s);
    for (int i = 0; i < m; ++i) { l[size_t(i)] = buf[size_t(s + i) * 2]; r[size_t(i)] = buf[size_t(s + i) * 2 + 1]; }
    float* ch[2] = {l.data(), r.data()};
    proc.process(ch, 2, m);
    for (int i = 0; i < m; ++i) { buf[size_t(s + i) * 2] = l[size_t(i)]; buf[size_t(s + i) * 2 + 1] = r[size_t(i)]; }
  }
}

static double rmsDb(const std::vector<float>& v, size_t from) {
  double s = 0;
  for (size_t i = from; i < v.size(); ++i) s += double(v[i]) * v[i];
  return 10.0 * std::log10(s / double(v.size() - from) + 1e-30);
}

TEST(flavor_off_is_bit_exact) {
  const auto in = pinkStereo(48000 * 3, -18.f, 3);
  BassCharacter bc;
  bc.prepare(48000, 2);
  LateNight ln;
  ln.prepare(48000, 2);
  auto a = in, b = in;
  runStereo(bc, a);
  runStereo(ln, b);
  CHECK(a == in);
  CHECK(b == in);
  // On, then off again: once the ramps finish, bit-exact again.
  for (int kind = 1; kind <= 2; ++kind) {
    BassCharacter c2;
    c2.prepare(48000, 2);
    c2.setParams({BassCharacterKind(kind), 0.8f, 1.f});
    auto x = in;
    runStereo(c2, x);
    CHECK(x != in);
    c2.setParams({});
    auto y = in;
    runStereo(c2, y);  // ramps out during the first 25 ms
    auto z = in;
    runStereo(c2, z);
    CHECK(z == in);
  }
  LateNight l2;
  l2.prepare(48000, 2);
  l2.setParams({true, 0.5f});
  auto x = in;
  runStereo(l2, x);
  CHECK(x != in);
  l2.setParams({});
  auto y = in;
  runStereo(l2, y);
  auto z = in;
  runStereo(l2, z);
  CHECK(z == in);
}

TEST(flavor_finite_no_denormals_44k_192k) {
  for (double fs : {44100.0, 192000.0}) {
    Engine e;
    e.edit().bassCharacter = {BassCharacterKind::Distort, 1.f, 1.f};
    e.edit().lateNight = {true, 1.f};
    e.prepare(fs, 2, 512);
    const int n = int(fs) * 2;
    // Hot 808 + noise, then silence; switch kind and haze mid-way.
    std::vector<float> buf(size_t(n) * 2);
    auto noise = pinkStereo(n, -10.f, 9);
    for (int i = 0; i < n; ++i)
      for (int c = 0; c < 2; ++c)
        buf[size_t(i) * 2 + size_t(c)] = i < n / 2 ? 1.5f * float(std::sin(2 * std::numbers::pi * 45 * i / fs)) +
                                                         noise[size_t(i) * 2 + size_t(c)]
                                                   : 0.f;
    bool finite = true, subnormal = false;
    float peak = 0.f;
    for (int s = 0; s < n; s += 512) {
      if (s == n / 4) {
        e.edit().bassCharacter = {BassCharacterKind::Punch, 0.3f, 1.f};
        e.edit().lateNight.haze = 0.f;
        e.publish();
      }
      const int m = std::min(512, n - s);
      e.processInterleaved(&buf[size_t(s) * 2], &buf[size_t(s) * 2], 2, m);
    }
    for (float v : buf) {
      finite &= std::isfinite(v);
      subnormal |= std::fpclassify(v) == FP_SUBNORMAL;
      peak = std::max(peak, std::fabs(v));
    }
    CHECK(finite);
    CHECK(!subnormal);
    CHECK(peak < 2.f);
  }
}

TEST(flavor_loudness_roughly_matched) {
  const auto in = pinkStereo(48000 * 5, -18.f, 5);
  const double ref = rmsDb(in, in.size() / 2);
  for (int kind = 1; kind <= 2; ++kind) {
    BassCharacter bc;
    bc.prepare(48000, 2);
    bc.setParams({BassCharacterKind(kind), 0.6f, 1.f});
    auto x = in;
    runStereo(bc, x);
    const double d = rmsDb(x, x.size() / 2) - ref;
    std::printf("    bass character %d: %+.2f dB\n", kind, d);
    CHECK(std::fabs(d) <= 1.5);
  }
  LateNight ln;
  ln.prepare(48000, 2);
  ln.setParams({true, 0.5f});
  auto x = in;
  runStereo(ln, x);
  const double d = rmsDb(x, x.size() / 2) - ref;
  std::printf("    late night: %+.2f dB\n", d);
  CHECK(std::fabs(d) <= 1.5);
}

TEST(late_night_darkens_8k) {
  LateNight ln;
  ln.prepare(48000, 2);
  ln.setParams({true, 0.5f});
  const int n = 48000;
  std::vector<float> buf(size_t(n) * 2);
  for (int i = 0; i < n; ++i)
    buf[size_t(i) * 2] = buf[size_t(i) * 2 + 1] = 0.1f * float(std::sin(2 * std::numbers::pi * 8000.0 * i / 48000.0));
  const double ref = rmsDb(buf, buf.size() / 2);
  runStereo(ln, buf);
  const double d = rmsDb(buf, buf.size() / 2) - ref;
  std::printf("    late night 8 kHz: %+.1f dB\n", d);
  CHECK(d <= -10.0);
}

TEST(bass_character_c_api) {
  PunchEngine* e = punch_engine_create();
  punch_engine_prepare(e, 48000, 2, 512);
  punch_set_bass_character(e, 1, 0.6f);
  punch_set_late_night(e, true, 0.5f);
  punch_engine_publish(e);
  std::vector<float> buf(512 * 2, 0.2f);
  punch_process_interleaved(e, buf.data(), buf.data(), 2, 512);
  for (float v : buf) CHECK(std::isfinite(v));
  punch_engine_destroy(e);
}

// ---- Bass character timing / image (owner: "Distort nudges my bass to the
// right and brings it in a few ms late").
namespace bctest {
constexpr double kFs = 48000.0;
// Zero-phase Butterworth analysis filter (forward + backward).
static std::vector<float> zeroPhase(std::vector<float> y, FilterType t, double hz) {
  for (int pass = 0; pass < 2; ++pass) {
    for (int k = 0; k < 2; ++k) {
      const SvfCoeffs c = SvfCoeffs::make({t, hz, 0, 0.7071, true}, kFs);
      SvfState s;
      for (auto& v : y) v = s.tick(c, v);
    }
    std::reverse(y.begin(), y.end());
  }
  return y;
}
static std::vector<float> envelope(const std::vector<float>& x) {
  std::vector<float> e(x.size());
  const float a = float(1 - std::exp(-1.0 / (0.0003 * kFs)));
  float z = 0;
  for (size_t i = 0; i < x.size(); ++i) { z += a * (std::fabs(x[i]) - z); e[i] = z; }
  z = 0;
  for (size_t i = e.size(); i-- > 0;) { z += a * (e[i] - z); e[i] = z; }
  return e;
}
static std::complex<double> toneAt(const std::vector<float>& x, double hz, size_t a, size_t b) {
  std::complex<double> s = 0;
  for (size_t i = a; i < b; ++i) s += double(x[i]) * std::polar(1.0, -2 * std::numbers::pi * hz * double(i) / kFs);
  return s * (2.0 / double(b - a));
}
static void run(BassCharacter& bc, std::vector<float>& l, std::vector<float>& r) {
  for (size_t i = 0; i < l.size(); i += 512) {
    float* p[2] = {l.data() + i, r.data() + i};
    bc.process(p, 2, int(std::min<size_t>(512, l.size() - i)));
  }
}
// A kick: 158 -> 48 Hz chirp, 0.7 ms attack, 160 ms decay.
static std::vector<float> kicks(std::vector<size_t>& onsets) {
  std::vector<float> m(size_t(kFs * 3), 0.f);
  for (double t = 0.5; t < 2.6; t += 0.5) {
    const size_t o = size_t(t * kFs);
    onsets.push_back(o);
    double ph = 0;
    for (size_t i = 0; i < size_t(0.45 * kFs); ++i) {
      const double s = double(i) / kFs;
      ph += 2 * std::numbers::pi * (48 + 110 * std::exp(-s / 0.025)) / kFs;
      m[o + i] += float(0.7 * std::exp(-s / 0.16) * (1 - std::exp(-s / 0.0007)) * std::sin(ph));
    }
  }
  return m;
}
}  // namespace bctest

TEST(bass_character_keeps_the_bass_image) {
  using namespace bctest;
  for (int kind = 1; kind <= 2; ++kind) {
    for (double lean : {0.0, 0.15}) {
      const size_t n = size_t(kFs * 2);
      std::vector<float> l(n), r(n);
      for (size_t i = 0; i < n; ++i) {
        const double t = double(i) / kFs;
        const double b = 0.4 * std::sin(2 * std::numbers::pi * 55 * t) + 0.25 * std::sin(2 * std::numbers::pi * 90 * t + 1) +
                         0.15 * std::sin(2 * std::numbers::pi * 140 * t + 2);
        l[i] = float(b * (1 - lean));
        r[i] = float(b * (1 + lean));
      }
      const auto l0 = l, r0 = r;
      BassCharacter bc;
      bc.prepare(kFs, 2);
      bc.setParams({BassCharacterKind(kind), 0.8f, 1.f});
      run(bc, l, r);
      CHECK(l != l0);  // it did something
      if (lean == 0.0) CHECK(l == r);  // a centred bass stays exactly centred
      const size_t a = size_t(kFs), e = n;
      for (double hz : {55.0, 90.0, 140.0}) {
        const double balIn = 20 * std::log10(std::abs(toneAt(r0, hz, a, e)) / std::abs(toneAt(l0, hz, a, e)));
        const auto ol = toneAt(l, hz, a, e), orr = toneAt(r, hz, a, e);
        const double balOut = 20 * std::log10(std::abs(orr) / std::abs(ol));
        const double phase = std::arg(orr / ol) * 180 / std::numbers::pi;
        CHECK_NEAR(balOut, balIn, 0.1);
        CHECK_NEAR(phase, 0.0, 1.0);
      }
    }
  }
}

TEST(bass_character_onset_timing) {
  using namespace bctest;
  std::vector<size_t> on;
  const auto dry = kicks(on);
  const auto dl = zeroPhase(dry, FilterType::LowPass, 150);
  const auto ed = envelope(dl);
  for (int kind = 1; kind <= 2; ++kind) {
    auto l = dry, r = dry;
    BassCharacter bc;
    bc.prepare(kFs, 2);
    bc.setParams({BassCharacterKind(kind), 0.6f, 1.f});
    run(bc, l, r);
    // The summed low band lands with the dry one (cross-correlation lag).
    const auto ol = zeroPhase(l, FilterType::LowPass, 150);
    double best = -1e30;
    int lag = 0;
    for (int L = -48; L <= 48; ++L) {
      double s = 0;
      for (size_t i = size_t(0.9 * kFs); i < size_t(2.9 * kFs); ++i) s += double(dl[i]) * ol[size_t(long(i) + L)];
      if (s > best) { best = s; lag = L; }
    }
    const double lagMs = lag / kFs * 1000;
    // What Distort adds (its grit) arrives with the kick: envelope lag of
    // (out - dry) against the dry lows over the first 60 ms of each hit.
    std::vector<float> add(dry.size());
    for (size_t i = 0; i < dry.size(); ++i) add[i] = l[i] - dry[i];
    const auto ea = envelope(zeroPhase(add, FilterType::LowPass, 2000));
    best = -1e30;
    int glag = 0;
    for (int L = -240; L <= 480; ++L) {
      double s = 0;
      for (size_t o : on)
        if (o > size_t(0.9 * kFs))
          for (size_t i = o; i < o + size_t(0.06 * kFs); ++i) s += double(ed[i]) * ea[size_t(long(i) + L)];
      if (s > best) { best = s; glag = L; }
    }
    const double gritMs = glag / kFs * 1000;
    std::printf("    %s: low band lag %+.2f ms, added part lag %+.2f ms\n", kind == 1 ? "distort" : "punch", lagMs, gritMs);
    CHECK(std::fabs(lagMs) <= 0.5);
    if (kind == 1) CHECK(gritMs <= 2.0);  // an LR4 split put it ~4 ms late
  }
}

// Punch's boost used to be x + (g - 1) * LR4(x), which cancels against the
// dry signal at the 150 Hz crossover: a quiet 150 Hz tone dipped on every hit.
TEST(punch_does_not_notch_150hz) {
  using namespace bctest;
  const size_t n = size_t(kFs * 4);
  std::vector<float> x(n, 0.f);
  for (double t0 = 0.25; t0 < 3.6; t0 += 0.5) {
    const size_t o = size_t(t0 * kFs);
    for (size_t i = 0; i < size_t(0.4 * kFs) && o + i < n; ++i) {
      const double t = double(i) / kFs;
      x[o + i] += float(0.5 * std::exp(-t / 0.15) * (1 - std::exp(-t / 0.001)) * std::sin(2 * std::numbers::pi * 45 * t));
    }
  }
  for (size_t i = 0; i < n; ++i) x[i] += float(0.03 * std::sin(2 * std::numbers::pi * 150 * double(i) / kFs));
  for (float amt : {0.3f, 0.6f, 1.f}) {
    auto l = x, r = x;
    BassCharacter bc;
    bc.prepare(kFs, 2);
    bc.setParams({BassCharacterKind::Punch, amt, 1.f});
    run(bc, l, r);
    double pin = 0, pout = 0;
    for (double t0 = 0.75; t0 < 3.6; t0 += 0.5) {
      const size_t o = size_t((t0 + 0.005) * kFs), e = size_t((t0 + 0.060) * kFs);
      auto lock = [&](const std::vector<float>& v) {
        std::complex<double> s = 0;
        double ws = 0;
        for (size_t i = o; i < e; ++i) {
          const double w = 0.5 - 0.5 * std::cos(2 * std::numbers::pi * double(i - o) / double(e - o));
          s += w * double(v[i]) * std::polar(1.0, -2 * std::numbers::pi * 150 * double(i) / kFs);
          ws += w;
        }
        return std::norm(s / ws);
      };
      pin += lock(x);
      pout += lock(l);
    }
    const double d = 10 * std::log10(pout / pin);
    std::printf("    punch %.1f: 150 Hz during hits %+.2f dB\n", double(amt), d);
    CHECK(d >= -0.5);
  }
}

// ---- Bass Shaker (the Bass Shake preset's low end)
namespace shtest {
constexpr double kFs = 48000.0;
constexpr double kPi = std::numbers::pi;
using Buf = std::vector<float>;
struct St { Buf L, R; };

static Buf lr4(const Buf& x, FilterType t, double hz) {
  const SvfCoeffs c = SvfCoeffs::make({t, hz, 0, 0.7071, true}, kFs);
  SvfState a, b;
  Buf y(x.size());
  for (size_t i = 0; i < x.size(); ++i) y[i] = b.tick(c, a.tick(c, x[i]));
  return y;
}
static Buf mono(const St& s) {
  Buf m(s.L.size());
  for (size_t i = 0; i < m.size(); ++i) m[i] = 0.5f * (s.L[i] + s.R[i]);
  return m;
}
static double pw(const Buf& x, size_t a, size_t b) {
  double s = 0;
  b = std::min(b, x.size());
  for (size_t i = a; i < b; ++i) s += double(x[i]) * x[i];
  return b > a ? s / double(b - a) : 0;
}
static double dB(double p) { return 10 * std::log10(std::max(p, 1e-20)); }
struct Pink {
  std::mt19937 rng{7};
  std::normal_distribution<float> nd{0.f, 1.f};
  float b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0;
  float next() {
    const float w = nd(rng) * 0.05f;
    b0 = 0.99886f * b0 + w * 0.0555179f; b1 = 0.99332f * b1 + w * 0.0750759f;
    b2 = 0.96900f * b2 + w * 0.1538520f; b3 = 0.86650f * b3 + w * 0.3104856f;
    b4 = 0.55000f * b4 + w * 0.5329522f; b5 = -0.7616f * b5 - w * 0.0168980f;
    const float p = b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362f;
    b6 = w * 0.115926f;
    return p;
  }
};
static void addKick(Buf& m, size_t at, float amp) {
  double ph = 0;
  for (size_t i = 0; i < size_t(0.45 * kFs) && at + i < m.size(); ++i) {
    const double t = double(i) / kFs;
    ph += 2 * kPi * (48 + 110 * std::exp(-t / 0.025)) / kFs;
    m[at + i] += amp * float(std::exp(-t / 0.16) * (1 - std::exp(-t / 0.0007)) * std::sin(ph));
  }
}
static void add808(Buf& m, size_t at, double f, double dur, float amp) {
  double ph = 0;
  for (size_t i = 0; i < size_t(dur * kFs) && at + i < m.size(); ++i) {
    const double t = double(i) / kFs;
    ph += 2 * kPi * f * (1 + 0.6 * std::exp(-t / 0.012)) / kFs;
    const double env = std::exp(-t / 0.9) * (1 - std::exp(-t / 0.003)) * std::min(1.0, (dur - t) / 0.02);
    m[at + i] += amp * float(std::tanh(1.4 * std::sin(ph)) / std::tanh(1.4) * env);
  }
}
static std::vector<size_t> onsets(double secs) {
  std::vector<size_t> v;
  for (double t = 0.25; t < secs - 0.5; t += 0.5) v.push_back(size_t(t * kFs));
  return v;
}
static void normPeak(St& s, float peak) {
  float p = 0;
  for (size_t i = 0; i < s.L.size(); ++i) p = std::max({p, std::fabs(s.L[i]), std::fabs(s.R[i])});
  for (size_t i = 0; i < s.L.size(); ++i) { s.L[i] *= peak / p; s.R[i] *= peak / p; }
}
// The app's Bass Shake (Limit off): new preset EQ, the Shaker at `strength`,
// and the safety net the Shaker always turns on.
static PunchEngine* bassShake(double strength) {
  PunchEngine* e = punch_engine_create();
  const double bands[6][4] = {{PUNCH_LOW_SHELF, 105, 0, 0.71}, {PUNCH_BELL, 55, 0, 1.2}, {PUNCH_BELL, 250, -1.5, 1},
                              {PUNCH_BELL, 1000, 0, 1}, {PUNCH_BELL, 3500, 1.5, 1}, {PUNCH_HIGH_SHELF, 10000, 1.5, 0.71}};
  punch_set_num_bands(e, 6);
  for (int i = 0; i < 6; ++i) punch_set_band(e, i, PunchFilterType(int(bands[i][0])), bands[i][1], bands[i][2], bands[i][3], true);
  punch_set_auto_preamp(e, false);
  punch_set_bass(e, strength > 0.001, float(strength), 110);
  punch_set_bass_mode(e, 1);
  punch_set_bass_shaker(e, 0.f, 1.f);
  punch_set_limiter(e, true, -1, 80);
  punch_set_boost_leveler(e, true);
  punch_set_limiter_shape(e, 600, 1);
  punch_set_bass_priority(e, 150);
  punch_engine_prepare(e, kFs, 2, 512);
  punch_engine_publish(e);
  return e;
}
static St render(PunchEngine* e, St s) {
  const size_t n = s.L.size();
  for (size_t i = 0; i < n; i += 512) {
    float* p[2] = {s.L.data() + i, s.R.data() + i};
    punch_process_planar(e, p, 2, int(std::min<size_t>(512, n - i)));
  }
  const size_t lat = size_t(punch_engine_latency_frames(e));
  s.L.erase(s.L.begin(), s.L.begin() + long(lat)); s.L.resize(n, 0.f);
  s.R.erase(s.R.begin(), s.R.begin() + long(lat)); s.R.resize(n, 0.f);
  return s;
}
static void fft(std::vector<std::complex<double>>& a) {
  const size_t n = a.size();
  for (size_t i = 1, j = 0; i < n; ++i) {
    size_t bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) std::swap(a[i], a[j]);
  }
  for (size_t len = 2; len <= n; len <<= 1) {
    const std::complex<double> wl = std::polar(1.0, -2 * kPi / double(len));
    for (size_t i = 0; i < n; i += len) {
      std::complex<double> w(1);
      for (size_t j = 0; j < len / 2; ++j) {
        const auto u = a[i + j], v = a[i + j + len / 2] * w;
        a[i + j] = u + v;
        a[i + j + len / 2] = u - v;
        w *= wl;
      }
    }
  }
}
}  // namespace shtest

TEST(bass_shaker_bit_exact_when_off) {
  const auto in = pinkStereo(48000 * 2, -14.f, 11);
  BassShaker sh;
  sh.prepare(48000, 2);
  auto a = in;
  runStereo(sh, a);
  CHECK(a == in);
  sh.setParams({0.7f, 0.f, -1.f, 0.f, 1.f});
  auto b = in;
  runStereo(sh, b);
  CHECK(b != in);
  sh.setParams({});
  auto c = in;
  runStereo(sh, c);  // glides out
  auto d = in;
  runStereo(sh, d);
  CHECK(d == in);
  CHECK(sh.idle());
  // Through the engine: Shaker mode at Strength 0 is the plain chain.
  Engine e1, e2;
  e1.edit().bassShaker = true;
  e1.edit().eq.numBands = 1;
  e1.edit().eq.bands[0] = {FilterType::Bell, 1000, 2, 1, true};
  e2.edit() = e1.edit();
  e2.edit().bassShaker = false;
  e1.prepare(48000, 2, 512);
  e2.prepare(48000, 2, 512);
  auto x = in, y = in;
  e1.processInterleaved(x.data(), x.data(), 2, 48000);
  e2.processInterleaved(y.data(), y.data(), 2, 48000);
  CHECK(x == y);
}

TEST(bass_shaker_amount_step_has_no_jumps) {
  BassShaker sh;
  sh.prepare(48000, 2);
  const int n = 48000 * 2;
  std::vector<float> l(static_cast<size_t>(n)), r(static_cast<size_t>(n));
  for (int i = 0; i < n; ++i) {
    const double t = i / 48000.0;
    const double ph = std::fmod(t, 0.5);  // kicks keep the dynamics moving
    l[size_t(i)] = r[size_t(i)] = float(0.3 * std::sin(2 * std::numbers::pi * 60 * t) +
                                        0.4 * std::exp(-ph / 0.12) * std::sin(2 * std::numbers::pi * 50 * ph));
  }
  const auto l0 = l;
  double maxJump = 0, maxChange = 0, steadyJump = 0;
  float prev = 0.f;
  bool stepped = false;
  for (int s = 0; s < n; s += 256) {
    if (s >= n / 2 && !stepped) {
      sh.setParams({1.f, 0.f, -1.f, 0.f, 1.f});  // 0 -> 1 in one go
      stepped = true;
    }
    float* ch[2] = {l.data() + s, r.data() + s};
    sh.process(ch, 2, std::min(256, n - s));
    for (int i = s; i < std::min(n, s + 256); ++i) {
      const float d = l[size_t(i)] - l0[size_t(i)];  // what the stage changed
      const double j = std::fabs(d - prev);
      if (i >= n / 2 && i < n / 2 + 4800) maxJump = std::max(maxJump, j);  // the 100 ms after the step
      if (i >= n - 24000) steadyJump = std::max(steadyJump, j);             // settled at 1
      maxChange = std::max(maxChange, double(std::fabs(d)));
      prev = d;
    }
  }
  std::printf("    largest sample-to-sample step of the change: %.4f after the step, %.4f settled (change up to %.3f)\n",
              maxJump, steadyJump, maxChange);
  CHECK(maxChange > 0.05);
  CHECK(maxJump <= 1.2 * steadyJump);  // no click: never steeper than the settled sound
  bool finite = true;
  for (float v : l) finite &= std::isfinite(v);
  CHECK(finite);
}

TEST(bass_shaker_finite_no_denormals_44k_192k) {
  for (double fs : {44100.0, 192000.0}) {
    Engine e;
    e.edit().bassShaker = true;
    e.edit().bass = {1.f, 110.f, 4.f, true};
    e.edit().limiter.enabled = true;
    e.prepare(fs, 2, 512);
    const int n = int(fs) * 3;
    std::vector<float> buf(size_t(n) * 2);
    auto noise = pinkStereo(n, -10.f, 9);
    for (int i = 0; i < n; ++i)
      for (int c = 0; c < 2; ++c)
        buf[size_t(i) * 2 + size_t(c)] = i < n / 2 ? 1.5f * float(std::sin(2 * std::numbers::pi * 45 * i / fs)) +
                                                         noise[size_t(i) * 2 + size_t(c)]
                                                   : 0.f;  // then silence: decaying state
    bool finite = true, subnormal = false;
    float peak = 0.f;
    for (int s = 0; s < n; s += 512) {
      if (s == n / 4) { e.edit().bass.amount = 0.3f; e.edit().shaker.paceBpm = 95.f; e.publish(); }
      const int m = std::min(512, n - s);
      e.processInterleaved(&buf[size_t(s) * 2], &buf[size_t(s) * 2], 2, m);
    }
    for (float v : buf) {
      finite &= std::isfinite(v);
      subnormal |= std::fpclassify(v) == FP_SUBNORMAL;
      peak = std::max(peak, std::fabs(v));
    }
    CHECK(finite);
    CHECK(!subnormal);
    CHECK(peak < 1.f);  // the limiter held it
    // Hostile input: NaN/Inf must not latch.
    std::vector<float> bad(1024, std::numeric_limits<float>::quiet_NaN());
    e.processInterleaved(bad.data(), bad.data(), 2, 512);
    std::vector<float> ok(1024, 0.1f);
    e.processInterleaved(ok.data(), ok.data(), 2, 512);
    bool fin2 = true;
    for (float v : ok) fin2 &= std::isfinite(v);
    CHECK(fin2);
  }
}

// R&D thresholds (harness, run 8): punchy, no mid pumping, no junk in the
// vocal band, at the default Strength.
TEST(bass_shaker_regression_thresholds) {
  using namespace shtest;
  const double secs = 12;
  const size_t n = size_t(secs * kFs);
  // A (quiet): kick every beat + 808 + steady vocal-band tones, -12 dB.
  {
    Buf m(n, 0.f);
    const double notes[] = {55, 49, 41.2};
    int k = 0;
    for (size_t o : onsets(secs)) {
      addKick(m, o, 0.6f);
      if (k % 4 == 0) add808(m, o, notes[(k / 4) % 3], 4 * 0.5 - 0.02, 0.45f);
      ++k;
    }
    St s{m, m};
    for (size_t i = 0; i < n; ++i) {
      const double t = double(i) / kFs;
      const float v = 0.08f * float(std::sin(2 * kPi * 431 * t) + std::sin(2 * kPi * 1013 * t) + std::sin(2 * kPi * 2311 * t));
      s.L[i] += v;
      s.R[i] += v;
    }
    normPeak(s, 0.89f * 0.25f);
    PunchEngine* e = bassShake(0.55);
    const St o = render(e, s);
    punch_engine_destroy(e);
    const Buf li = lr4(mono(s), FilterType::LowPass, 120), lo = lr4(mono(o), FilterType::LowPass, 120);
    double ti = 0, to = 0, si = 0, so = 0;
    for (size_t on : onsets(secs)) {
      if (on < size_t(2.25 * kFs) || on > n - size_t(0.6 * kFs)) continue;
      ti += pw(li, on, on + size_t(0.03 * kFs)); to += pw(lo, on, on + size_t(0.03 * kFs));
      si += pw(li, on + size_t(0.15 * kFs), on + size_t(0.45 * kFs)); so += pw(lo, on + size_t(0.15 * kFs), on + size_t(0.45 * kFs));
    }
    const double punchIndex = (dB(to) - dB(ti)) - (dB(so) - dB(si));
    std::printf("    punch index (transient - sustain lift) %.2f dB\n", punchIndex);
    CHECK(punchIndex > 0.0);
  }
  // B (hot): pink noise + kicks: the 600 Hz-3 kHz band must not swing.
  {
    Buf m(n, 0.f);
    for (size_t o : onsets(secs)) addKick(m, o, 0.7f);
    St s{m, m};
    Pink pl, pr;
    for (size_t i = 0; i < n; ++i) {
      const float c = pl.next(), d = pr.next();
      s.L[i] += 0.12f * (0.8f * c + 0.2f * d);
      s.R[i] += 0.12f * (0.8f * c + 0.2f * d * -1 + 0.4f * d);
    }
    normPeak(s, 0.89f);
    PunchEngine* e = bassShake(0.55);
    const St o = render(e, s);
    punch_engine_destroy(e);
    const Buf mi = lr4(lr4(mono(s), FilterType::HighPass, 600), FilterType::LowPass, 3000);
    const Buf mo = lr4(lr4(mono(o), FilterType::HighPass, 600), FilterType::LowPass, 3000);
    std::vector<double> ratio;
    for (size_t a = size_t(2.25 * kFs); a + 480 <= n - size_t(0.6 * kFs); a += 480)
      ratio.push_back(dB(pw(mo, a, a + 480)) - dB(pw(mi, a, a + 480)));
    std::sort(ratio.begin(), ratio.end());
    const double swing = ratio[size_t(0.98 * double(ratio.size() - 1))] - ratio[size_t(0.02 * double(ratio.size() - 1))];
    std::printf("    600 Hz-3 kHz swing (p98-p2) %.2f dB\n", swing);
    CHECK(swing < 1.0);
  }
  // D: steady 55 + 65.4 Hz minor third under a 1 kHz tone: whatever lands in
  // 300 Hz-3 kHz that isn't the tone or a bass harmonic is junk.
  {
    const size_t nd = size_t(6 * kFs);
    St s{Buf(nd), Buf(nd)};
    for (size_t i = 0; i < nd; ++i) {
      const double t = double(i) / kFs;
      s.L[i] = s.R[i] = 0.35f * float(std::sin(2 * kPi * 55 * t) + std::sin(2 * kPi * 65.41 * t)) + 0.06f * float(std::sin(2 * kPi * 1013 * t));
    }
    PunchEngine* e = bassShake(0.55);
    const St o = render(e, s);
    punch_engine_destroy(e);
    const Buf mo = mono(o);
    const size_t N = size_t(1) << 17, at = size_t(1.5 * kFs);
    std::vector<std::complex<double>> a(N);
    for (size_t i = 0; i < N; ++i) {
      const double t = double(i) / double(N - 1);
      const double w = 0.35875 - 0.48829 * std::cos(2 * kPi * t) + 0.14128 * std::cos(4 * kPi * t) - 0.01168 * std::cos(6 * kPi * t);
      a[i] = mo[at + i] * w;
    }
    fft(a);
    const double hz = kFs / double(N);
    std::vector<char> known(N / 2, 0);
    auto mark = [&](double f, int w) {
      for (long b = long(std::lround(f / hz)) - w; b <= long(std::lround(f / hz)) + w; ++b)
        if (b >= 0 && b < long(N / 2)) known[size_t(b)] = 1;
    };
    for (int k = 1; k * 55 < 3200; ++k) mark(55.0 * k, 5);
    for (int k = 1; k * 65.41 < 3200; ++k) mark(65.41 * k, 5);
    mark(1013, 6);
    double tone = 0, junk = 0;
    for (long b = long(std::lround(1013 / hz)) - 4; b <= long(std::lround(1013 / hz)) + 4; ++b) tone += std::norm(a[size_t(b)]);
    for (size_t b = size_t(300 / hz); b < size_t(3000 / hz); ++b)
      if (!known[b]) junk += std::norm(a[b]);
    const double junkDb = 10 * std::log10(junk / tone);
    std::printf("    vocal-band junk %.1f dBr the 1 kHz tone\n", junkDb);
    CHECK(junkDb < -25.0);
  }
}

TEST(bass_shaker_c_api_and_pace) {
  PunchEngine* e = punch_engine_create();
  punch_set_bass(e, true, 0.55f, 110);
  punch_set_bass_mode(e, 1);
  punch_set_bass_shaker(e, 3.f, 1.6f);
  punch_set_bass_pace(e, 90.f);
  punch_engine_prepare(e, 48000, 2, 512);
  punch_engine_publish(e);
  std::vector<float> buf(512 * 2, 0.f);
  for (int k = 0; k < 400; ++k) {
    for (int i = 0; i < 512; ++i) buf[size_t(i) * 2] = buf[size_t(i) * 2 + 1] = 0.3f * float(std::sin((k * 512 + i) * 0.007));
    punch_process_interleaved(e, buf.data(), buf.data(), 2, 512);
  }
  for (float v : buf) CHECK(std::isfinite(v));
  CHECK_NEAR(punch_bass_pace_bpm(e), 90.0, 0.5);
  CHECK_NEAR(punch_bass_shaker_strength_scale(), 1.4, 1e-6);
  // Automatic pace from kicks at 100 BPM (no tracker running).
  punch_set_bass_pace(e, 0.f);
  punch_engine_publish(e);
  const int beat = int(48000 * 0.6);
  for (int k = 0; k < 400; ++k) {
    for (int i = 0; i < 512; ++i) {
      const int t = (k * 512 + i) % beat;
      const double s = t / 48000.0;
      buf[size_t(i) * 2] = buf[size_t(i) * 2 + 1] = float(0.5 * std::exp(-s / 0.1) * (1 - std::exp(-s / 0.001)) * std::sin(2 * std::numbers::pi * 50 * s));
    }
    punch_process_interleaved(e, buf.data(), buf.data(), 2, 512);
  }
  std::printf("    pace from 100 BPM kicks: %.1f BPM\n", double(punch_bass_pace_bpm(e)));
  CHECK_NEAR(punch_bass_pace_bpm(e), 100.0, 3.0);
  punch_engine_destroy(e);
}

// Lights Out's master fade: bit-exact at 0 dB, a smooth monotonic ramp to
// exact silence (bypass included), a new pipeline starts where it's heading,
// and the way back is a ramp too.
TEST(master_fade_bit_exact_ramps_to_silence) {
  auto sine = [](std::vector<float>& b, int n, int off) {
    for (int i = 0; i < n; ++i) b[size_t(i) * 2] = b[size_t(i) * 2 + 1] = 0.5f * float(std::sin((off + i) * 0.05));
  };
  // Off: identical to an engine without it.
  {
    Engine a, b;
    a.edit().limiter.enabled = false; b.edit().limiter.enabled = false;
    a.edit().bypass = b.edit().bypass = true;
    a.prepare(48000, 2, 512); b.prepare(48000, 2, 512);
    b.edit().masterFadeDb = 0.f; b.edit().masterFadeMs = 45000.f; b.publish();
    std::vector<float> x(1024), y(1024);
    for (int k = 0; k < 20; ++k) {
      sine(x, 512, k * 512); y = x;
      a.processInterleaved(x.data(), x.data(), 2, 512);
      b.processInterleaved(y.data(), y.data(), 2, 512);
      for (size_t i = 0; i < x.size(); ++i) CHECK(x[i] == y[i]);
    }
  }
  Engine e;
  e.edit().bypass = true;   // applies in A/B too
  e.prepare(48000, 2, 480);
  std::vector<float> buf(960);
  for (int k = 0; k < 10; ++k) {   // fill the limiter's look-ahead first
    std::fill(buf.begin(), buf.end(), 1.f);
    e.processInterleaved(buf.data(), buf.data(), 2, 480);
  }
  e.edit().masterFadeDb = -120.f;   // clamps to silent
  e.edit().masterFadeMs = 300.f;
  e.publish();
  double lastDb = 0, maxJump = 0;
  float prevAbsGain = 1.f;
  bool monotonic = true;
  for (int k = 0; k < 40; ++k) {   // 400 ms
    for (int i = 0; i < 480; ++i) buf[size_t(i) * 2] = buf[size_t(i) * 2 + 1] = 1.f;   // DC: out = gain
    e.processInterleaved(buf.data(), buf.data(), 2, 480);
    for (int i = 0; i < 480; ++i) {
      const float g = buf[size_t(i) * 2];
      if (g > prevAbsGain + 1e-6f) monotonic = false;
      maxJump = std::max(maxJump, double(prevAbsGain - g));
      prevAbsGain = g;
    }
    const double db = e.masterFadeDb();
    CHECK(db <= lastDb);
    lastDb = db;
  }
  CHECK(monotonic);
  CHECK(maxJump < 0.01);         // no step: a ramp
  CHECK(lastDb == Engine::kSilentDb);
  CHECK(buf[958] == 0.f);        // exactly silent
  // Another edit (same target) doesn't restart it; a rebuild starts silent.
  e.edit().outputGainDb = 3.f; e.publish();
  e.prepare(44100, 2, 512);
  CHECK(e.masterFadeDb() == Engine::kSilentDb);
  // Back up over 100 ms: still silent at once, then a ramp to unity.
  e.edit().masterFadeDb = 0.f; e.edit().masterFadeMs = 100.f; e.publish();
  std::vector<float> one(1024, 1.f);
  e.processInterleaved(one.data(), one.data(), 2, 512);
  CHECK(one[0] < 0.01f);
  for (int k = 0; k < 20; ++k) { std::fill(one.begin(), one.end(), 1.f); e.processInterleaved(one.data(), one.data(), 2, 512); }
  CHECK(e.masterFadeDb() == 0.0);
  CHECK_NEAR(one[1022], 1.0, 1e-6);
  // C API.
  PunchEngine* c = punch_engine_create();
  punch_engine_prepare(c, 48000, 2, 512);
  punch_set_master_fade(c, -90.f, 10.f);
  punch_engine_publish(c);
  std::vector<float> z(1024, 0.5f);
  for (int k = 0; k < 4; ++k) punch_process_interleaved(c, z.data(), z.data(), 2, 512);
  CHECK(punch_master_fade_db(c) == -90.0);
  punch_engine_destroy(c);
}

int main() {
  for (const auto& t : registry()) {
    const int before = g_failures;
    t.fn();
    std::printf("%s %s\n", g_failures == before ? "[ OK ]" : "[FAIL]", t.name);
  }
  std::printf("\n%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
