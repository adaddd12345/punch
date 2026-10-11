// Loudness / "something is fighting the EQ" analyser.
//
// Synthesises a loud, modern-master-style track (kick, 808, hats and a
// steady 1 kHz probe tone), runs it through the real engine in IO-sized
// blocks, and reports, per configuration:
//   * level change overall, in the bass and in the mids (dB vs input)
//   * pumping: how far the steady 1 kHz probe dips when the kick hits
//     (anything the chain does to the whole signal shows up here)
//   * limiter gain reduction (mean / 95th percentile)
//   * output peak
//
//   punch_loudness [--wav out_prefix]
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <numbers>
#include <random>
#include <string>
#include <vector>

#include "punch/engine.hpp"
#include "punch/limiter.hpp"
#include "punch/svf.hpp"
#include "wav.hpp"

using namespace punch;

namespace {

constexpr double kFs = 48000;
constexpr int kBlock = 512;
constexpr double kSeconds = 12;
constexpr double kProbeHz = 1000;

struct Track {
  std::vector<float> l, r;
};

// Loud master: kick on every beat (120 bpm), sustained 808 notes, hats on
// 16ths, a steady -24 dBFS 1 kHz probe; then mastered with a brickwall to
// -0.3 dBFS peak with ~5 dB of gain reduction, like commercial releases.
Track makeTrack(bool bassOnly = false) {
  const int n = int(kSeconds * kFs);
  Track t{std::vector<float>(size_t(n), 0.f), std::vector<float>(size_t(n), 0.f)};
  std::mt19937 rng(7);
  std::uniform_real_distribution<float> uni(-1.f, 1.f);
  SvfCoeffs hatHp = SvfCoeffs::make({FilterType::HighPass, 7000, 0, 0.7071, true}, kFs);
  SvfState hs;
  const double notes[] = {41.2, 41.2, 49.0, 36.7};
  double kickPhase = 0, bassPhase = 0;
  for (int i = 0; i < n; ++i) {
    const double ts = i / kFs;
    const double tk = std::fmod(ts, 0.5);
    const double f = 45 + 90 * std::exp(-tk / 0.025);
    kickPhase += 2 * std::numbers::pi * f / kFs;
    const double kick = std::sin(kickPhase) * std::exp(-tk / 0.22);
    const double tb = std::fmod(ts, 2.0);
    const double fb = notes[int(ts / 2.0) % 4];
    bassPhase += 2 * std::numbers::pi * fb / kFs;
    const double b808 = 0.7 * std::sin(bassPhase) * std::exp(-tb / 1.6) * std::min(1.0, tb / 0.004);
    const double th = std::fmod(ts, 0.125);
    const double hat = 0.18 * hs.tick(hatHp, uni(rng)) * std::exp(-th / 0.018);
    const double probe = 0.063 * std::sin(2 * std::numbers::pi * kProbeHz * ts);  // -24 dBFS
    const float m = float(0.9 * kick + b808 + (bassOnly ? 0.0 : probe));
    t.l[size_t(i)] = m + (bassOnly ? 0.f : float(hat));
    t.r[size_t(i)] = m + (bassOnly ? 0.f : float(0.8 * hat));
  }
  // Master: +gain into a slow brickwall, ceiling -0.3 dBFS.
  float peak = 0;
  for (int i = 0; i < n; ++i) peak = std::max({peak, std::fabs(t.l[size_t(i)]), std::fabs(t.r[size_t(i)])});
  const float pre = dbToGain(5.f) / peak;
  for (int i = 0; i < n; ++i) { t.l[size_t(i)] *= pre; t.r[size_t(i)] *= pre; }
  Limiter lim;
  lim.prepare(kFs, 2, 3.f);
  lim.setParams({-0.3f, 250.f, true});
  float* ch[2] = {t.l.data(), t.r.data()};
  for (int s = 0; s < n; s += kBlock) {
    float* p[2] = {ch[0] + s, ch[1] + s};
    lim.process(p, 2, std::min(kBlock, n - s));
  }
  // Remove the mastering limiter's latency so input and output line up.
  const int lat = lim.latencyFrames();
  for (auto* v : {&t.l, &t.r}) {
    v->erase(v->begin(), v->begin() + lat);
    v->resize(size_t(n), 0.f);
  }
  return t;
}

double rmsDb(const std::vector<float>& x, int from) {
  double s = 0;
  for (size_t i = size_t(from); i < x.size(); ++i) s += double(x[i]) * x[i];
  return 10 * std::log10(s / double(x.size() - size_t(from)) + 1e-20);
}

std::vector<float> filtered(const std::vector<float>& x, FilterSpec spec, int passes = 1) {
  std::vector<float> y = x;
  for (int p = 0; p < passes; ++p) {
    SvfCoeffs c = SvfCoeffs::make(spec, kFs);
    SvfState s;
    for (auto& v : y) v = s.tick(c, v);
  }
  return y;
}

// Envelope of the 1 kHz probe in 10 ms windows (dB), after a narrow band-pass.
std::vector<double> probeEnvelope(const std::vector<float>& x, int from) {
  auto y = filtered(x, {FilterType::BandPass, kProbeHz, 0, 12, true}, 2);
  std::vector<double> env;
  const int w = int(0.01 * kFs);
  for (size_t i = size_t(from); i + size_t(w) <= y.size(); i += size_t(w)) {
    double s = 0;
    for (int k = 0; k < w; ++k) s += double(y[i + size_t(k)]) * y[i + size_t(k)];
    env.push_back(10 * std::log10(s / w + 1e-20));
  }
  return env;
}

double pct(std::vector<double> v, double p) {
  std::sort(v.begin(), v.end());
  return v[size_t(std::clamp(p, 0.0, 1.0) * double(v.size() - 1))];
}

struct Config {
  std::string name;
  // nodes: LS, bell x4, HS (Hz, dB, Q)
  double nodes[6][3];
  float bass = 0;
  float boostDb = 0;
  bool autoPreamp = true;
  bool limiter = true;
  float limiterReleaseMs = 80;
  float slowReleaseMs = 0;
  float clipKneeDb = 0;
  float bassHz = 0;
  CompressorParams comp{};
  SaturatorParams sat{};
};

void configure(Engine& e, const Config& c) {
  auto& p = e.edit();
  p = EngineParams{};
  p.eq.numBands = 6;
  for (int i = 0; i < 6; ++i) {
    const FilterType t = i == 0 ? FilterType::LowShelf : i == 5 ? FilterType::HighShelf : FilterType::Bell;
    p.eq.bands[size_t(i)] = {t, c.nodes[i][0], c.nodes[i][1], c.nodes[i][2], true};
  }
  p.autoPreamp = c.autoPreamp;
  p.bass = {c.bass, 110.f, 4.f, c.bass > 0};
  p.outputGainDb = c.boostDb;
  p.limiter = {-1.f, c.limiterReleaseMs, c.limiter, c.slowReleaseMs, c.clipKneeDb, c.bassHz};
  p.compressor = c.comp;
  p.saturator = c.sat;
  e.publish();
}

}  // namespace

int main(int argc, char** argv) {
  std::string wavPrefix;
  for (int i = 1; i + 1 < argc; i += 2)
    if (std::strcmp(argv[i], "--wav") == 0) wavPrefix = argv[i + 1];

  const Track in = makeTrack();
  const Track bassTrack = makeTrack(true);
  const int n = int(in.l.size());
  const int skip = int(1.0 * kFs);  // ignore the first second (settling)

  const double flat[6][3] = {{80, 0, .71}, {150, 0, 1}, {400, 0, 1}, {1500, 0, 1}, {4000, 0, 1}, {10000, 0, .71}};
  const double shake[6][3] = {{105, 5, .71}, {55, 3, 1.2}, {250, -2, 1}, {1000, 0, 1}, {3500, 1.5, 1}, {10000, 1.5, .71}};
  const double boost[6][3] = {{100, 8, .71}, {150, 0, 1}, {300, -1.5, 1}, {1500, 0, 1}, {4000, 0, 1}, {10000, 0, .71}};
  const double rap[6][3] = {{100, 3.5, .71}, {280, -3, 1.1}, {900, 1.5, .9}, {3000, 2.5, 1}, {7000, -1.5, 2.5}, {10000, 1.5, .71}};

  std::vector<Config> configs;
  configs.reserve(64);  // add() hands out pointers into it
  auto add = [&](std::string name, const double (&nodes)[6][3], float bass, float boostDb, bool ap, bool lim) {
    Config c;
    c.name = std::move(name);
    std::memcpy(c.nodes, nodes, sizeof(c.nodes));
    c.bass = bass;
    c.boostDb = boostDb;
    c.autoPreamp = ap;
    c.limiter = lim;
    configs.push_back(c);
    return &configs.back();
  };
  // "before": full-band limiter + worst-case auto-headroom (beta <= 27).
  add("Flat", flat, 0, 0, true, true);
  add("OLD Bass Shake", shake, 0.55f, 0, true, true);
  add("OLD Bass Shake +6 Boost", shake, 0.55f, 6, true, true);
  add("OLD Bass Shake +12 Boost", shake, 0.55f, 12, true, true);
  add("OLD Bass Boost", boost, 0.35f, 0, true, true);
  auto* oldRap = add("OLD Underground Rap", rap, 0.55f, 1, true, true);
  oldRap->comp = {-18, 3, 25, 120, 6, 3, 90, true};
  oldRap->sat = {9, 0.35f, 7500, 0.25f, 120, true};
  add("No Limit", shake, 0.55f, 0, false, false);
  // "after": bass-priority limiter at 150 Hz; auto-headroom ignores bass.
  auto bp = [&](std::string name, const double (&nodes)[6][3], float bass, float boostDb) {
    auto* c = add(std::move(name), nodes, bass, boostDb, true, true);
    c->bassHz = 150;
    return c;
  };
  bp("NEW Bass Shake", shake, 0.55f, 0);
  bp("NEW Bass Shake +6 Boost", shake, 0.55f, 6);
  bp("NEW Bass Shake +12 Boost", shake, 0.55f, 12);
  bp("NEW Bass Boost", boost, 0.35f, 0);
  auto* newRap = bp("NEW Underground Rap", rap, 0.55f, 1);
  newRap->comp = {-18, 3, 25, 120, 6, 3, 90, true};
  newRap->sat = {9, 0.35f, 7500, 0.25f, 120, true};

  // Input reference numbers.
  const auto inBass = filtered(in.l, {FilterType::LowPass, 120, 0, .7071, true}, 2);
  const auto inMid = filtered(in.l, {FilterType::HighPass, 300, 0, .7071, true}, 2);
  const auto inEnv = probeEnvelope(in.l, skip);
  auto dirtBand = [&](const std::vector<float>& x) {
    auto y = filtered(x, {FilterType::HighPass, 1500, 0, .7071, true}, 2);
    y = filtered(y, {FilterType::LowPass, 5000, 0, .7071, true}, 2);
    return rmsDb(y, skip);
  };
  const double inDirt = dirtBand(in.l);
  const double inAll = rmsDb(in.l, skip), inB = rmsDb(inBass, skip), inM = rmsDb(inMid, skip);
  const double inProbe = pct(inEnv, 0.5);
  std::printf("input: rms %.1f dBFS, bass %.1f, mids %.1f, probe median %.1f dB, probe dip (p50-p2) %.2f dB\n\n",
              inAll, inB, inM, inProbe, inProbe - pct(inEnv, 0.02));
  std::printf("%-30s %7s %7s %7s %9s %9s %9s %8s %8s\n", "config", "preamp", "all", "bass", "mids", "probeΔ",
              "pump dB", "GR mean", "GR p95");
  std::printf("%-30s\n", "(dist: distortion+IMD of a bass-only master, dB below output; lower = cleaner)");

  for (const auto& c : configs) {
    Engine e;
    e.prepare(kFs, 2, kBlock);
    configure(e, c);
    std::vector<float> l = in.l, rr = in.r;
    std::vector<double> gr;
    float outPeak = 0;
    for (int s = 0; s < n; s += kBlock) {
      const int m = std::min(kBlock, n - s);
      float* p[2] = {l.data() + s, rr.data() + s};
      e.processPlanar(p, 2, m);
      const Meters mt = e.takeMeters();
      if (s >= skip) gr.push_back(-mt.gainReductionDb);
      outPeak = std::max({outPeak, mt.outPeak[0], mt.outPeak[1]});
    }
    // Align for latency.
    const int lat = e.latencyFrames();
    for (auto* v : {&l, &rr}) { v->erase(v->begin(), v->begin() + lat); v->resize(size_t(n), 0.f); }
    if (!wavPrefix.empty()) {
      wav::Audio a;
      a.sampleRate = int(kFs);
      a.channels = 2;
      a.samples.resize(size_t(n) * 2);
      for (int i = 0; i < n; ++i) { a.samples[size_t(i) * 2] = l[size_t(i)]; a.samples[size_t(i) * 2 + 1] = rr[size_t(i)]; }
      std::string fn = wavPrefix + "-" + c.name + ".wav";
      std::replace(fn.begin(), fn.end(), ' ', '_');
      wav::writeFloat(fn, a);
    }
    // Distortion: bass-only master through the same config; everything in
    // 1.5-5 kHz is distortion/IMD (input there is ~silent), relative to the
    // output's total level.
    double thd;
    {
      Engine e2;
      e2.prepare(kFs, 2, kBlock);
      configure(e2, c);
      Track b = bassTrack;
      for (int s2 = 0; s2 < n; s2 += kBlock) {
        float* p[2] = {b.l.data() + s2, b.r.data() + s2};
        e2.processPlanar(p, 2, std::min(kBlock, n - s2));
      }
      auto y = filtered(b.l, {FilterType::HighPass, 1500, 0, .7071, true}, 3);
      y = filtered(y, {FilterType::LowPass, 5000, 0, .7071, true}, 2);
      thd = rmsDb(y, skip) - rmsDb(b.l, skip);
    }
    const auto ob = filtered(l, {FilterType::LowPass, 120, 0, .7071, true}, 2);
    const auto om = filtered(l, {FilterType::HighPass, 300, 0, .7071, true}, 2);
    const auto env = probeEnvelope(l, skip);
    const double probeMed = pct(env, 0.5);
    const double pump = probeMed - pct(env, 0.02);
    std::printf("%-30s %+7.1f %+7.1f %+7.1f %+9.1f %+9.1f %9.2f %8.2f %8.2f  dist %+6.1f  peak %.2f\n", c.name.c_str(),
                e.effectivePreampDb(), rmsDb(l, skip) - inAll, rmsDb(ob, skip) - inB, rmsDb(om, skip) - inM,
                probeMed - inProbe, pump, pct(gr, 0.5), pct(gr, 0.95), thd, outPeak);
  }
  std::printf("\nprobeΔ: level change of the steady 1 kHz tone (static EQ at 1 kHz is ~0 dB in all presets),\n"
              "pump dB: how far that tone dips below its median (input baseline shown above).\n");
  return 0;
}
