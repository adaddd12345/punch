// Self-contained test runner (no third-party deps so it builds anywhere).
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <new>
#include <numbers>
#include <random>
#include <string>
#include <thread>
#include <vector>

#include "punch/autoeq.hpp"
#include "punch/character.hpp"
#include "punch/engine.hpp"
#include "punch/lockfree.hpp"
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

int main() {
  for (const auto& t : registry()) {
    const int before = g_failures;
    t.fn();
    std::printf("%s %s\n", g_failures == before ? "[ OK ]" : "[FAIL]", t.name);
  }
  std::printf("\n%d checks, %d failures\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
