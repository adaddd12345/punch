// Import/export of Equalizer APO "ParametricEQ.txt" text, the format the
// AutoEq project (github.com/jaakkopasanen/AutoEq) publishes headphone
// correction profiles in, e.g.
//
//   Preamp: -6.2 dB
//   Filter 1: ON LSC Fc 105 Hz Gain 6.5 dB Q 0.70
//   Filter 2: ON PK Fc 2363 Hz Gain 3.2 dB Q 2.12
//
// Control-thread only.
#pragma once

#include <string>
#include <string_view>

#include "punch/parametric_eq.hpp"

namespace punch {

struct ParseResult {
  EqParams params;
  int skippedLines = 0;   // unrecognised filter types / malformed lines
  bool truncated = false; // more than kMaxEqBands filters present
  bool ok() const { return params.numBands > 0 || params.preampDb != 0.f; }
};

ParseResult parseEqualizerApo(std::string_view text);
std::string formatEqualizerApo(const EqParams& p);

}  // namespace punch
