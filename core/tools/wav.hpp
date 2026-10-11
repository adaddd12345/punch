// Minimal RIFF/WAVE reader/writer for offline testing (PCM 16/24/32, float32).
#pragma once

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

namespace wav {

struct Audio {
  int sampleRate = 48000;
  int channels = 2;
  std::vector<float> samples;  // interleaved
  int frames() const { return channels ? int(samples.size() / size_t(channels)) : 0; }
};

inline bool read(const std::string& path, Audio& out, std::string& err) {
  FILE* f = std::fopen(path.c_str(), "rb");
  if (!f) { err = "cannot open " + path; return false; }
  std::vector<unsigned char> d;
  unsigned char buf[65536];
  size_t n;
  while ((n = std::fread(buf, 1, sizeof buf, f)) > 0) d.insert(d.end(), buf, buf + n);
  std::fclose(f);
  auto u16 = [&](size_t o) { return uint32_t(d[o]) | uint32_t(d[o + 1]) << 8; };
  auto u32 = [&](size_t o) { return u16(o) | u16(o + 2) << 16; };
  if (d.size() < 12 || std::memcmp(d.data(), "RIFF", 4) || std::memcmp(d.data() + 8, "WAVE", 4)) {
    err = "not a WAVE file"; return false;
  }
  int fmt = 0, bits = 0;
  size_t p = 12;
  while (p + 8 <= d.size()) {
    const uint32_t sz = u32(p + 4);
    const size_t body = p + 8;
    if (body + sz > d.size()) break;
    if (!std::memcmp(&d[p], "fmt ", 4) && sz >= 16) {
      fmt = int(u16(body));
      out.channels = int(u16(body + 2));
      out.sampleRate = int(u32(body + 4));
      bits = int(u16(body + 14));
      if (fmt == 0xFFFE && sz >= 26) fmt = int(u16(body + 24));  // WAVE_FORMAT_EXTENSIBLE subformat
    } else if (!std::memcmp(&d[p], "data", 4)) {
      const int bps = bits / 8;
      if (out.channels <= 0 || bps <= 0) { err = "fmt chunk missing"; return false; }
      const size_t count = sz / size_t(bps);
      out.samples.resize(count);
      for (size_t i = 0; i < count; ++i) {
        const unsigned char* s = &d[body + i * size_t(bps)];
        float v = 0;
        if (fmt == 3 && bits == 32) std::memcpy(&v, s, 4);
        else if (fmt == 1 && bits == 16) v = float(int16_t(uint16_t(s[0] | s[1] << 8))) / 32768.f;
        else if (fmt == 1 && bits == 24) v = float(int32_t(uint32_t(s[0] << 8 | s[1] << 16 | s[2] << 24)) >> 8) / 8388608.f;
        else if (fmt == 1 && bits == 32) v = float(double(int32_t(uint32_t(s[0] | s[1] << 8 | s[2] << 16 | uint32_t(s[3]) << 24))) / 2147483648.0);
        else { err = "unsupported sample format"; return false; }
        out.samples[i] = v;
      }
      return true;
    }
    p = body + sz + (sz & 1);
  }
  err = "no data chunk";
  return false;
}

inline bool writeFloat(const std::string& path, const Audio& a) {
  FILE* f = std::fopen(path.c_str(), "wb");
  if (!f) return false;
  const uint32_t dataBytes = uint32_t(a.samples.size() * 4);
  auto w32 = [&](uint32_t v) { std::fwrite(&v, 4, 1, f); };
  auto w16 = [&](uint16_t v) { std::fwrite(&v, 2, 1, f); };
  std::fwrite("RIFF", 1, 4, f); w32(36 + dataBytes); std::fwrite("WAVE", 1, 4, f);
  std::fwrite("fmt ", 1, 4, f); w32(16); w16(3); w16(uint16_t(a.channels)); w32(uint32_t(a.sampleRate));
  w32(uint32_t(a.sampleRate * a.channels * 4)); w16(uint16_t(a.channels * 4)); w16(32);
  std::fwrite("data", 1, 4, f); w32(dataBytes);
  std::fwrite(a.samples.data(), 4, a.samples.size(), f);
  return std::fclose(f) == 0;
}

}  // namespace wav
