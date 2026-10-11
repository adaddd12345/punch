import Foundation

/// Headphone-specific presets: a 6-node fit of each model's measured
/// deviation from the Harman target plus a modest bass lift.
/// Sources and fitting method: docs/research/16-headphone-presets.md.
enum HeadphonePresets {
  /// Measurements: AutoEq (github.com/jaakkopasanen/AutoEq) data by
  /// oratory1990, Rtings and DHRME; credit belongs to them.
  static let all: [Preset] = [
    // Built on original AirPods Max data (Max 2 keeps the same basic tuning;
    // no published Max 2 measurement yet). Small shelf: Adaptive EQ partly
    // undoes static bass, so the lift comes from Shake instead.
    Preset(name: "AirPods Max 2", nodes: [(105, 0.5, 0.71), (220, -2, 1), (1_000, -2, 1.2), (3_200, 2, 1), (5_800, 3.5, 0.9), (10_000, -4, 0.71)],
           bass: 0.35, symbol: "airpodsmax",
           subtitle: "Fills AirPods Max's 4–8 kHz dip and trims its lower-mid hump, toward the Harman target plus a bass lift."),
    // Assumes ANC on. Treble only partly restored (it's already sharp).
    Preset(name: "Powerbeats Pro 2", nodes: [(105, 2.5, 0.71), (330, 1.5, 0.7), (1_700, -1.5, 0.7), (2_550, -1.5, 2.5), (6_000, -1, 2), (8_500, 4, 0.71)],
           bass: 0.30, symbol: "earbuds",
           subtitle: "Softens the forward 2.5 kHz and restores some of the top-end roll-off. Tuned with ANC on."),
    Preset(name: "B&W Px7 S2e", nodes: [(105, -3.5, 0.71), (200, -2.5, 1.2), (1_000, -1, 1.5), (2_000, 4, 1.8), (5_300, 1.5, 1.5), (10_000, 0, 0.71)],
           bass: 0.20, symbol: "headphones",
           subtitle: "Tightens the Px7 S2e's heavy mid-bass and fills its 2 kHz hole for clearer vocals; Strength keeps the punch."),
  ]
}
