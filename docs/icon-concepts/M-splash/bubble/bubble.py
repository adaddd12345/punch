#!/usr/bin/env python3
"""The splash's title bubble: a cobalt speech pill, the mascot saying its name.

    python3 bubble.py   ->  bubble.svg, bubble-dark.svg (and preview.svg, both on fields)

Type: "The Bass Shaker" in a Japanese-bitmap-font-style Latin (after k8x12 /
PixelMplus, the namigroove "TOOLS" title): tall narrow caps, 1 px monoline, solid
square pixels with stepped one-pixel chamfers. Each line is ONE path of merged
horizontal pixel runs, so no seams or dots. A pixel is 1.5 pt = 3 device px at 2x,
so edges land on whole device pixels when the origin sits on a 0.5 pt grid.
The face is WooferFace(ring: false) (= FaceDot), the same numbers as gen.py MODEL4.
Units are points. Groups: bubble-shape, bubble-text (bubble-latin), bubble-face.
"""
import math
from pathlib import Path

HERE = Path(__file__).resolve().parent

# ------------------------------------------------------------- parameters (all of them)
P = dict(
    copy="The Bass Shaker",
    type=dict(
        px=1.5,                # pt per pixel (3 device px at 2x)
        cap=11,                # cap / ascender height in pixels (rows 0..10, baseline under row 10)
        x_height=8,            # lowercase: rows 3..10
        tracking=2,            # pixels between glyphs
        word_space=3,          # extra pixels for a space (plus tracking either side)
        kern={("T", "h"): -1},  # optical pairs, in pixels
    ),
    pill=dict(
        pad_l=13.5, pad_r=4.5, pad_y=9.0,   # pt; pad_r is to the face's keyline
        roundness=1.0,         # corner radius as a fraction of half the height (1 = capsule)
        face_gap=9.0,          # pt between text and face
    ),
    tail=dict(
        w=13.0, h=8.0,         # pt: base width, drop below the pill
        x=0.5,                 # tip position as a fraction of the pill width
        lean=0.0,              # pt the tip shifts sideways from the base centre
        tip_round=1.5,         # pt of rounding at the tip
        root_round=3.0,        # pt fillet where the tail meets the pill
    ),
    face=dict(
        size=None,             # pt diameter of the cone disc (None: pill height - 2 x inset)
        inset=4.0,             # pt from the pill's top/bottom to the face's keyline
        keyline=1.25,          # pt white ring separating cone blue from bubble blue
    ),
    colours=dict(
        light=dict(bubble="#3A63D6", text="#FFFFFF", keyline="#FFFFFF"),
        dark=dict(bubble="#4570E2", text="#FFFFFF", keyline="#EAF0FF"),
        # WooferFace.C and the cone shading
        eye="#2A1B1F", glint="#F6F9FF", cheek="#F49AB8", plate="#3A63D6",
        cone_lo=(0x18, 0x3B, 0xA9), cone_hi=(0x4F, 0x7C, 0xF2),
        field_light="#EEF2FD", field_dark="#0B1120",   # preview only
    ),
)

# ------------------------------------------------------------- glyphs, 11 rows (0 = cap top)
# Caps 6-7 wide, lowercase 5 wide on an 8-row x-height (rows 3..10); 1 px monoline,
# stepped single-pixel chamfers instead of curves.
GLYPHS = {
    "T": ["#######"] + ["...#..."] * 10,
    "B": ["#####.",
          "#....#",
          "#....#",
          "#....#",
          "#####.",
          "#....#",
          "#....#",
          "#....#",
          "#....#",
          "#....#",
          "#####."],
    "S": [".####.",
          "#....#",
          "#.....",
          "#.....",
          ".#....",
          "..##..",
          "....#.",
          ".....#",
          ".....#",
          "#....#",
          ".####."],
    "h": ["#....",
          "#....",
          "#....",
          "#.##.",
          "##..#",
          "#...#",
          "#...#",
          "#...#",
          "#...#",
          "#...#",
          "#...#"],
    "k": ["#....",
          "#....",
          "#....",
          "#...#",
          "#..#.",
          "#.#..",
          "##...",
          "#.#..",
          "#..#.",
          "#...#",
          "#...#"],
    "e": [".....", ".....", ".....",
          ".###.",
          "#...#",
          "#...#",
          "#####",
          "#....",
          "#....",
          "#...#",
          ".###."],
    "a": [".....", ".....", ".....",
          ".###.",
          "....#",
          "....#",
          ".####",
          "#...#",
          "#...#",
          "#..##",
          ".##.#"],
    "s": [".....", ".....", ".....",
          ".####",
          "#....",
          "#....",
          ".###.",
          "....#",
          "....#",
          "....#",
          "####."],
    "r": [".....", ".....", ".....",
          "#.##.",
          "##..#",
          "#....",
          "#....",
          "#....",
          "#....",
          "#....",
          "#...."],
}


# ------------------------------------------------------------- type layout
def layout(text):
    """-> (runs, width_px): runs are (x, y, length) horizontal pixel runs."""
    T = P["type"]
    runs, x, prev = [], 0, None
    for ch in text:
        if ch == " ":
            x += T["word_space"] + T["tracking"]
            prev = None
            continue
        x += T["kern"].get((prev, ch), 0)
        rows = GLYPHS[ch]
        for r, line in enumerate(rows):
            c = 0
            while c < len(line):
                if line[c] == "#":
                    s = c
                    while c < len(line) and line[c] == "#":
                        c += 1
                    runs.append((x + s, r, c - s))
                else:
                    c += 1
        x += len(rows[0]) + T["tracking"]
        prev = ch
    return runs, x - T["tracking"]


def render_type(runs, px, ox, oy):
    """One path: every run a clockwise rectangle, so the fill is their union (no seams)."""
    d = " ".join(f"M{ox + x * px:g},{oy + y * px:g}h{n * px:g}v{px:g}h{-n * px:g}z" for x, y, n in runs)
    return f'<path d="{d}"/>'


# ------------------------------------------------------------- face (WooferFace ring: false)
F = dict(cone=0.86, plate=0.70, eye_dx=0.32, eye_dy=-0.02, eye_rx=0.145, eye_ry=0.19,
         glint=(-0.30, -0.38, 0.42), glint2=(0.38, 0.36, 0.18),
         cheek_dx=0.50, cheek_gap=0.10, cheek_w=0.20, cheek_amp=0.035, cheek_stroke=0.045,
         mouth_w=0.11, mouth_sag=0.5, mouth_stroke=0.05, mouth_dy=0.85)


def cone_colour(a):
    C = P["colours"]
    lx, ly, lz = -0.35, 0.45, 0.82
    lm = math.sqrt(lx * lx + ly * ly + lz * lz)
    tilt = math.atan2(0.03, 0.35 * 0.16)
    u, v = math.cos(a), math.sin(a)
    nx, ny, nz = -u * math.sin(tilt), math.cos(tilt), v * math.sin(tilt)
    t = min(1, max(0, 0.24 + 0.84 * max(0, (nx * lx + ny * ly + nz * lz) / lm)))
    lo, hi = C["cone_lo"], C["cone_hi"]
    return "#" + "".join(f"{round(lo[i] + (hi[i] - lo[i]) * t):02X}" for i in range(3))


def render_face(cx, cy, d, keyline_col):
    C = P["colours"]
    R = d / 2 / F["cone"]                  # model radius: the cone disc is 0.86 R
    rc = F["cone"] * R
    out = [f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="{rc + P["face"]["keyline"]:.2f}" fill="{keyline_col}"/>']
    out.append(f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="{rc:.2f}" fill="{cone_colour(math.pi / 2)}"/>')  # under the wedges: no seams
    n = 48
    for i in range(n):                     # conic shading as wedges (SVG has no conic gradient)
        a0, a1 = 2 * math.pi * i / n, 2 * math.pi * (i + 1.02) / n
        out.append(f'<path d="M{cx:.2f},{cy:.2f} L{cx + rc * math.cos(a0):.3f},{cy + rc * math.sin(a0):.3f} '
                   f'A{rc:.2f},{rc:.2f} 0 0 1 {cx + rc * math.cos(a1):.3f},{cy + rc * math.sin(a1):.3f} Z" '
                   f'fill="{cone_colour(2 * math.pi * (i + 0.5) / n)}"/>')
    out.append(f'<circle cx="{cx:.2f}" cy="{cy:.2f}" r="{F["plate"] * R:.2f}" fill="{C["plate"]}"/>')
    ey = cy + F["eye_dy"] * R
    for s in (-1, 1):
        ex = cx + s * F["eye_dx"] * R
        rx, ry = F["eye_rx"] * R, F["eye_ry"] * R
        out.append(f'<ellipse class="eye" cx="{ex:.2f}" cy="{ey:.2f}" rx="{rx:.2f}" ry="{ry:.2f}" fill="{C["eye"]}"/>')
        for gx, gy, gr in (F["glint"], F["glint2"]):
            out.append(f'<circle class="glint" cx="{ex + gx * rx:.2f}" cy="{ey + gy * ry:.2f}" r="{gr * rx:.2f}" fill="{C["glint"]}"/>')
    # cheeks: one sine period each, starting upward
    chy = ey + (F["eye_ry"] + F["cheek_gap"]) * R
    for s in (-1, 1):
        x0 = cx + (s * F["cheek_dx"] - F["cheek_w"] / 2) * R
        pts = [(x0 + F["cheek_w"] * R * k / 24, chy - F["cheek_amp"] * R * math.sin(2 * math.pi * k / 24))
               for k in range(25)]
        out.append('<polyline fill="none" stroke="{}" stroke-width="{:.2f}" stroke-linecap="round" '
                   'stroke-linejoin="round" points="{}"/>'.format(
                       C["cheek"], F["cheek_stroke"] * R, " ".join(f"{x:.2f},{y:.2f}" for x, y in pts)))
    w, my = F["mouth_w"] * R, ey + F["eye_ry"] * R * F["mouth_dy"]
    sag = w * F["mouth_sag"]
    out.append(f'<path d="M{cx - w:.2f},{my:.2f} Q{cx:.2f},{my + 2 * sag:.2f} {cx + w:.2f},{my:.2f}" fill="none" '
               f'stroke="{C["eye"]}" stroke-width="{F["mouth_stroke"] * R:.2f}" stroke-linecap="round"/>')
    return "\n      ".join(out)


# ------------------------------------------------------------- bubble shape
def bubble_path(W, H):
    """Rounded pill with a tail on the bottom edge; one closed path (fillable, maskable)."""
    Pi, Tl = P["pill"], P["tail"]
    r = min(H / 2, Pi["roundness"] * H / 2)
    tx = Tl["x"] * W
    bl, br = tx - Tl["w"] / 2, tx + Tl["w"] / 2
    tipx, tipy = tx + Tl["lean"], H + Tl["h"]
    f, k = Tl["root_round"], Tl["tip_round"]

    def toward(p, q, d):
        L = math.hypot(q[0] - p[0], q[1] - p[1])
        return (p[0] + (q[0] - p[0]) * d / L, p[1] + (q[1] - p[1]) * d / L)

    tip = (tipx, tipy)
    a_in, a_out = toward(tip, (br, H), k), toward(tip, (bl, H), k)
    rr_in, ll_out = toward((br, H), tip, f), toward((bl, H), tip, f)
    return (f"M{r:.2f},0 H{W - r:.2f} A{r:.2f},{r:.2f} 0 0 1 {W:.2f},{r:.2f} "
            f"V{H - r:.2f} A{r:.2f},{r:.2f} 0 0 1 {W - r:.2f},{H:.2f} "
            f"H{br + f:.2f} Q{br:.2f},{H:.2f} {rr_in[0]:.2f},{rr_in[1]:.2f} "
            f"L{a_in[0]:.2f},{a_in[1]:.2f} Q{tipx:.2f},{tipy:.2f} {a_out[0]:.2f},{a_out[1]:.2f} "
            f"L{ll_out[0]:.2f},{ll_out[1]:.2f} Q{bl:.2f},{H:.2f} {bl - f:.2f},{H:.2f} "
            f"H{r:.2f} A{r:.2f},{r:.2f} 0 0 1 0,{H - r:.2f} V{r:.2f} A{r:.2f},{r:.2f} 0 0 1 {r:.2f},0 Z")




# ------------------------------------------------------------- compose
def snap(v, g=0.5):
    return round(v / g) * g


def build(mode):
    T, Pi, C = P["type"], P["pill"], P["colours"]
    col = C[mode]
    runs, w_px = layout(P["copy"])
    px = T["px"]
    text_w, text_h = w_px * px, T["cap"] * px
    H = snap(text_h + 2 * Pi["pad_y"])
    d = P["face"]["size"] or H - 2 * P["face"]["inset"] - 2 * P["face"]["keyline"]
    W = snap(Pi["pad_l"] + text_w + Pi["face_gap"] + P["face"]["keyline"] * 2 + d + Pi["pad_r"])
    tx, ty = snap(Pi["pad_l"]), snap((H - text_h) / 2)
    face_cx = W - Pi["pad_r"] - P["face"]["keyline"] - d / 2
    face_cy = H / 2
    Ht = H + P["tail"]["h"]
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W:g}" height="{Ht:g}" viewBox="0 0 {W:g} {Ht:g}">
  <!-- The Bass Shaker splash title bubble ({mode}). {W:g} x {H:g} pt pill + {P["tail"]["h"]:g} pt tail.
       Type: {w_px} x {T["cap"]} px at {px:g} pt/px. Generated by bubble.py -->
  <g id="bubble-shape">
    <path d="{bubble_path(W, H)}" fill="{col["bubble"]}"/>
  </g>
  <g id="bubble-text" fill="{col["text"]}">
    <g id="bubble-latin" aria-label="{P["copy"]}">
      {render_type(runs, px, tx, ty)}
    </g>
  </g>
  <g id="bubble-face" data-cx="{face_cx:.2f}" data-cy="{face_cy:.2f}" data-d="{d:.2f}">
      {render_face(face_cx, face_cy, d, col["keyline"])}
  </g>
</svg>
'''
    return svg, W, Ht, H, w_px


def main():
    light, W, Ht, H, w_px = build("light")
    dark, *_ = build("dark")
    (HERE / "bubble.svg").write_text(light)
    (HERE / "bubble-dark.svg").write_text(dark)
    # preview: both on their fields, stacked, 3x (for review only)
    C, s, m = P["colours"], 3, 16
    inner = lambda svg: svg.split(">", 1)[1].rsplit("</svg>", 1)[0]
    pw, ph = W + 2 * m, (Ht + 2 * m) * 2
    prev = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{pw * s:.0f}" height="{ph * s:.0f}" viewBox="0 0 {pw:g} {ph:g}">'
            f'<rect width="{pw:g}" height="{ph / 2:g}" fill="{C["field_light"]}"/>'
            f'<rect y="{ph / 2:g}" width="{pw:g}" height="{ph / 2:g}" fill="{C["field_dark"]}"/>'
            f'<g transform="translate({m},{m})">{inner(light)}</g>'
            f'<g transform="translate({m},{ph / 2 + m:g})">{inner(dark)}</g></svg>')
    (HERE / "preview.svg").write_text(prev)
    print(f"bubble {W:g} x {H:g} pt (+ tail {P['tail']['h']:g} pt); type {w_px} px wide at {P['type']['px']} pt")


if __name__ == "__main__":
    main()
