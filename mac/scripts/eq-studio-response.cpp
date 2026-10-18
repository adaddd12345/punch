#include "eq-studio-response.h"
#include "punch/svf.hpp"
#include <array>

// Review uses the production filter equations, not an approximate drawn curve.
extern "C" void eq_studio_response(double rate, double selected_gain, double *response,
                                    double *without_selected, size_t count) {
  if (!response || !without_selected || count < 2 || !std::isfinite(rate) || rate <= 0) return;
  using punch::FilterType;
  const std::array<punch::FilterSpec, 6> bands{{
    {FilterType::LowShelf, 80, 3, 0.71, true},
    {FilterType::Bell, 150, 2, 1, true},
    {FilterType::Bell, 400, -4, 1.4, true},
    {FilterType::Bell, 1500, 1.5, 1, true},
    {FilterType::Bell, 8000, selected_gain, 2, true},
    {FilterType::HighShelf, 14000, 2, 0.71, true},
  }};
  std::array<punch::SvfCoeffs, 6> coefficients;
  for (size_t b = 0; b < bands.size(); ++b) coefficients[b] = punch::SvfCoeffs::make(bands[b], rate);
  for (size_t i = 0; i < count; ++i) {
    const double frequency = 20 * std::pow(1000, double(i) / double(count - 1));
    double total = 0, other = 0;
    for (size_t b = 0; b < bands.size(); ++b) {
      const double db = coefficients[b].magnitudeDb(frequency, rate);
      total += db;
      if (b != 4) other += db;
    }
    response[i] = total;
    without_selected[i] = other;
  }
}
