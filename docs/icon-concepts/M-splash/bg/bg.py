#!/usr/bin/env python3
"""Splash background for The Bass Shaker (360 x 680 pt portrait stage).

Gradients and particles only: a diagonal field, a few huge soft tonal blobs,
a whisper of 1-bit pixel grain, and a flat two-tone wave band at the bottom.
Every movable piece has its own id (blob-0.., wave-back, wave-front) plus a
data-drift="dx,dy" hint (pt per 8 fps step) so the lead can step it later.

  python3 bg.py            -> bg-light.svg, bg-dark.svg
  python3 bg.py --check    -> also check-light.svg (icon cube composited)
"""
import math, random, re, sys, os

W, H = 360, 680

P = {
    # ---- field (same pair as the icon's background) ----
    "field": {"light": ("#E6ECFD", "#D4DEFA"), "dark": ("#1E2A48", "#0B1120")},
    # ---- blobs: (id, cx, cy, r, drift dx,dy per step) ----
    "blobs": [
        ("blob-0",  28, 150, 168, (0.6, -0.4)),   # top-left, behind the title bubble
        ("blob-1", 352, 352, 132, (-0.5, 0.3)),   # right, frames the icon
        ("blob-2",  46, 560, 118, (0.4, 0.4)),    # lower-left, above the wave
        ("blob-3", 300,  28,  70, (-0.3, 0.5)),   # small top-right accent
    ],
    # blob tint + opacity per mode (a few % lighter than the field)
    "blob_fill": {"light": ("#FFFFFF", 0.34), "dark": ("#7D93DB", 0.055)},
    "blob_feather": 0.06,   # fraction of the radius that fades to 0 (soft edge)
    # ---- grain: 1-bit pixel dither ----
    "grain": {
        "seed": 7, "count": 1100, "cell": 2.0, "px": 1.0,  # 1 pt squares on a 2 pt grid
        "bottom_bias": 0.55,  # density ramps toward the bottom (0 = uniform)
        "light": [("#FFFFFF", 0.55, 0.6), ("#5C74C8", 0.10, 0.4)],  # (colour, opacity, share)
        "dark":  [("#A9BAF0", 0.10, 0.7), ("#000000", 0.18, 0.3)],
    },
    # ---- wave band: two flat layers, bottom edge ----
    "wave": [
        # id, baseline y, [(amplitude, wavelength, phase)], drift
        ("wave-back",  610, [(11, 320, 0.6), (4, 140, 2.1)], (-1.0, 0)),
        ("wave-front", 640, [(9, 250, 2.4), (3, 115, 0.3)], (1.0, 0)),
    ],
    "wave_fill": {"light": ("#CBD6F7", "#C1CDF4"), "dark": ("#141C35", "#19233F")},
}


def blob_defs(mode):
    col, op = P["blob_fill"][mode]
    f = 1 - P["blob_feather"]
    return (f'<radialGradient id="bs-blob-{mode}" cx="0.5" cy="0.5" r="0.5">'
            f'<stop offset="0" stop-color="{col}" stop-opacity="{op}"/>'
            f'<stop offset="{f:.3f}" stop-color="{col}" stop-opacity="{op}"/>'
            f'<stop offset="1" stop-color="{col}" stop-opacity="0"/></radialGradient>')


def wave_path(y0, comps, x_pad=24):
    pts = []
    for i in range(0, int(W + 2 * x_pad) + 1, 4):
        x = i - x_pad
        y = y0 + sum(a * math.sin(2 * math.pi * x / wl + ph) for a, wl, ph in comps)
        pts.append(f"{x:.1f},{y:.2f}")
    return f"M{-x_pad},{H + 4} L" + " L".join(pts) + f" L{W + x_pad},{H + 4} Z"


def grain(mode):
    g = P["grain"]
    rnd = random.Random(g["seed"])
    cols, n, cell, px, bias = g[mode], g["count"], g["cell"], g["px"], g["bottom_bias"]
    buckets = {i: [] for i in range(len(cols))}
    seen = set()
    while sum(len(b) for b in buckets.values()) < n:
        cx, cy = rnd.randrange(int(W / cell)), rnd.randrange(int(H / cell))
        if (cx, cy) in seen:
            continue
        # density weight ramps toward the bottom
        if rnd.random() > (1 - bias) + bias * (cy * cell / H):
            continue
        seen.add((cx, cy))
        r, acc = rnd.random(), 0
        for i, (_, _, share) in enumerate(cols):
            acc += share
            if r <= acc:
                break
        buckets[i].append(f"M{cx*cell:.0f},{cy*cell:.0f}h{px:g}v{px:g}h-{px:g}z")
    return "".join(f'<path fill="{cols[i][0]}" fill-opacity="{cols[i][1]}" d="{"".join(d)}"/>'
                   for i, d in buckets.items())


def svg(mode, inner_extra=""):
    a, b = P["field"][mode]
    blobs = "".join(
        f'<circle id="{i}" cx="{x}" cy="{y}" r="{r}" fill="url(#bs-blob-{mode})" data-drift="{d[0]},{d[1]}"/>'
        for i, x, y, r, d in P["blobs"])
    waves = "".join(
        f'<path id="{i}" d="{wave_path(y0, comps)}" fill="{P["wave_fill"][mode][k]}" data-drift="{d[0]},{d[1]}"/>'
        for k, (i, y0, comps, d) in enumerate(P["wave"]))
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}">'
            f'<defs><linearGradient id="bs-field-{mode}" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="{W}" y2="{H}">'
            f'<stop offset="0" stop-color="{a}"/><stop offset="1" stop-color="{b}"/></linearGradient>'
            f'{blob_defs(mode)}<clipPath id="bs-stage"><rect width="{W}" height="{H}"/></clipPath></defs>'
            f'<g clip-path="url(#bs-stage)">'
            f'<rect id="bg-field" width="{W}" height="{H}" fill="url(#bs-field-{mode})"/>'
            f'<g id="bg-blobs">{blobs}</g>'
            f'<g id="bg-grain">{grain(mode)}</g>'
            f'<g id="bg-wave">{waves}</g>'
            f'{inner_extra}</g></svg>\n')


def icon_cube(width=150, cy=372):
    src = "/Users/adam2/Developer/punch/docs/icon-concepts/K-isometric/A-origami-cube/release/icon.svg"
    s = open(src).read()
    s = re.sub(r'<path id="squircle"[^>]*/>', "", s)
    body = s[s.index(">") + 1: s.rindex("</svg>")]
    k = width / (807.65 - 216.35)
    tx, ty = W / 2 - 512 * k, cy - 540 * k
    return f'<g id="check-icon" transform="translate({tx:.2f},{ty:.2f}) scale({k:.4f})">{body}</g>'


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    for m in ("light", "dark"):
        open(os.path.join(here, f"bg-{m}.svg"), "w").write(svg(m))
    if "--check" in sys.argv:
        open(os.path.join(here, "check-light.svg"), "w").write(svg("light", icon_cube()))


def render():
    """qlmanage crops thumbnails to a square: wrap each stage in a square viewBox,
    render at 720 px, then crop the stage back out with sips."""
    import subprocess, tempfile
    here = os.path.dirname(os.path.abspath(__file__))
    tmp = tempfile.mkdtemp(dir=here)
    pad = (H - W) / 2
    for name in ("bg-light", "bg-dark", "check-light"):
        src = os.path.join(here, f"{name}.svg")
        if not os.path.exists(src):
            continue
        s = open(src).read().replace(f'viewBox="0 0 {W} {H}" width="{W}" height="{H}"',
                                     f'viewBox="{-pad} 0 {H} {H}" width="{H}" height="{H}"')
        sq = os.path.join(tmp, f"{name}.svg")
        open(sq, "w").write(s)
        subprocess.run(["qlmanage", "-t", "-s", "720", "-o", tmp, sq], capture_output=True)
        out = os.path.join(here, f"{name}.png")
        k = 720 / H
        subprocess.run(["sips", "-c", "720", str(round(W * k)), os.path.join(tmp, f"{name}.svg.png"),
                        "--out", out], capture_output=True)
    subprocess.run(["rm", "-rf", tmp])


if __name__ == "__main__" and "--render" in sys.argv:
    render()
