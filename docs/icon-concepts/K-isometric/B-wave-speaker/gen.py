#!/usr/bin/env python3
"""The Bass Shaker, concept K/B "Wave speaker".

A Japanese-isometric speaker block with a low-poly origami wave (the bass)
standing on it. The wave is the mascot: glossy eyes, "~" blush, tiny mouth.

Everything is built in 3D world units and projected isometrically:
    x -> screen right-down (cos30, sin30)
    y -> screen left-down  (-cos30, sin30)
    z -> screen up
The viewer looks along -(1,1,1), so faces with n.(1,1,1) > 0 are visible.
Light comes from the screen's top-left: top brightest, +y (left) face next,
+x (right) face darkest. Facet colours are quantised to a small palette.

Run:  python3 gen.py   -> icon.svg next to this file.
"""
import math
import os

C, S = math.cos(math.radians(30)), math.sin(math.radians(30))
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "icon.svg")

# ---------------------------------------------------------------- palette
BG_TOP = "#eaf0fe"     # pale sky
BG_BOT = "#d3ddf7"     # periwinkle
WHITE = "#ffffff"      # speaker top / foam
PAPER = "#e4eafb"      # speaker left face
SHADE = "#b4c3ee"      # speaker right face, ground shadow family
LIGHT = "#6f93f0"      # lit blue facet
COBALT = "#3a63d6"     # app cobalt
DEEP = "#2442a8"       # deep blue facet / woofer surround
INK = "#3a2116"        # eyes (glossy dark brown)
TOPS = "#a9c0fa"       # lit paper edge
FOAM = "#c6d0ee"       # crest shade (flat grey-blue, like the mascot cap)
T_HI, T_LO = 0.60, 0.44

# ---------------------------------------------------------------- geometry
A = 236.0              # speaker footprint (x and y)
H = 168.0              # speaker height
BEV = 14.0             # one bevel width for every speaker edge
L = (-0.30, 0.62, 1.0)
_l = math.sqrt(sum(v * v for v in L)); L = tuple(v / _l for v in L)


def proj(p):
    x, y, z = p
    return ((x - y) * C, (x + y) * S - z)


def dot(a, b): return sum(i * j for i, j in zip(a, b))
def sub(a, b): return tuple(i - j for i, j in zip(a, b))
def cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])
def norm(v):
    n = math.sqrt(dot(v, v)); return tuple(i / n for i in v)
def lam(n): return max(0.0, dot(norm(n), L))


def hexmix(a, b, t):
    pa = [int(a[i:i + 2], 16) for i in (1, 3, 5)]
    pb = [int(b[i:i + 2], 16) for i in (1, 3, 5)]
    return "#" + "".join(f"{round(x + (y - x) * t):02x}" for x, y in zip(pa, pb))


# ---------------------------------------------------------------- speaker
def chamfer_box(hx, hy, hz, b, cz):
    """Convex box with every edge chamfered by b. Returns visible faces."""
    verts = []
    for sx in (-1, 1):
        for sy in (-1, 1):
            for sz in (-1, 1):
                verts += [(sx * hx, sy * (hy - b), sz * (hz - b) + cz),
                          (sx * (hx - b), sy * hy, sz * (hz - b) + cz),
                          (sx * (hx - b), sy * (hy - b), sz * hz + cz)]
    faces = []
    for nx in (-1, 0, 1):
        for ny in (-1, 0, 1):
            for nz in (-1, 0, 1):
                n = (nx, ny, nz)
                if n == (0, 0, 0) or nx + ny + nz <= 0:
                    continue
                m = max(dot(n, (v[0], v[1], v[2] - cz)) for v in verts)
                pts = list({v for v in verts if abs(dot(n, (v[0], v[1], v[2] - cz)) - m) < 1e-6})
                if len(pts) < 3:
                    continue
                cx = sum(p[0] for p in pts) / len(pts)
                cy = sum(p[1] for p in pts) / len(pts)
                cc = sum(p[2] for p in pts) / len(pts)
                u = norm(sub(pts[0], (cx, cy, cc)))
                w = cross(norm(n), u)
                pts.sort(key=lambda p: math.atan2(dot(sub(p, (cx, cy, cc)), w),
                                                  dot(sub(p, (cx, cy, cc)), u)))
                faces.append((n, pts))
    return faces


def box_colour(n):
    k = sum(abs(i) for i in n)
    if n == (0, 0, 1): return WHITE
    if n == (0, 1, 0): return PAPER
    if n == (1, 0, 0): return SHADE
    # bevels and corners: blend the faces they join (keeps the bevel family flat)
    base = {(0, 0, 1): WHITE, (0, 1, 0): PAPER, (1, 0, 0): SHADE}
    cols = [base[(1 if i == 0 else 0, 1 if i == 1 else 0, 1 if i == 2 else 0)]
            for i in range(3) if n[i] == 1]
    if n == (0, 1, 1): return "#f6f8ff"      # lit top-left edge: a bright rim
    if n == (1, 0, 1): return "#dbe3fa"
    if n == (1, 1, 0): return "#ccd7f6"
    return "#e9eefc"                          # corner


# ---------------------------------------------------------------- polygons
def poly(pts, fill, extra="", seam=True):
    d = " ".join(f"{x:.2f},{y:.2f}" for x, y in pts)
    st = f' stroke="{fill}" stroke-width="0.8" stroke-linejoin="round"' if seam else ""
    return f'<polygon points="{d}" fill="{fill}"{st}{extra}/>'


def main():
    hx = hy = A / 2
    out = {k: [] for k in ("shadow", "body", "woofer", "wave", "foam",
                          "eyes", "cheeks", "mouth")}

    # speaker
    for n, pts in sorted(chamfer_box(hx, hy, H / 2, BEV, H / 2), key=lambda f: sum(f[0])):
        out["body"].append(poly([proj(p) for p in pts], box_colour(n)))

    # ground shadow: footprint pushed away from the light (+x), flat tint
    k_sh = 0.42 * H / L[2]
    off = (-L[0] * k_sh, -L[1] * k_sh)
    foot = [(-hx + BEV, -hy + BEV), (hx - BEV, -hy + BEV), (hx - BEV, hy - 2 * BEV), (-hx + BEV, hy - 2 * BEV)]
    pts2 = [proj((x, y, 0)) for x, y in foot] + [proj((x + off[0], y + off[1], 0)) for x, y in foot]
    # convex hull (monotone chain)
    pts2 = sorted(set(pts2))
    def half(ps):
        h = []
        for p_ in ps:
            while len(h) >= 2 and ((h[-1][0] - h[-2][0]) * (p_[1] - h[-2][1]) - (h[-1][1] - h[-2][1]) * (p_[0] - h[-2][0])) <= 0:
                h.pop()
            h.append(p_)
        return h
    hull = half(pts2)[:-1] + half(pts2[::-1])[:-1]
    out["shadow"].append(poly(hull, "#c8d2f3", seam=False))

    # woofer: low-poly cone on the +y face, recessed toward -y
    yf = hy
    cx, cz = 0.0, H / 2
    N = 16
    R0, R1, R2, R3 = 0.40 * H, 0.35 * H, 0.31 * H, 0.125 * H
    def ring(r, y, rot=0.0):
        return [(cx + r * math.cos(2 * math.pi * (i + rot) / N), y,
                 cz + r * math.sin(2 * math.pi * (i + rot) / N)) for i in range(N)]
    rim = ring(R0, yf + 0.5)
    out["woofer"].append(poly([proj(p) for p in rim], WHITE))          # trim
    sur = ring(R1, yf + 0.6)
    out["woofer"].append(poly([proj(p) for p in sur], DEEP))           # surround
    cone_o = ring(R2, yf + 0.7)
    REC = 0.10 * R2
    cone_i = ring(R3, yf - REC)
    facets = []
    for i in range(N):
        j = (i + 1) % N
        q = [cone_o[i], cone_o[j], cone_i[j], cone_i[i]]
        nrm = cross(sub(q[1], q[0]), sub(q[3], q[0]))
        if nrm[1] < 0: nrm = tuple(-v for v in nrm)
        s = lam(nrm)
        col = COBALT if s > 0.49 else DEEP
        facets.append((sum(p[0] + p[1] + p[2] for p in q) / 4, q, col))
    for _, q, col in sorted(facets, key=lambda t: t[0]):
        out["woofer"].append(poly([proj(p) for p in q], col))
    # dust cap: a low dome of 8 facets
    cap_c = (cx, yf - REC + 0.6 * R3, cz)
    cap = ring(R3, yf - REC)
    for i in range(N):
        j = (i + 1) % N
        t = [cap[i], cap[j], cap_c]
        nrm = cross(sub(t[1], t[0]), sub(t[2], t[0]))
        if nrm[1] < 0: nrm = tuple(-v for v in nrm)
        s = lam(nrm)
        col = "#9db6f6" if s > 0.66 else LIGHT
        out["woofer"].append(poly([proj(p) for p in t], col))

    # wave: an extruded origami profile standing on the top face, plane y = yw
    W = 2 * hx + 6         # base width along x
    x0 = -W / 2
    yw = -hy * 0.02                  # front plane of the wave
    T = 0.24 * A                        # paper thickness
    z0 = H
    U = [  # (u, v, relief) in units of W; boundary counter-clockwise from the front foot
        (0.00, 0.00, 0), (1.00, 0.00, 0), (1.06, 0.26, 0), (0.98, 0.56, 0),
        (0.80, 0.84, 0), (0.56, 1.02, 0), (0.28, 1.05, 0), (0.06, 0.93, 0),
        (-0.17, 0.62, 0), (0.03, 0.68, 0), (0.09, 0.50, 0), (0.21, 0.64, 0),
        (0.30, 0.50, 0), (0.13, 0.36, 0), (0.03, 0.16, 0),
        # interior folds: a back spine and the crest ridge
        (0.84, 0.30, 0.14), (0.78, 0.60, 0.13), (0.50, 0.80, 0.03), (0.33, 0.87, 0.03),
    ]
    NB = 15
    def wpt(i, front=True):
        u, v, d = U[i]
        y = yw + d * W if front else yw - T
        return (x0 + u * W, y, z0 + v * W)
    # sides of the paper (only the boundary)
    sides = []
    for i in range(NB):
        j = (i + 1) % NB
        du, dv = U[j][0] - U[i][0], U[j][1] - U[i][1]
        n3 = (dv, 0.0, -du)
        if n3[0] + n3[2] <= 1e-9:
            continue
        q = [wpt(i), wpt(j), wpt(j, False), wpt(i, False)]
        depth = sum(p[0] + p[1] + p[2] for p in q) / 4
        s = lam(n3)
        if 5 <= i <= 10:   # crest edges carry the foam
            col = WHITE if s > 0.55 else FOAM
        else:
            col = TOPS if s > 0.55 else (LIGHT if s > 0.2 else COBALT)
        sides.append((depth, q, col))
    for _, q, col in sorted(sides, key=lambda t: t[0]):
        out["wave"].append(poly([proj(p) for p in q], col))
    blue = [(0, 1, 17), (1, 15, 17), (1, 2, 15), (2, 3, 15), (3, 16, 15), (15, 16, 17),
            (3, 4, 16), (4, 17, 16), (4, 5, 17), (5, 18, 17), (0, 17, 12), (12, 17, 18),
            (11, 12, 18), (0, 12, 13), (0, 13, 14)]
    crest = [(5, 6, 18), (6, 7, 18), (7, 11, 18), (7, 8, 9), (7, 9, 11), (9, 10, 11)]
    for tri in blue:
        P = [wpt(i) for i in tri]
        nrm = cross(sub(P[1], P[0]), sub(P[2], P[0]))
        if nrm[1] < 0: nrm = tuple(-v for v in nrm)
        s = lam(nrm)
        col = LIGHT if s > T_HI else (COBALT if s > T_LO else DEEP)
        out["wave"].append(poly([proj(p) for p in P], col, f' data-s="{s:.2f}"'))
    for tri in crest:
        P = [wpt(i) for i in tri]
        nrm = cross(sub(P[1], P[0]), sub(P[2], P[0]))
        if nrm[1] < 0: nrm = tuple(-v for v in nrm)
        out["wave"].append(poly([proj(p) for p in P], WHITE if lam(nrm) > T_LO + 0.04 else FOAM))

    # foam: 7 dots, the shaker's holes, spraying off the curl tip (wave plane)
    # the shaker lid's 7 holes on the top face, in front of the wave
    hcx, hcy, hr, hs = 0.0, (yw + hy - BEV) / 2 + 4, 7.0, 21.0
    holes = [(0, 0)] + [(hs * math.cos(math.pi / 3 * i + math.pi / 6),
                         hs * math.sin(math.pi / 3 * i + math.pi / 6)) for i in range(6)]
    for dx, dy in holes:
        ring_ = [proj((hcx + dx + hr * math.cos(t / 12 * math.tau),
                       hcy + dy + hr * math.sin(t / 12 * math.tau), H)) for t in range(12)]
        out["foam"].append(poly(ring_, SHADE))

    # face decal: drawn in local (u, w) units, mapped onto the wave's front plane
    fy = yw + 0.04 * W
    o = proj((x0, fy, z0))
    face_tf = f'matrix({C:.5f} {S:.5f} 0 1 {o[0]:.2f} {o[1]:.2f})'   # (u,w) -> plane, w = -z
    ex = [0.42 * W, 0.65 * W]
    ey = -0.36 * W
    erx, ery = 0.064 * W, 0.086 * W
    for e in ex:
        out["eyes"].append(f'<ellipse cx="{e:.2f}" cy="{ey:.2f}" rx="{erx:.2f}" ry="{ery:.2f}" fill="{INK}"/>')
        out["eyes"].append(f'<circle cx="{e - 0.022 * W:.2f}" cy="{ey - 0.032 * W:.2f}" r="{0.024 * W:.2f}" fill="{WHITE}"/>')
        out["eyes"].append(f'<circle cx="{e + 0.020 * W:.2f}" cy="{ey + 0.030 * W:.2f}" r="{0.011 * W:.2f}" fill="{WHITE}"/>')
    sw = 0.016 * W
    for e in ex:
        bx, by, a = e - 0.02 * W, ey + 0.135 * W, 0.028 * W
        out["cheeks"].append(
            f'<path d="M{bx - 1.5 * a:.2f},{by:.2f} q{a / 2:.2f},{-a * 0.7:.2f} {a:.2f},0 '
            f't{a:.2f},0 t{a:.2f},0" fill="none" stroke="{TOPS}" stroke-width="{sw:.2f}" '
            f'stroke-linecap="round" stroke-linejoin="round"/>')
    mx, my, mw = (ex[0] + ex[1]) / 2, ey + 0.085 * W, 0.034 * W
    out["mouth"].append(
        f'<path d="M{mx - mw:.2f},{my:.2f} q{mw:.2f},{mw * 0.9:.2f} {2 * mw:.2f},0" fill="none" '
        f'stroke="{INK}" stroke-width="{sw:.2f}" stroke-linecap="round"/>')

    # ---------------------------------------------------------- layout
    # bbox of everything in world-projected space, then centre on the canvas
    xs, ys = [], []
    for g in ("body", "wave", "shadow"):
        for el in out[g]:
            nums = el.split('points="')[1].split('"')[0].split()
            for pr in nums:
                a_, b_ = pr.split(","); xs.append(float(a_)); ys.append(float(b_))
    bw, bh = max(xs) - min(xs), max(ys) - min(ys)
    target = 640.0
    k = target / max(bw, bh)
    tx = 512 - k * (min(xs) + max(xs)) / 2
    ty = 512 - k * (min(ys) + max(ys)) / 2 + 4      # optical: sit a hair low
    world = f'matrix({k:.4f} 0 0 {k:.4f} {tx:.2f} {ty:.2f})'

    # squircle (superellipse n=5), the macOS 824 body at offset 100
    n, a = 5.0, 412.0
    pts = []
    for i in range(360):
        t = 2 * math.pi * i / 360
        ct, st = math.cos(t), math.sin(t)
        pts.append((512 + a * math.copysign(abs(ct) ** (2 / n), ct),
                    512 + a * math.copysign(abs(st) ** (2 / n), st)))
    sq = "M" + " L".join(f"{x:.2f},{y:.2f}" for x, y in pts) + " Z"

    def g(id_, items, tf=None):
        t = f' transform="{tf}"' if tf else ""
        return f'<g id="{id_}"{t}>\n  ' + "\n  ".join(items) + "\n</g>"

    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="{BG_TOP}"/><stop offset="1" stop-color="{BG_BOT}"/>
  </linearGradient>
  <clipPath id="squircle"><path d="{sq}"/></clipPath>
</defs>
<path id="plate" d="{sq}" fill="url(#bg)"/>
<g clip-path="url(#squircle)">
<g id="art" transform="{world}">
{g("shadow", out["shadow"])}
{g("body", out["body"])}
{g("woofer", out["woofer"])}
{g("wave", out["wave"])}
{g("lid-holes", out["foam"])}
<g id="face" transform="{face_tf}">
{g("face-eyes", out["eyes"])}
{g("face-cheeks", out["cheeks"])}
{g("face-mouth", out["mouth"])}
</g>
</g>
</g>
</svg>
'''
    with open(OUT, "w") as f:
        f.write(svg)
    print("wrote", OUT, f"scale={k:.3f}")


if __name__ == "__main__":
    main()
