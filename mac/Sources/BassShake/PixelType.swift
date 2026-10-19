import SwiftUI

/// A tiny dot-matrix face for the Tempo tools: 5 × 7 glyphs drawn as soft
/// square dots, so the pixel look needs no font file and takes the theme's ink.
enum PixelFont {
  static let columns = 5, rows = 7

  /// Each glyph: seven rows of five, `#` lit. Unknown characters draw nothing.
  static let glyphs: [Character: [String]] = [
    "0": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
    "3": ["#####", "...#.", "..#..", "...#.", "....#", "#...#", ".###."],
    "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
    "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
    "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
    "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
    "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
    "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
    "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
    "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
    "D": ["###..", "#..#.", "#...#", "#...#", "#...#", "#..#.", "###.."],
    "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
    "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
    "G": [".###.", "#...#", "#....", "#.###", "#...#", "#...#", ".####"],
    "H": ["#...#", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "I": [".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "J": ["..###", "...#.", "...#.", "...#.", "...#.", "#..#.", ".##.."],
    "K": ["#...#", "#..#.", "#.#..", "##...", "#.#..", "#..#.", "#...#"],
    "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
    "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
    "N": ["#...#", "#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#"],
    "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
    "Q": [".###.", "#...#", "#...#", "#...#", "#.#.#", "#..#.", ".##.#"],
    "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
    "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
    "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
    "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
    "W": ["#...#", "#...#", "#...#", "#.#.#", "#.#.#", "#.#.#", ".#.#."],
    "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
    "Y": ["#...#", "#...#", ".#.#.", "..#..", "..#..", "..#..", "..#.."],
    "Z": ["#####", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
    "m": [".....", ".....", "##.#.", "#.#.#", "#.#.#", "#...#", "#...#"],
    "#": [".#.#.", ".#.#.", "#####", ".#.#.", "#####", ".#.#.", ".#.#."],
    "♯": [".#.#.", ".#.#.", "#####", ".#.#.", "#####", ".#.#.", ".#.#."],
    "♭": ["#....", "#....", "#.##.", "##..#", "#...#", "#..#.", "###.."],
    "−": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
    "-": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
    "+": [".....", "..#..", "..#..", "#####", "..#..", "..#..", "....."],
    ".": [".....", ".....", ".....", ".....", ".....", ".##..", ".##.."],
    ":": [".....", ".##..", ".##..", ".....", ".##..", ".##..", "....."],
    "!": ["..#..", "..#..", "..#..", "..#..", "..#..", ".....", "..#.."],
    "&": [".##..", "#..#.", "#.#..", ".#...", "#.#.#", "#..#.", ".##.#"],
    "%": ["##...", "##..#", "...#.", "..#..", ".#...", "#..##", "...##"],
    "?": [".###.", "#...#", "....#", "...#.", "..#..", ".....", "..#.."],
  ]

  /// Lit cells of one glyph, as (column, row) with row 0 at the top.
  private static let lit: [Character: [(Int, Int)]] = glyphs.mapValues { rows in
    rows.enumerated().flatMap { r, line in
      line.enumerated().compactMap { c, ch in ch == "#" ? (c, r) : nil }
    }
  }

  static func cells(_ ch: Character) -> [(Int, Int)] {
    lit[ch] ?? lit[Character(ch.uppercased())] ?? []
  }

  /// Glyph cells across a string: five per glyph and one between; a space is three.
  static func width(_ text: String) -> Int {
    guard !text.isEmpty else { return 0 }
    return text.reduce(0) { $0 + ($1 == " " ? 3 : columns) } + (text.count - 1)
  }
}

/// A string in the dot-matrix face. `dot` is one cell's pitch in points; the
/// lit square fills `fill` of it, with soft corners.
struct PixelText: View {
  let text: String
  var dot: CGFloat = 4
  var fill: CGFloat = 0.8
  var color: Color = .primary

  init(_ text: String, dot: CGFloat = 4, fill: CGFloat = 0.8, color: Color = .primary) {
    self.text = text; self.dot = dot; self.fill = fill; self.color = color
  }

  var body: some View {
    let w = CGFloat(PixelFont.width(text)) * dot, h = CGFloat(PixelFont.rows) * dot
    Canvas { ctx, _ in
      var path = Path()
      let side = dot * fill, inset = (dot - side) / 2
      var x: CGFloat = 0
      for ch in text {
        if ch == " " { x += 4 * dot; continue }
        // A dash is one soft bar, not five dots (a run reads as a dotted line).
        if ch == "−" || ch == "-" {
          path.addRoundedRect(in: CGRect(x: x + inset, y: 3 * dot + inset, width: 5 * dot - 2 * inset, height: side),
                              cornerSize: CGSize(width: side / 2, height: side / 2))
          x += CGFloat(PixelFont.columns + 1) * dot
          continue
        }
        for (c, r) in PixelFont.cells(ch) {
          path.addRoundedRect(in: CGRect(x: x + CGFloat(c) * dot + inset, y: CGFloat(r) * dot + inset,
                                         width: side, height: side),
                              cornerSize: CGSize(width: side * 0.3, height: side * 0.3))
        }
        x += CGFloat(PixelFont.columns + 1) * dot
      }
      ctx.fill(path, with: .color(color))
    }
    .frame(width: max(0, w), height: h)
    .accessibilityElement()
    .accessibilityLabel(text)
  }
}
