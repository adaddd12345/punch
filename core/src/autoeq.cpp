#include "punch/autoeq.hpp"

#include <cctype>
#include <cmath>
#include <cstdio>
#include <locale>
#include <sstream>
#include <optional>
#include <vector>

namespace punch {

namespace {

std::vector<std::string_view> tokenize(std::string_view line) {
  std::vector<std::string_view> out;
  size_t i = 0;
  while (i < line.size()) {
    while (i < line.size() && std::isspace(static_cast<unsigned char>(line[i]))) ++i;
    const size_t start = i;
    while (i < line.size() && !std::isspace(static_cast<unsigned char>(line[i]))) ++i;
    if (i > start) out.push_back(line.substr(start, i - start));
  }
  return out;
}

bool iequals(std::string_view a, std::string_view b) {
  if (a.size() != b.size()) return false;
  for (size_t i = 0; i < a.size(); ++i)
    if (std::tolower(static_cast<unsigned char>(a[i])) != std::tolower(static_cast<unsigned char>(b[i]))) return false;
  return true;
}

std::optional<double> number(std::string_view s) {
  // Not std::from_chars: Apple's libc++ lacks the floating-point overloads
  // for our deployment target. Not strtod: it follows the C locale's
  // decimal separator. The classic locale always parses "6.5".
  std::istringstream in{std::string(s)};
  in.imbue(std::locale::classic());
  double v = 0;
  in >> v;
  if (in.fail() || !std::isfinite(v)) return std::nullopt;
  in.peek();
  if (!in.eof()) return std::nullopt;  // trailing junk
  return v;
}

std::optional<FilterType> filterType(std::string_view t, double* defaultQ) {
  *defaultQ = 0.7071;
  if (iequals(t, "PK") || iequals(t, "PEQ")) return FilterType::Bell;
  // LS/HS in Equalizer APO are fixed-slope (Q 0.7071); LSC/HSC carry a Q.
  if (iequals(t, "LS") || iequals(t, "LSC") || iequals(t, "LSQ")) return FilterType::LowShelf;
  if (iequals(t, "HS") || iequals(t, "HSC") || iequals(t, "HSQ")) return FilterType::HighShelf;
  if (iequals(t, "LP") || iequals(t, "LPQ")) return FilterType::LowPass;
  if (iequals(t, "HP") || iequals(t, "HPQ")) return FilterType::HighPass;
  if (iequals(t, "BP")) return FilterType::BandPass;
  if (iequals(t, "NO")) return FilterType::Notch;
  return std::nullopt;
}

const char* typeCode(FilterType t) {
  switch (t) {
    case FilterType::Bell: return "PK";
    case FilterType::LowShelf: return "LSC";
    case FilterType::HighShelf: return "HSC";
    case FilterType::LowPass: return "LPQ";
    case FilterType::HighPass: return "HPQ";
    case FilterType::BandPass: return "BP";
    case FilterType::Notch: return "NO";
  }
  return "PK";
}

}  // namespace

ParseResult parseEqualizerApo(std::string_view text) {
  ParseResult r;
  size_t pos = 0;
  while (pos <= text.size()) {
    size_t eol = text.find('\n', pos);
    if (eol == std::string_view::npos) eol = text.size();
    std::string_view line = text.substr(pos, eol - pos);
    pos = eol + 1;
    if (const size_t hash = line.find('#'); hash != std::string_view::npos) line = line.substr(0, hash);
    const auto tok = tokenize(line);
    if (tok.empty()) continue;

    if (iequals(tok[0], "Preamp:")) {
      if (tok.size() >= 2) {
        if (auto v = number(tok[1])) {
          r.params.preampDb = float(*v);
          continue;
        }
      }
      ++r.skippedLines;
      continue;
    }

    if (tok[0].size() < 6 || !iequals(tok[0].substr(0, 6), "Filter")) {
      ++r.skippedLines;
      continue;
    }
    // "Filter" ["N"] ":" or "FilterN:" variants; find the ON/OFF token.
    size_t i = 1;
    while (i < tok.size() && !iequals(tok[i], "ON") && !iequals(tok[i], "OFF")) ++i;
    if (i + 1 >= tok.size()) {
      ++r.skippedLines;
      continue;
    }
    const bool on = iequals(tok[i], "ON");
    double defaultQ = 0.7071;
    const auto type = filterType(tok[i + 1], &defaultQ);
    if (!type) {
      ++r.skippedLines;
      continue;
    }
    FilterSpec spec;
    spec.type = *type;
    spec.enabled = on;
    spec.q = defaultQ;
    bool haveFc = false;
    for (size_t k = i + 2; k + 1 < tok.size(); ++k) {
      if (iequals(tok[k], "Fc")) {
        if (auto v = number(tok[k + 1])) { spec.freqHz = *v; haveFc = true; }
      } else if (iequals(tok[k], "Gain")) {
        if (auto v = number(tok[k + 1])) spec.gainDb = *v;
      } else if (iequals(tok[k], "Q")) {
        if (auto v = number(tok[k + 1]); v && *v > 0) spec.q = *v;
      } else if (iequals(tok[k], "BW")) {
        // "BW Oct x": convert bandwidth in octaves to Q.
        if (k + 2 < tok.size() && iequals(tok[k + 1], "Oct")) {
          if (auto v = number(tok[k + 2]); v && *v > 0) {
            const double p2 = std::pow(2.0, *v);
            spec.q = std::sqrt(p2) / (p2 - 1.0);
          }
        }
      }
    }
    if (!haveFc || spec.freqHz <= 0) {
      ++r.skippedLines;
      continue;
    }
    if (r.params.numBands >= kMaxEqBands) {
      r.truncated = true;
      continue;
    }
    r.params.bands[size_t(r.params.numBands++)] = spec;
  }
  return r;
}

std::string formatEqualizerApo(const EqParams& p) {
  std::string out;
  char line[160];
  std::snprintf(line, sizeof line, "Preamp: %.1f dB\n", double(p.preampDb));
  out += line;
  for (int i = 0; i < p.numBands; ++i) {
    const FilterSpec& b = p.bands[size_t(i)];
    std::snprintf(line, sizeof line, "Filter %d: %s %s Fc %.0f Hz Gain %.1f dB Q %.2f\n", i + 1,
                  b.enabled ? "ON" : "OFF", typeCode(b.type), b.freqHz, b.gainDb, b.q);
    out += line;
  }
  return out;
}

}  // namespace punch
