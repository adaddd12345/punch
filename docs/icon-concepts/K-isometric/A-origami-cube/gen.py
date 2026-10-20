#!/usr/bin/env python3
"""Origami speaker cube: The Bass Shaker icon in true isometric projection.

Everything is computed: a chamfered (low-poly) box is projected with the
30-degree isometric map, each visible facet is shaded flat from one light
vector, and the woofer / face live in the front-left face's own plane via an
affine matrix, so a later face animation can work in flat face coordinates.

    python3 gen.py       ->  icon.svg   (v1)
    python3 gen.py --v2  ->  icon2.svg  (A2: cobalt sides)
    python3 gen.py --v3  ->  icon3.svg  (v3: one parametric 3D scene, MODEL3 below)
    python3 gen.py --v4  ->  icon4.svg  (v4: v3 after review, MODEL4 below)
    python3 gen.py --release -> release/: icon{,-dark,-freezing,-ember,-mono}.svg and
                             layers/{,dark/,mono/}{1-cube,2-lid,3-woofer,background}.svg
"""
import math
import sys
from pathlib import Path

# =====================================================================
# v3 MODEL (python3 gen.py --v3 -> icon3.svg). One parametric 3D scene:
# every length is in body units (the cube's width = 1), every angle in
# degrees. Change anything here and the icon regenerates correctly.
# The face sizes are fractions of the woofer radius, measured in the
# face plate's own (u, v) plane: u = world +x, v = world DOWN (-z), so the
# face's "up" is the cube's world up.
# =====================================================================
MODEL3 = dict(
    camera=dict(yaw=45.0, pitch=math.degrees(math.atan(1 / math.sqrt(2)))),   # true isometric
    light=dict(dir=(-0.35, 0.45, 0.82), ambient=0.24, diffuse=0.84),          # one sun + ambient
    body=dict(w=1.0, d=1.0, h=0.94, bevel=0.07),
    lid=dict(inset=0.21, height=0.045, round=0.03, round_steps=2, corner=0.05),
    holes=dict(r=0.028, pitch=0.112, depth=0.03, angle=45.0, segments=64),
    woofer=dict(r=0.37, cx=0.5, cz=0.475, wall=0.03, ring=0.14, cone_depth=0.03,
                plate=0.70, pleats=24, segments=160),
    face=dict(eye_dx=0.32, eye_dy=-0.02, eye_rx=0.145, eye_ry=0.19,
              glint=(-0.30, -0.38, 0.42), glint2=(0.38, 0.36, 0.18),          # (dx, dy, r) in eye radii
              cheek_dx=0.50, cheek_gap=0.10, cheek_w=0.20, cheek_amp=0.035, cheek_stroke=0.045,
              mouth_w=0.07, mouth_sag=0.45, mouth_stroke=0.04, mouth_dy=0.85, samples=96),
    frame=dict(height=596.0, cx=506.0, cy=520.0, squircle_n=5.0),
    materials=dict(                       # (shadow colour, lit colour): t = ambient + diffuse * max(0, n.L)
        body=("#506DCC", "#FFFFFF"),
        lid=("#506AC3", "#D9E1FB"),
        ring=("#0A1045", "#2A3FAE"),
        cone=("#183BA9", "#4F7CF2"),
        hole=("#0A1045", "#202F8C"),
        eye=("#180E0D", "#35232A"),
        glint=("#E8EEFF", "#FFFFFF"),
        blush=("#E286A5", "#FFA6C4"),
    ),
    ground=dict(colour="#C3D0F4", contact=0.30),   # shadow cast by the lowest 30% of the body
    background=("#E6ECFD", "#D4DEFA"),
)

# =====================================================================
# v4 MODEL (python3 gen.py --v4 -> icon4.svg): v3's scene after review.
# Woofer radius is derived from a margin, the lid gets back a gentle tent
# fold with a body-style 45-degree chamfer, the contact shadow is ambient
# occlusion (footprint + bevel overhang, Gaussian-softened), the cone is
# smooth, and the frame is centred from the body + shadow bounds.
# =====================================================================
# The angled view the app icon used before going face on: isometric turned 20 deg
# toward the woofer and tilted 1.5 deg flatter. The menu-bar template keeps it.
ANGLED_CAMERA = dict(yaw=45.0 - 20.0, pitch=math.degrees(math.atan(1 / math.sqrt(2))) - 1.5)

MODEL4 = dict(
    # The app icon looks straight at the woofer (picked in viewer.py's Face on).
    camera=dict(yaw=0.0, pitch=0.0),
    light=dict(dir=(-0.35, 0.45, 0.82), ambient=0.24, diffuse=0.84),          # one sun + ambient
    body=dict(w=1.0, d=1.0, h=0.94, bevel=0.07),
    lid=dict(inset=0.18, height=0.07, bevel=0.045, ridge=0.025),               # tent fold: back -> front corner
    holes=dict(r=0.032, pitch=0.125, depth=0.07, angle=45.0, segments=72),     # depth >= 2r
    woofer=dict(margin=0.05, cx=0.5, cz=0.5, wall=0.03, ring=0.14, cone_depth=0.03,
                plate=0.70, segments=160),                                    # R = min(W-2c, H-2c)/2 - margin
    face=dict(eye_dx=0.32, eye_dy=-0.02, eye_rx=0.145, eye_ry=0.19,
              glint=(-0.30, -0.38, 0.42), glint2=(0.38, 0.36, 0.18),
              cheek_dx=0.50, cheek_gap=0.10, cheek_w=0.20, cheek_amp=0.035, cheek_stroke=0.045,
              mouth_w=0.11, mouth_sag=0.5, mouth_stroke=0.05, mouth_dy=0.85, samples=96),
    frame=dict(height=612.0, squircle=(100.0, 100.0, 824.0), squircle_n=5.0),  # body+shadow box height, px
    render=dict(seam_px=0.5),   # every facet carries a 0.5 px outline in its own colour: one uniform
                                # overlap so exactly-abutting facets show no antialiasing seams
    materials=dict(             # (shadow colour, lit colour): t = ambient + diffuse * max(0, n.L)
        body=("#506DCC", "#FFFFFF"),
        recess=("#3A4FA5", "#8498DB"),
        lid=("#506AC3", "#D9E1FB"),
        ring=("#0A1045", "#2A3FAE"),
        cone=("#183BA9", "#4F7CF2"),
        hole=("#0A1045", "#2A3FAE"),
        eye=("#180E0D", "#35232A"),
        glint=("#E8EEFF", "#FFFFFF"),
        blush=("#E286A5", "#FFA6C4"),
        ground=("#506DCC", None),   # lit colour derived so the sunlit ground equals the field
    ),
    ground=dict(softness=0.06, occlusion=1.0),   # AO removes `occlusion` x the ambient term
    background=("#E6ECFD", "#D4DEFA"),
)

# Colourways for the release set: palette only (materials + field). Every
# colour is still a (shadow, lit) material lit by MODEL4's one light, so the
# shading stays geometric. light = MODEL4 itself.
PALETTES4 = dict(
    light=dict(),
    dark=dict(                      # night field, deep-navy cube, luminous woofer
        background=("#1E2A48", "#0B1120"),
        materials=dict(
            body=("#0A1230", "#5C76C6"), recess=("#040820", "#1E2E66"),
            lid=("#141E48", "#8296D8"), ring=("#050C38", "#2A4AC8"),
            cone=("#2457E0", "#8FB8FF"), hole=("#02040E", "#0C1438"),
            eye=("#180E0D", "#35232A"), glint=("#E8EEFF", "#FFFFFF"),
            blush=("#E286A5", "#FFB2CC"), ground=("#000000", None))),
    freezing=dict(                  # icy navy-to-cyan
        background=("#0A1F5C", "#1B9ED2"),
        materials=dict(
            body=("#0A2E8C", "#D2F3FF"), recess=("#041654", "#2A5FCC"),
            lid=("#4A6688", "#F6FBFF"), ring=("#020C3A", "#1238A0"),
            cone=("#0E2A9A", "#4E8CF2"), hole=("#06102E", "#1B3566"),
            eye=("#100A14", "#2A2234"), glint=("#E8FBFF", "#FFFFFF"),
            blush=("#D07AB0", "#FFB8DC"), ground=("#020A30", None))),
    ember=dict(                     # obsidian body, gunmetal cap, molten woofer
        background=("#2A0608", "#B23A18"),
        materials=dict(
            body=("#140E0F", "#7A5A50"), recess=("#120606", "#4A1E16"),
            lid=("#2A2424", "#9A8E88"), ring=("#2A0406", "#B22A14"),
            cone=("#A01A08", "#FFA040"), hole=("#B8400C", "#FF8A2A"),
            eye=("#1A0A06", "#2E1610"), glint=("#FFE8CC", "#FFFBEA"),
            blush=("#C0405A", "#FFD0B8"), ground=("#0A0000", None))),
    mono=dict(                      # tinted appearance: greys, the woofer is the white hero
        background=("#3A3A3C", "#1C1C1E"),
        materials=dict(
            body=("#3A3A3A", "#B4B4B4"), recess=("#202020", "#585858"),
            lid=("#484848", "#CACACA"), ring=("#8A8A8A", "#E2E2E2"),
            cone=("#C4C4C4", "#FFFFFF"), hole=("#080808", "#262626"),
            eye=("#0A0A0A", "#1E1E1E"), glint=("#F2F2F2", "#FFFFFF"),
            blush=("#6A6A6A", "#A8A8A8"), ground=("#000000", None))),
)

OUT = Path(__file__).with_name("icon.svg")

# ---------------------------------------------------------------- palette
BG_A = "#E6ECFD"      # periwinkle field, top-left
BG_B = "#D4DEFA"      # periwinkle field, bottom-right (very subtle diagonal)
TOP = "#F7F9FF"       # lit top (pure white is kept for the lit bevels)
MID = "#C0CCF2"       # left face (woofer face)
DARK = "#7A90D8"      # right face
COBALT = "#3A63D6"    # cone
NAVY = "#1E2D86"      # surround, holes
INK = "#2A1B1F"       # eyes / mouth: the mascot's glossy dark brown
BLUSH = "#F49AB8"     # "~" cheeks
SHADOW = "#BFCDF3"    # flat ground shadow
CONE_OUT = "#3155C2"  # outer cone fold (cobalt, one step down)
LID_TOP, LID_MID, LID_DARK = "#CFD9F9", "#A3B3EA", "#6F85D2"   # the shaker lid: periwinkle
WALL = DARK                      # inside wall of the woofer recess
CONE_IN = COBALT                 # inner cone
FACE = dict(ex=0.32, ey=-0.02, erx=0.145, ery=0.19, cheek_x=0.50, cheek_w=0.20, cheek_dy=0.10,
            cheek_sw=0.045, mouth_w=0.07, mouth_sw=0.04, cone_split=0.70, tilt=0.0)

# ---- A2 (python3 gen.py --v2): cobalt sides for contrast, a pale cone with a
# face ~1.7x bigger, partly counter-sheared so it doesn't look crooked, and a
# lighter shaker lid.
V2 = "--v2" in sys.argv
if V2:
    OUT = OUT.with_name("icon2.svg")
    TOP = "#DCE4FB"                       # pale top
    MID = "#3A63D6"                       # lit side (woofer face)
    DARK = "#2A46A8"                      # shaded side
    NAVY = "#17246E"                      # surround, holes
    WALL = "#203a93"
    CONE_OUT, CONE_IN = "#D5DFFB", "#F1F5FF"   # a pale paper cone
    LID_TOP, LID_MID, LID_DARK = "#F6F8FF", "#DCE4FB", "#B8C6F1"
    SHADOW = "#BCCAF2"
    FACE = dict(ex=0.40, ey=-0.06, erx=0.235, ery=0.31, cheek_x=0.56, cheek_w=0.26, cheek_dy=0.08,
                cheek_sw=0.075, mouth_w=0.12, mouth_sw=0.065, cone_split=0.80, tilt=0.268)

# ---------------------------------------------------------------- geometry
COS30 = math.cos(math.radians(30))
LIGHT = (-0.35, 0.45, 0.82)   # from the upper-left: top light, left mid, right dark

W = 1.0          # body width / depth
H = 0.94         # body height (a touch squat = cuter)
C = 0.07         # bevel (chamfer) width, used everywhere
LID_M = 0.15     # lid inset from the body edge
LID_H = 0.05 if "--v2" in sys.argv else 0.075   # lid thickness at its low corners
LID_RIDGE = 0.035 # extra height of the fold along the diagonal

SCALE = 300.0    # px per unit, refined by fit()
TX, TY = 512.0, 512.0


def iso(p):
    x, y, z = p
    return ((x - y) * COS30 * SCALE + TX, ((x + y) * 0.5 - z) * SCALE + TY)


def hexc(h):
    h = h.lstrip("#")
    return [int(h[i:i + 2], 16) for i in (0, 2, 4)]


def mix(a, b, t):
    a, b = hexc(a), hexc(b)
    return "#%02X%02X%02X" % tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def norm(v):
    m = math.sqrt(sum(c * c for c in v))
    return tuple(c / m for c in v)


L = norm(LIGHT)
B_RIGHT = L[0]          # brightness of +x face
B_LEFT = L[1]           # +y face
B_TOP = L[2]            # +z face


def shade(n, top=TOP, mid=MID, dark=DARK, hi="#FFFFFF"):
    """Flat Lambert value mapped piecewise through the three anchor colours."""
    b = sum(a * c for a, c in zip(norm(n), L))
    if b > B_TOP + 1e-9:   # turned further toward the light than the top
        return mix(top, hi, min(1.0, (b - B_TOP) / (1 - B_TOP) * 1.5))
    if b >= B_LEFT:
        return mix(mid, top, (b - B_LEFT) / (B_TOP - B_LEFT))
    if b >= B_RIGHT:
        return mix(dark, mid, (b - B_RIGHT) / (B_LEFT - B_RIGHT))
    # below the right face (the under-bevel): a little deeper than dark
    return mix(dark, NAVY, min(0.35, (B_RIGHT - b) * 0.35))


def box_facets(x0, x1, y0, y1, z0, z1, c, cb):
    """Visible facets of a box with chamfered top + vertical edges (c) and
    bottom edges (cb), seen from the isometric direction (1,1,1)."""
    f = []
    f.append(((0, 0, 1), [(x0 + c, y0 + c, z1), (x1 - c, y0 + c, z1), (x1 - c, y1 - c, z1), (x0 + c, y1 - c, z1)]))
    f.append(((1, 0, 0), [(x1, y0 + c, z1 - c), (x1, y1 - c, z1 - c), (x1, y1 - c, z0 + cb), (x1, y0 + c, z0 + cb)]))
    f.append(((0, 1, 0), [(x0 + c, y1, z1 - c), (x1 - c, y1, z1 - c), (x1 - c, y1, z0 + cb), (x0 + c, y1, z0 + cb)]))
    f.append(((1, 0, 1), [(x1 - c, y0 + c, z1), (x1 - c, y1 - c, z1), (x1, y1 - c, z1 - c), (x1, y0 + c, z1 - c)]))
    f.append(((0, 1, 1), [(x0 + c, y1 - c, z1), (x1 - c, y1 - c, z1), (x1 - c, y1, z1 - c), (x0 + c, y1, z1 - c)]))
    f.append(((1, 1, 0), [(x1 - c, y1, z1 - c), (x1, y1 - c, z1 - c), (x1, y1 - c, z0 + cb), (x1 - c, y1, z0 + cb)]))
    f.append(((1, 1, 1), [(x1 - c, y1 - c, z1), (x1, y1 - c, z1 - c), (x1 - c, y1, z1 - c)]))
    f.append(((1, -1, 1), [(x1 - c, y0 + c, z1), (x1, y0 + c, z1 - c), (x1 - c, y0, z1 - c)]))
    f.append(((-1, 1, 1), [(x0 + c, y1 - c, z1), (x0 + c, y1, z1 - c), (x0, y1 - c, z1 - c)]))
    if cb > 0:
        f.append(((1, 1, -1), [(x1, y1 - cb, z0 + cb), (x1 - cb, y1, z0 + cb), (x1 - cb, y1 - cb, z0)]))
    return f


def poly(pts3, fill, extra=""):
    pts = " ".join("%.2f,%.2f" % iso(p) for p in pts3)
    return f'<polygon points="{pts}" fill="{fill}" stroke="{fill}" stroke-width="1" stroke-linejoin="round"{extra}/>'


def plane_matrix(origin, eu, ev):
    """SVG matrix mapping local (u, v) (v pointing down the plane) to screen."""
    ox, oy = iso(origin)
    o0 = iso((0, 0, 0))
    a = iso(eu)
    b = iso(ev)
    return "matrix(%.5f %.5f %.5f %.5f %.3f %.3f)" % (
        a[0] - o0[0], a[1] - o0[1], b[0] - o0[0], b[1] - o0[1], ox, oy)


def squircle(x, y, size, n=5.0, steps=360):
    a = size / 2
    cx, cy = x + a, y + a
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        px = cx + a * math.copysign(abs(ct) ** (2 / n), ct)
        py = cy + a * math.copysign(abs(st) ** (2 / n), st)
        pts.append("%.2f,%.2f" % (px, py))
    return "M" + " L".join(pts) + " Z"


def fit():
    """Scale + centre the body+lid silhouette inside the 824 grid."""
    global SCALE, TX, TY
    SCALE, TX, TY = 1.0, 0.0, 0.0
    pts = [iso((x, y, z)) for x in (0, W) for y in (0, W) for z in (0, H + LID_H + LID_RIDGE)]
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    target_h = 620.0
    SCALE = target_h / (max(ys) - min(ys))
    cx, cy = (max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2
    TX = 512 - cx * SCALE
    TY = 524 - cy * SCALE   # optical: sit a hair low, the lid reads as headroom


def build():
    fit()
    out = []
    add = out.append
    add('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">')
    add('<defs>')
    add(f'<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{BG_A}"/><stop offset="1" stop-color="{BG_B}"/></linearGradient>')
    # woofer hole, for clipping the recessed rings
    add('</defs>')

    add(f'<path id="squircle" d="{squircle(100, 100, 824)}" fill="url(#bg)"/>')

    # ---- flat ground shadow: footprint + top swept along the light
    k = (-LIGHT[0] / LIGHT[2], -LIGHT[1] / LIGHT[2])
    zt = H * 0.22   # a short contact shadow along the same light
    sh = [(C, C, 0), (W - C, C, 0), (W - C, W - C, 0), (C, W - C, 0)]   # bottom face
    top_sh = [(x + k[0] * zt, y + k[1] * zt, 0) for (x, y, _) in sh]
    allp = sh + top_sh
    # convex hull in screen space
    sp = sorted(set(iso(p) for p in allp))

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lo, hi = [], []
    for p in sp:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], p) <= 0:
            lo.pop()
        lo.append(p)
    for p in reversed(sp):
        while len(hi) >= 2 and cross(hi[-2], hi[-1], p) <= 0:
            hi.pop()
        hi.append(p)
    hull = lo[:-1] + hi[:-1]
    add('<g id="shadow"><polygon points="%s" fill="%s"/></g>' % (
        " ".join("%.2f,%.2f" % p for p in hull), SHADOW))

    # ---- body
    add('<g id="body">')
    for n, pts in box_facets(0, W, 0, W, 0, H, C, C):
        add(poly(pts, shade(n)))
    add('</g>')

    # ---- lid: the shaker top, folded like paper along its front diagonal
    # (a valley-to-ridge "tent" fold from the back corner to the front corner),
    # so its two halves catch the light differently: the origami signature.
    a, b = LID_M, W - LID_M
    z0, zt, r = H, H + LID_H, LID_RIDGE
    def roof(x, y):
        return zt + r * (1 - abs(x - y) / (b - a))
    def normal(p, q, t):
        u = [q[i] - p[i] for i in range(3)]
        v = [t[i] - p[i] for i in range(3)]
        n = (u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0])
        return n if n[2] > 0 else tuple(-c for c in n)
    lidshade = lambda n: shade(n, top=LID_TOP, mid=LID_MID, dark=LID_DARK, hi=mix(LID_TOP, "#FFFFFF", 0.5))
    add('<g id="lid">')
    add(poly([(b, a, z0), (b, b, z0), (b, b, roof(b, b)), (b, a, roof(b, a))], lidshade((1, 0, 0))))
    add(poly([(a, b, z0), (b, b, z0), (b, b, roof(b, b)), (a, b, roof(a, b))], lidshade((0, 1, 0))))
    back, front = (a, a, roof(a, a)), (b, b, roof(b, b))
    for corner in ((a, b), (b, a)):           # left half, right half
        c3 = (corner[0], corner[1], roof(*corner))
        add(poly([back, front, c3], lidshade(normal(back, front, c3))))
    # 7 holes in a hex, rotated so three sit on the fold; each is a true
    # circle on the folded surface, projected point by point
    add('<g id="holes">')
    cx = cy = W / 2
    pitch, hr = 0.12, 0.034
    centres = [(cx, cy)] + [(cx + pitch * math.cos(math.radians(d)), cy + pitch * math.sin(math.radians(d)))
                            for d in range(45, 405, 60)]
    for (u, v) in centres:
        ring = []
        for k in range(48):
            t = 2 * math.pi * k / 48
            x, y = u + hr * math.cos(t), v + hr * math.sin(t)
            ring.append(iso((x, y, roof(x, y))))
        add('<path d="M%s Z" fill="%s"/>' % (" L".join("%.2f,%.2f" % q for q in ring), NAVY))
    add('</g></g>')

    # ---- woofer on the left (y = W) face, in the face's own plane
    R = 0.37
    wu, wz = W / 2, H * 0.475           # centre on the face
    def face(depth):
        # local u = x, local v = -z (down); origin at (0, W - depth, 0)
        return plane_matrix((0, W - depth, 0), (1, 0, 0), (0, 0, -1))
    wv = -wz
    add('<g id="woofer">')
    add(f'<clipPath id="hole"><circle cx="{wu}" cy="{wv:.4f}" r="{R}"/></clipPath>')
    add(f'<g id="woofer-ring"><g transform="{face(0)}"><circle cx="{wu}" cy="{wv:.4f}" r="{R}" fill="{WALL}"/></g>')
    add(f'<g transform="{face(0.035)}" clip-path="url(#hole)">'
        f'<circle cx="{wu}" cy="{wv:.4f}" r="{R}" fill="{NAVY}"/></g></g>')
    add(f'<g id="woofer-cone" transform="{face(0.035)}" clip-path="url(#hole)">'
        f'<circle cx="{wu}" cy="{wv:.4f}" r="{R * 0.86:.4f}" fill="{CONE_OUT}"/>'
        f'<circle cx="{wu}" cy="{wv:.4f}" r="{R * FACE["cone_split"]:.4f}" fill="{CONE_IN}"/>'
        f'</g>')
    add('</g>')

    # ---- face, on the cone plane
    fm = face(0.035)
    F = FACE
    ex, ey = R * F["ex"], wv + R * F["ey"]
    erx, ery = R * F["erx"], R * F["ery"]
    # optical balance: a partial in-plane counter-shear about the cone centre
    # halves the 30-degree slope of the eye line (k = 0.268 -> 15 degrees)
    k = F["tilt"]
    add(f'<g id="face" transform="{fm}"><g transform="matrix(1 {-k:.4f} 0 1 0 {k * wu:.4f})">')
    add('<g id="face-eyes">')
    for s in (-1, 1):
        x = wu + s * ex
        add(f'<ellipse cx="{x:.4f}" cy="{ey:.4f}" rx="{erx:.4f}" ry="{ery:.4f}" fill="{INK}"/>')
        add(f'<circle cx="{x - erx * 0.30:.4f}" cy="{ey - ery * 0.38:.4f}" r="{erx * 0.42:.4f}" fill="#FFFFFF"/>')
        add(f'<circle cx="{x + erx * 0.38:.4f}" cy="{ey + ery * 0.36:.4f}" r="{erx * 0.18:.4f}" fill="#FFFFFF"/>')
    add('</g>')
    add('<g id="face-cheeks" fill="none" stroke="%s" stroke-width="%.4f" stroke-linecap="round" stroke-linejoin="round">'
        % (BLUSH, R * F["cheek_sw"]))
    for s in (-1, 1):
        w = R * F["cheek_w"]
        x0 = wu + s * R * F["cheek_x"] - w / 2
        y0 = ey + ery + R * F["cheek_dy"]
        a = w * 0.175
        add(f'<path d="M{x0:.4f},{y0:.4f} q{w/4:.4f},{-2*a:.4f} {w/2:.4f},0 t{w/2:.4f},0"/>')
    add('</g>')
    my = ey + ery * 0.85
    mw = R * F["mouth_w"]
    add(f'<g id="face-mouth"><path d="M{wu - mw:.4f},{my:.4f} q{mw:.4f},{mw * 0.9:.4f} {2 * mw:.4f},0" '
        f'fill="none" stroke="{INK}" stroke-width="{R * F["mouth_sw"]:.4f}" stroke-linecap="round"/></g>')
    add('</g></g>')

    add('</svg>')
    OUT.write_text("\n".join(out) + "\n")



# =====================================================================
# v3 renderer: camera, shading, geometry, painter's order
# =====================================================================
class Cam3:
    """Orthographic camera: yaw about world z, then pitch about the screen x
    axis. Screen x right, screen y down, depth toward the viewer."""

    def __init__(self, yaw, pitch, scale=1.0, tx=0.0, ty=0.0):
        y, p = math.radians(yaw), math.radians(pitch)
        self.cy, self.sy, self.cp, self.sp = math.cos(y), math.sin(y), math.cos(p), math.sin(p)
        self.scale, self.tx, self.ty = scale, tx, ty
        # unit vector from the scene toward the viewer
        self.view = (self.sy * self.cp, self.cy * self.cp, self.sp)

    def lin(self, v):
        x, y, z = v
        x1 = x * self.cy - y * self.sy
        y1 = x * self.sy + y * self.cy
        return (x1 * self.scale, (y1 * self.sp - z * self.cp) * self.scale)

    def __call__(self, p):
        sx, sy = self.lin(p)
        return (sx + self.tx, sy + self.ty)

    def depth(self, p):
        return sum(a * b for a, b in zip(p, self.view))


def v_sub(a, b):
    return tuple(x - y for x, y in zip(a, b))


def v_dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def newell(pts):
    n = [0.0, 0.0, 0.0]
    for i, p in enumerate(pts):
        q = pts[(i + 1) % len(pts)]
        n[0] += (p[1] - q[1]) * (p[2] + q[2])
        n[1] += (p[2] - q[2]) * (p[0] + q[0])
        n[2] += (p[0] - q[0]) * (p[1] + q[1])
    return norm(n)


def dedupe(pts, eps=1e-9):
    out = []
    for p in pts:
        if not out or max(abs(a - b) for a, b in zip(p, out[-1])) > eps:
            out.append(p)
    if len(out) > 1 and max(abs(a - b) for a, b in zip(out[0], out[-1])) <= eps:
        out.pop()
    return out


def rect_ring(x0, x1, y0, y1, z, inset, cut):
    """8-point ring: the rectangle shrunk by `inset`, its corners cut by `cut`."""
    a, b, c, d = x0 + inset, x1 - inset, y0 + inset, y1 - inset
    return [(a + cut, c, z), (b - cut, c, z), (b, c + cut, z), (b, d - cut, z),
            (b - cut, d, z), (a + cut, d, z), (a, d - cut, z), (a, c + cut, z)]


def loft(rings):
    """Closed convex solid from stacked rings: side bands + both caps.
    Returns [(outward normal, polygon)]."""
    faces = [list(reversed(rings[0])), list(rings[-1])]
    for A, B in zip(rings, rings[1:]):
        for j in range(8):
            faces.append([A[j], A[(j + 1) % 8], B[(j + 1) % 8], B[j]])
    allp = [p for r in rings for p in r]
    cen = tuple(sum(c) / len(allp) for c in zip(*allp))
    out = []
    for f in faces:
        f = dedupe(f)
        if len(f) < 3:
            continue
        n = newell(f)
        fc = tuple(sum(c) / len(f) for c in zip(*f))
        if v_dot(n, v_sub(fc, cen)) < 0:
            n = tuple(-x for x in n)
            f = list(reversed(f))
        out.append((n, f))
    return out


def build_v3():
    M = MODEL3
    out_path = Path(__file__).with_name("icon3.svg")
    B, LD, HO, WF, FA, FR = M["body"], M["lid"], M["holes"], M["woofer"], M["face"], M["frame"]
    W, D, H, c = B["w"], B["d"], B["h"], B["bevel"]
    Ld = norm(M["light"]["dir"])
    ka, kd = M["light"]["ambient"], M["light"]["diffuse"]

    def colour(material, n):
        t = max(0.0, min(1.0, ka + kd * max(0.0, v_dot(norm(n), Ld))))
        lo, hi = M["materials"][material]
        return mix(lo, hi, t)

    # ---------------- geometry (pure 3D)
    body = loft([rect_ring(0, W, 0, D, 0, c, 0), rect_ring(0, W, 0, D, c, 0, c),
                 rect_ring(0, W, 0, D, H - c, 0, c), rect_ring(0, W, 0, D, H, c, 0)])
    lx0, lx1, ly0, ly1 = LD["inset"], W - LD["inset"], LD["inset"], D - LD["inset"]
    lz0, lz1, rr = H, H + LD["height"], LD["round"]
    lid_rings = [rect_ring(lx0, lx1, ly0, ly1, lz0, 0, LD["corner"])]
    for k in range(LD["round_steps"] + 1):              # soft, rounded top edge in flat steps
        a = (math.pi / 2) * k / LD["round_steps"]
        lid_rings.append(rect_ring(lx0, lx1, ly0, ly1, lz1 - rr + rr * math.sin(a),
                                   rr - rr * math.cos(a), LD["corner"]))
    lid = loft(lid_rings)

    # woofer frame on the y = D face: P(a, b, depth) = centre + a*x + b*z - depth*y
    wx, wz, R = WF["cx"] * W, WF["cz"] * H, WF["r"]
    def wp(a, b, depth):
        return (wx + a, D - depth, wz + b)
    Rs = R * (1 - WF["ring"])                 # cone outer edge (inner edge of the surround)
    Rp = R * WF["plate"]                      # flat centre plate that carries the face
    dw, dc = WF["wall"], WF["cone_depth"]
    face_n = (0.0, 1.0, 0.0)

    # ---------------- fit the frame: scale + centre the body + lid silhouette
    cam0 = Cam3(M["camera"]["yaw"], M["camera"]["pitch"])
    pts = [cam0(p) for _, f in body + lid for p in f]
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    s = FR["height"] / (max(ys) - min(ys))
    cam = Cam3(M["camera"]["yaw"], M["camera"]["pitch"], s,
               FR["cx"] - s * (max(xs) + min(xs)) / 2, FR["cy"] - s * (max(ys) + min(ys)) / 2)
    V = cam.view

    def P(pts3):
        return " ".join("%.2f,%.2f" % cam(p) for p in pts3)

    def facet(pts3, fill):
        return (f'<polygon points="{P(pts3)}" fill="{fill}" stroke="{fill}" '
                f'stroke-width="0.8" stroke-linejoin="round"/>')

    def circle3(centre_fn, r, n):
        return [centre_fn(r * math.cos(2 * math.pi * i / n), r * math.sin(2 * math.pi * i / n)) for i in range(n)]

    def path3(loops):
        return " ".join("M" + " L".join("%.2f,%.2f" % cam(p) for p in loop) + " Z" for loop in loops)

    o = []
    add = o.append
    add('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">')
    bga, bgb = M["background"]
    add(f'<defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{bga}"/>'
        f'<stop offset="1" stop-color="{bgb}"/></linearGradient>')
    # clip apertures (exact: anything inside a hole is seen only through its opening)
    seg = WF["segments"]
    opening = circle3(lambda a, b: wp(a, b, 0), R, seg)
    throat = [wp(Rs * math.cos(2 * math.pi * (i + 0.5) / WF["pleats"]),
                 Rs * math.sin(2 * math.pi * (i + 0.5) / WF["pleats"]), dw) for i in range(WF["pleats"])]
    add(f'<clipPath id="w-open"><path d="{path3([opening])}"/></clipPath>')
    add(f'<clipPath id="w-throat"><path d="{path3([throat])}"/></clipPath>')
    hz = lz1
    hc = (W / 2, D / 2)
    centres = [hc] + [(hc[0] + HO["pitch"] * math.cos(math.radians(HO["angle"] + 60 * k)),
                       hc[1] + HO["pitch"] * math.sin(math.radians(HO["angle"] + 60 * k))) for k in range(6)]
    flat = (lx1 - lx0) / 2 - rr                         # half-size of the lid's flat top
    for (hx, hy) in centres:
        assert max(abs(hx - W / 2), abs(hy - D / 2)) + HO["r"] < flat, "holes must sit on the flat lid top"
    for i, (hx, hy) in enumerate(centres):
        ring = circle3(lambda a, b: (hx + a, hy + b, hz), HO["r"], HO["segments"])
        add(f'<clipPath id="h{i}"><path d="{path3([ring])}"/></clipPath>')
    add('</defs>')
    add(f'<path id="squircle" d="{squircle(100, 100, 824, FR["squircle_n"])}" fill="url(#bg)"/>')

    # ---------------- 1. contact shadow: the real cast shadow, along the light, of the
    # body's lowest slice (footprint up to `contact` x height), on the ground plane
    k = (-Ld[0] / Ld[2], -Ld[1] / Ld[2])
    zc = M["ground"]["contact"] * H
    gp = [cam((x + k[0] * min(z, zc), y + k[1] * min(z, zc), 0)) for _, f in body for (x, y, z) in f]
    gp = sorted(set((round(a, 3), round(b, 3)) for a, b in gp))
    def cross(a, b, q):
        return (b[0] - a[0]) * (q[1] - a[1]) - (b[1] - a[1]) * (q[0] - a[0])
    lo, hi = [], []
    for q in gp:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], q) <= 0:
            lo.pop()
        lo.append(q)
    for q in reversed(gp):
        while len(hi) >= 2 and cross(hi[-2], hi[-1], q) <= 0:
            hi.pop()
        hi.append(q)
    hull = lo[:-1] + hi[:-1]
    add(f'<clipPath id="field"><path d="{squircle(100, 100, 824, FR["squircle_n"])}"/></clipPath>')
    add('<g id="shadow" clip-path="url(#field)"><polygon points="%s" fill="%s"/></g>' % (
        " ".join("%.2f,%.2f" % q for q in hull), M["ground"]["colour"]))

    # ---------------- 2. body: convex, so back-face culling is the whole visibility test
    add('<g id="body">')
    for n, f in body:
        if v_dot(n, V) > 1e-6:
            add(facet(f, colour("body", n)))
    add('</g>')

    # ---------------- 3. woofer, recessed in the y = D face
    add('<g id="woofer">')
    add('<g id="woofer-ring" clip-path="url(#w-open)">')
    for i in range(seg):                                       # cylinder wall, inner side
        t0, t1 = 2 * math.pi * i / seg, 2 * math.pi * (i + 1) / seg
        tm = (t0 + t1) / 2
        n = (-math.cos(tm), 0.0, -math.sin(tm))
        if v_dot(n, V) > 1e-6:
            q = [wp(R * math.cos(t0), R * math.sin(t0), 0), wp(R * math.cos(t1), R * math.sin(t1), 0),
                 wp(R * math.cos(t1), R * math.sin(t1), dw), wp(R * math.cos(t0), R * math.sin(t0), dw)]
            add(facet(q, colour("body", n)))
    outer = circle3(lambda a, b: wp(a, b, dw), R, seg)
    rc = colour("ring", face_n)
    add(f'<path d="{path3([outer, list(reversed(throat))])}" fill="{rc}" fill-rule="evenodd" '
        f'stroke="{rc}" stroke-width="0.8"/>')
    add('</g>')
    add('<g id="woofer-cone" clip-path="url(#w-open)"><g clip-path="url(#w-throat)">')
    npl = WF["pleats"]
    for i in range(npl):                                        # pleated paper cone (frustum)
        t0, t1 = 2 * math.pi * (i + 0.5) / npl, 2 * math.pi * (i + 1.5) / npl
        q = [wp(Rs * math.cos(t0), Rs * math.sin(t0), dw), wp(Rs * math.cos(t1), Rs * math.sin(t1), dw),
             wp(Rp * math.cos(t1), Rp * math.sin(t1), dw + dc), wp(Rp * math.cos(t0), Rp * math.sin(t0), dw + dc)]
        n = newell(q)
        if n[1] < 0:
            n = tuple(-x for x in n)
        assert v_dot(n, V) > 0, "cone too steep for this camera: a pleat would face away"
        add(facet(q, colour("cone", n)))
    plate = [wp(Rp * math.cos(2 * math.pi * (i + 0.5) / npl), Rp * math.sin(2 * math.pi * (i + 0.5) / npl), dw + dc)
             for i in range(npl)]
    add(facet(plate, colour("cone", face_n)))
    add('</g></g>')
    add('</g>')

    # ---------------- 4. face: 2D shapes in the plate's (u, v) plane, mapped by the
    # camera's exact affine map for that plane (u = world x, v = world down)
    o0, ou, ov = cam.lin((0, 0, 0)), cam.lin((1, 0, 0)), cam.lin((0, 0, -1))
    org = cam(wp(0, 0, dw + dc))
    add('<g id="face" transform="matrix(%.6f %.6f %.6f %.6f %.4f %.4f)">' % (
        ou[0], ou[1], ov[0], ov[1], org[0], org[1]))
    F = FA
    ex, ey, erx, ery = R * F["eye_dx"], R * F["eye_dy"], R * F["eye_rx"], R * F["eye_ry"]
    add('<g id="face-eyes">')
    for sgn in (-1, 1):
        x = sgn * ex
        add(f'<ellipse cx="{x:.5f}" cy="{ey:.5f}" rx="{erx:.5f}" ry="{ery:.5f}" fill="{colour("eye", face_n)}"/>')
        for gx, gy, gr in (F["glint"], F["glint2"]):
            add(f'<circle cx="{x + gx * erx:.5f}" cy="{ey + gy * ery:.5f}" r="{gr * erx:.5f}" '
                f'fill="{colour("glint", face_n)}"/>')
    add('</g>')
    bc = colour("blush", face_n)
    add(f'<g id="face-cheeks" fill="none" stroke="{bc}" stroke-width="{R * F["cheek_stroke"]:.5f}" '
        f'stroke-linecap="round" stroke-linejoin="round">')
    cw, amp = R * F["cheek_w"], R * F["cheek_amp"]
    cyy = ey + ery + R * F["cheek_gap"]
    for sgn in (-1, 1):
        x0 = sgn * R * F["cheek_dx"] - cw / 2
        pts = [(x0 + cw * i / F["samples"], cyy - amp * math.sin(2 * math.pi * i / F["samples"]))
               for i in range(F["samples"] + 1)]                       # one full sine: "~"
        add('<path d="M%s"/>' % " L".join("%.5f,%.5f" % p for p in pts))
    add('</g>')
    mw, my = R * F["mouth_w"], ey + ery * F["mouth_dy"]
    sag = mw * F["mouth_sag"]
    mp = [(-mw + 2 * mw * i / F["samples"], my + sag * (1 - (( -1 + 2 * i / F["samples"]) ** 2)))
          for i in range(F["samples"] + 1)]                             # parabolic smile
    add(f'<g id="face-mouth"><path d="M{" L".join("%.5f,%.5f" % p for p in mp)}" fill="none" '
        f'stroke="{colour("eye", face_n)}" stroke-width="{R * F["mouth_stroke"]:.5f}" stroke-linecap="round"/></g>')
    add('</g>')
    far = math.hypot(ex + erx, ey) , R * F["cheek_dx"] + cw / 2 + R * F["cheek_stroke"]
    assert max(far) < Rp * math.cos(math.pi / npl), "face must sit on the flat plate"

    # ---------------- 5. lid: on top of the body, above every body point, so drawn after
    add('<g id="lid">')
    for n, f in lid:
        if v_dot(n, V) > 1e-6:
            add(facet(f, colour("lid", n)))
    add('</g>')

    # ---------------- 6. holes: real circles on the lid top, with visible inner wall + floor
    add('<g id="holes">')
    hs = HO["segments"]
    for i, (hx, hy) in enumerate(centres):
        add(f'<g clip-path="url(#h{i})">')
        for j in range(hs):
            t0, t1 = 2 * math.pi * j / hs, 2 * math.pi * (j + 1) / hs
            tm = (t0 + t1) / 2
            n = (-math.cos(tm), -math.sin(tm), 0.0)
            if v_dot(n, V) > 1e-6:
                r = HO["r"]
                q = [(hx + r * math.cos(t0), hy + r * math.sin(t0), hz), (hx + r * math.cos(t1), hy + r * math.sin(t1), hz),
                     (hx + r * math.cos(t1), hy + r * math.sin(t1), hz - HO["depth"]),
                     (hx + r * math.cos(t0), hy + r * math.sin(t0), hz - HO["depth"])]
                add(facet(q, colour("lid", n)))
        fl = circle3(lambda a, b: (hx + a, hy + b, hz - HO["depth"]), HO["r"], hs)
        fc = colour("hole", (0, 0, 1))
        add(f'<path d="{path3([fl])}" fill="{fc}" stroke="{fc}" stroke-width="0.6"/>')
        add('</g>')
    add('</g>')
    add('</svg>')
    out_path.write_text("\n".join(o) + "\n")

    # ---------------- numeric checks
    m = (ou[0] / s, ov[0] / s, ou[1] / s, ov[1] / s)       # 2x2 [[a c],[b d]] per unit
    a_, c_, b_, d_ = m
    # singular values of the plane map = projected circle's semi-axes
    t1 = a_ * a_ + b_ * b_ + c_ * c_ + d_ * d_
    det = a_ * d_ - b_ * c_
    root = math.sqrt(max(0.0, t1 * t1 / 4 - det * det))
    smax, smin = math.sqrt(t1 / 2 + root), math.sqrt(t1 / 2 - root)
    # major-axis angle: eigenvector of M M^T
    mm = (a_ * a_ + c_ * c_, a_ * b_ + c_ * d_, b_ * b_ + d_ * d_)
    ang = 0.5 * math.degrees(math.atan2(2 * mm[1], mm[0] - mm[2]))
    up = cam.lin((0, 0, 1))
    print("v3 face plane: circle -> ellipse axis ratio %.4f (n.view = %.4f), major axis at %.2f deg"
          % (smin / smax, v_dot(face_n, V), -ang))
    print("v3 world up -> screen (%.4f, %.4f)" % (up[0] / s, up[1] / s))
    print("v3 view vector", tuple(round(x, 4) for x in V))
    print("wrote", out_path)

def build_v4(palette=None, out_path=None, report=True, camera=None):
    """Render MODEL4. `palette` (a PALETTES4 entry) swaps only materials and the
    field; geometry, camera and light are untouched. Returns the SVG lines and
    the index of each part, so the release layers can be cut from one render.
    `camera` (yaw, pitch in degrees) views the same model from another angle
    (viewer.py); the release layers are only cut at the isometric default."""
    M = dict(MODEL4, **(palette or {}))
    if camera is not None:
        M["camera"] = dict(yaw=float(camera[0]), pitch=float(camera[1]))
    out_path = out_path or Path(__file__).with_name("icon4.svg")
    marks = {}
    B, LD, HO, WF, FA, FR = M["body"], M["lid"], M["holes"], M["woofer"], M["face"], M["frame"]
    W, D, H, c = B["w"], B["d"], B["h"], B["bevel"]
    Ld = norm(M["light"]["dir"])
    ka, kd = M["light"]["ambient"], M["light"]["diffuse"]
    seam = M["render"]["seam_px"]

    def intensity(n):
        return max(0.0, min(1.0, ka + kd * max(0.0, v_dot(norm(n), Ld))))

    def colour(material, n=None, t=None):
        lo, hi = M["materials"][material]
        return mix(lo, hi, intensity(n) if t is None else t)

    # ---------------- geometry (pure 3D)
    body = loft([rect_ring(0, W, 0, D, 0, c, 0), rect_ring(0, W, 0, D, c, 0, c),
                 rect_ring(0, W, 0, D, H - c, 0, c), rect_ring(0, W, 0, D, H, c, 0)])

    # lid: vertical walls, one 45-degree chamfer like the body's, and a top
    # folded into a gentle tent along the back -> front diagonal
    lx0, lx1, ly0, ly1 = LD["inset"], W - LD["inset"], LD["inset"], D - LD["inset"]
    lc, lz1, rdg = LD["bevel"], H + LD["height"], LD["ridge"]
    span = (lx1 - lc) - (lx0 + lc)                              # top square side
    def tent(x, y):
        return lz1 + rdg * (1 - abs((x - lx0) - (y - ly0)) / span)
    r0 = rect_ring(lx0, lx1, ly0, ly1, H, 0, lc)
    r1 = rect_ring(lx0, lx1, ly0, ly1, lz1 - lc, 0, lc)
    r2 = [(x, y, tent(x, y)) for (x, y, _) in rect_ring(lx0, lx1, ly0, ly1, lz1, lc, 0)]
    lid_pts = r0 + r1 + r2
    cen = tuple(sum(q) / len(lid_pts) for q in zip(*lid_pts))
    def outward(f):
        n = newell(f)
        fc = tuple(sum(q) / len(f) for q in zip(*f))
        if v_dot(n, v_sub(fc, cen)) < 0:
            f, n = list(reversed(f)), tuple(-x for x in n)
        return n, f
    lid = []
    for A, Bq in ((r0, r1), (r1, r2)):
        for j in range(8):
            q = dedupe([A[j], A[(j + 1) % 8], Bq[(j + 1) % 8], Bq[j]])
            if len(q) < 3:
                continue
            if len(q) == 4:                              # split non-planar quads so the solid stays convex
                n, _ = outward(q[:3])
                if abs(v_dot(n, v_sub(q[3], q[0]))) > 1e-9:
                    t1, t2 = [q[0], q[1], q[2]], [q[0], q[2], q[3]]
                    n1, _ = outward(t1)
                    if v_dot(n1, v_sub(q[3], q[0])) > 1e-12:   # wrong diagonal: q3 would poke out
                        t1, t2 = [q[0], q[1], q[3]], [q[1], q[2], q[3]]
                    lid += [outward(t1), outward(t2)]
                    continue
            lid.append(outward(q))
    top = dedupe(r2)                                     # 4 corners: back, right, front, left
    back = min(top, key=lambda p: p[0] + p[1])
    front = max(top, key=lambda p: p[0] + p[1])
    for side in top:
        if side is not back and side is not front:
            lid.append(outward([back, side, front]))

    # woofer on the y = D face, centred, radius from the margin
    wx, wz = WF["cx"] * W, WF["cz"] * H
    R = min(W - 2 * c, H - 2 * c) / 2 - WF["margin"]
    def wp(a, b, depth):
        return (wx + a, D - depth, wz + b)
    Rs, Rp = R * (1 - WF["ring"]), R * WF["plate"]
    dw, dc = WF["wall"], WF["cone_depth"]
    face_n = (0.0, 1.0, 0.0)
    margins = dict(left=wx - R - c, right=(W - c) - (wx + R), bottom=wz - R - c, top=(H - c) - (wz + R))

    # contact shadow: footprint + bevel overhang (the body's plan outline on the ground)
    soft = M["ground"]["softness"]
    foot = rect_ring(0, W, 0, D, 0, 0, c)
    reach = rect_ring(-soft, W + soft, -soft, D + soft, 0, 0, c)   # visible extent: 1 sigma of blur

    # ---------------- frame: centre + scale from body + lid + shadow bounds
    cam0 = Cam3(M["camera"]["yaw"], M["camera"]["pitch"])
    pts = [cam0(p) for _, f in body + lid for p in f] + [cam0(p) for p in reach]
    xs, ys = [p[0] for p in pts], [p[1] for p in pts]
    sx0, sy0, ssz = FR["squircle"]
    s = FR["height"] / (max(ys) - min(ys))
    cam = Cam3(M["camera"]["yaw"], M["camera"]["pitch"], s,
               sx0 + ssz / 2 - s * (max(xs) + min(xs)) / 2, sy0 + ssz / 2 - s * (max(ys) + min(ys)) / 2)
    V = cam.view

    def P(pts3):
        return " ".join("%.2f,%.2f" % cam(p) for p in pts3)

    def facet(pts3, fill):
        return (f'<polygon points="{P(pts3)}" fill="{fill}" stroke="{fill}" '
                f'stroke-width="{seam}" stroke-linejoin="round"/>')

    def circle3(fn, r, n, phase=0.0):
        return [fn(r * math.cos(2 * math.pi * (i + phase) / n), r * math.sin(2 * math.pi * (i + phase) / n))
                for i in range(n)]

    def path3(loops):
        return " ".join("M" + " L".join("%.2f,%.2f" % cam(p) for p in loop) + " Z" for loop in loops)

    # ground colours: sunlit ground = the field; occluded ground loses the ambient term
    field = mix(*M["background"], 0.5)
    g_lo = M["materials"]["ground"][0]
    t_sun = intensity((0, 0, 1))
    g_hi = "#%02X%02X%02X" % tuple(
        max(0, min(255, round((f - (1 - t_sun) * l) / t_sun))) for f, l in zip(hexc(field), hexc(g_lo)))
    shadow_col = mix(g_lo, g_hi, t_sun - ka * M["ground"]["occlusion"])

    o = []
    add = o.append
    add('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">')
    bga, bgb = M["background"]
    sq = squircle(sx0, sy0, ssz, FR["squircle_n"])
    add(f'<defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{bga}"/>'
        f'<stop offset="1" stop-color="{bgb}"/></linearGradient>')
    add(f'<filter id="ao" filterUnits="userSpaceOnUse" x="0" y="0" width="1024" height="1024">'
        f'<feGaussianBlur stdDeviation="{soft * s:.2f}"/></filter>')
    add(f'<clipPath id="field"><path d="{sq}"/></clipPath>')
    seg = WF["segments"]
    opening = circle3(lambda a, b: wp(a, b, 0), R, seg)
    throat = circle3(lambda a, b: wp(a, b, dw), Rs, seg)
    add(f'<clipPath id="w-open"><path d="{path3([opening])}"/></clipPath>')
    add(f'<clipPath id="w-throat"><path d="{path3([throat])}"/></clipPath>')
    hc = ((lx0 + lx1) / 2, (ly0 + ly1) / 2)
    centres = [hc] + [(hc[0] + HO["pitch"] * math.cos(math.radians(HO["angle"] + 60 * k)),
                       hc[1] + HO["pitch"] * math.sin(math.radians(HO["angle"] + 60 * k))) for k in range(6)]
    for (hx, hy) in centres:
        assert max(abs(hx - hc[0]), abs(hy - hc[1])) + HO["r"] < span / 2, "holes must sit on the lid top"
    rims = []
    for i, (hx, hy) in enumerate(centres):
        rim = circle3(lambda a, b: (hx + a, hy + b, tent(hx + a, hy + b)), HO["r"], HO["segments"])
        rims.append(rim)
        add(f'<clipPath id="h{i}"><path d="{path3([rim])}"/></clipPath>')
    add('</defs>')
    marks["field"] = len(o)
    add(f'<path id="squircle" d="{sq}" fill="url(#bg)"/>')

    # ---------------- 1. contact shadow (ambient occlusion), under everything
    marks["cube"] = len(o)
    add(f'<g id="shadow" clip-path="url(#field)"><polygon points="{P(foot)}" fill="{shadow_col}" filter="url(#ao)"/></g>')

    # ---------------- 2. body (convex: culling is the visibility test)
    add('<g id="body">')
    for n, f in body:
        if v_dot(n, V) > 1e-6:
            add(facet(f, colour("body", n)))
    add('</g>')

    # ---------------- 3. woofer
    marks["woofer"] = len(o)
    add('<g id="woofer">')
    add('<g id="woofer-ring" clip-path="url(#w-open)">')
    for i in range(seg):                                       # recess wall, inner side
        t0, t1 = 2 * math.pi * i / seg, 2 * math.pi * (i + 1) / seg
        tm = (t0 + t1) / 2
        n = (-math.cos(tm), 0.0, -math.sin(tm))
        if v_dot(n, V) > 1e-6:
            q = [wp(R * math.cos(t0), R * math.sin(t0), 0), wp(R * math.cos(t1), R * math.sin(t1), 0),
                 wp(R * math.cos(t1), R * math.sin(t1), dw), wp(R * math.cos(t0), R * math.sin(t0), dw)]
            add(facet(q, colour("recess", n)))
    outer = circle3(lambda a, b: wp(a, b, dw), R, seg)
    rc = colour("ring", face_n)
    add(f'<path d="{path3([outer, list(reversed(throat))])}" fill="{rc}" fill-rule="evenodd" '
        f'stroke="{rc}" stroke-width="{seam}"/>')
    add('</g>')
    add('<g id="woofer-cone" clip-path="url(#w-open)"><g clip-path="url(#w-throat)">')
    for i in range(seg):                                       # smooth shallow cone (frustum)
        t0, t1 = 2 * math.pi * i / seg, 2 * math.pi * (i + 1) / seg
        q = [wp(Rs * math.cos(t0), Rs * math.sin(t0), dw), wp(Rs * math.cos(t1), Rs * math.sin(t1), dw),
             wp(Rp * math.cos(t1), Rp * math.sin(t1), dw + dc), wp(Rp * math.cos(t0), Rp * math.sin(t0), dw + dc)]
        n = newell(q)
        if n[1] < 0:
            n = tuple(-x for x in n)
        if v_dot(n, V) <= 0:                                   # turned away: hidden behind the rim (viewer angles)
            continue
        add(facet(q, colour("cone", n)))
    plate = circle3(lambda a, b: wp(a, b, dw + dc), Rp, seg)
    add(facet(plate, colour("cone", face_n)))
    add('</g></g>')
    add('</g>')

    # ---------------- 4. face on the plate: (u, v) = (world x, world down), exact affine map
    ou, ov = cam.lin((1, 0, 0)), cam.lin((0, 0, -1))
    org = cam(wp(0, 0, dw + dc))
    add('<g id="face" transform="matrix(%.6f %.6f %.6f %.6f %.4f %.4f)">' % (
        ou[0], ou[1], ov[0], ov[1], org[0], org[1]))
    F = FA
    ex, ey, erx, ery = R * F["eye_dx"], R * F["eye_dy"], R * F["eye_rx"], R * F["eye_ry"]
    add('<g id="face-eyes">')
    for sgn in (-1, 1):
        x = sgn * ex
        add(f'<ellipse cx="{x:.5f}" cy="{ey:.5f}" rx="{erx:.5f}" ry="{ery:.5f}" fill="{colour("eye", face_n)}"/>')
        for gx, gy, gr in (F["glint"], F["glint2"]):
            add(f'<circle cx="{x + gx * erx:.5f}" cy="{ey + gy * ery:.5f}" r="{gr * erx:.5f}" '
                f'fill="{colour("glint", face_n)}"/>')
    add('</g>')
    bc = colour("blush", face_n)
    add(f'<g id="face-cheeks" fill="none" stroke="{bc}" stroke-width="{R * F["cheek_stroke"]:.5f}" '
        f'stroke-linecap="round" stroke-linejoin="round">')
    cw, amp = R * F["cheek_w"], R * F["cheek_amp"]
    cyy = ey + ery + R * F["cheek_gap"]
    for sgn in (-1, 1):
        x0 = sgn * R * F["cheek_dx"] - cw / 2
        pts = [(x0 + cw * i / F["samples"], cyy - amp * math.sin(2 * math.pi * i / F["samples"]))
               for i in range(F["samples"] + 1)]
        add('<path d="M%s"/>' % " L".join("%.5f,%.5f" % p for p in pts))
    add('</g>')
    mw, my = R * F["mouth_w"], ey + ery * F["mouth_dy"]
    sag = mw * F["mouth_sag"]
    mp = [(-mw + 2 * mw * i / F["samples"], my + sag * (1 - ((-1 + 2 * i / F["samples"]) ** 2)))
          for i in range(F["samples"] + 1)]
    add(f'<g id="face-mouth"><path d="M{" L".join("%.5f,%.5f" % p for p in mp)}" fill="none" '
        f'stroke="{colour("eye", face_n)}" stroke-width="{R * F["mouth_stroke"]:.5f}" stroke-linecap="round"/></g>')
    add('</g>')
    reach_face = max(math.hypot(ex + erx, abs(ey) + ery), R * F["cheek_dx"] + cw / 2 + R * F["cheek_stroke"])
    assert reach_face < Rp, "face must sit on the flat plate"

    # ---------------- 5. lid (above every body point, so after the body)
    marks["lid"] = len(o)
    add('<g id="lid">')
    for n, f in lid:
        if v_dot(n, V) > 1e-6:
            add(facet(f, colour("lid", n)))
    add('</g>')

    # ---------------- 6. holes: rims follow the tent, walls drop `depth`, hole material
    add('<g id="holes">')
    hs, dh = HO["segments"], HO["depth"]
    for i, rim in enumerate(rims):
        hx, hy = centres[i]
        add(f'<g clip-path="url(#h{i})">')
        for j in range(hs):
            a0, a1 = rim[j], rim[(j + 1) % hs]
            tm = 2 * math.pi * (j + 0.5) / hs
            n = (-math.cos(tm), -math.sin(tm), 0.0)
            if v_dot(n, V) > 1e-6:
                add(facet([a0, a1, (a1[0], a1[1], a1[2] - dh), (a0[0], a0[1], a0[2] - dh)], colour("hole", n)))
        floor = [(p[0], p[1], p[2] - dh) for p in rim]
        add(facet(floor, colour("hole", (0, 0, 1))))
        add('</g>')
    add('</g>')
    marks["end"] = len(o)
    add('</svg>')
    out_path.write_text("\n".join(o) + "\n")

    # layers must be stackable in any order: the woofer and the lid never overlap on screen
    lid_px = [cam(p) for _, f in lid for p in f]
    open_px = [cam(p) for p in opening]
    assert camera is not None or max(q[1] for q in lid_px) < min(q[1] for q in open_px) or \
        max(q[0] for q in open_px) < min(q[0] for q in lid_px), "woofer and lid overlap"
    if not report:
        return o, marks

    # ---------------- numeric checks
    print("v4 woofer R = %.4f; flat-face margins: %s" % (R, ", ".join("%s %.4f" % kv for kv in margins.items())))
    sc = s / 1024 * 128
    print("v4 mouth: %.4f u wide (%.2f x eye width), %.1f px at 1024, %.1f px at 128"
          % (2 * mw, mw / erx, 2 * mw * s, 2 * mw * sc))
    up = cam.lin((0, 0, 1))
    print("v4 world up -> screen (%.4f, %.4f); shadow colour %s; holes depth/r = %.2f"
          % (up[0] / s, up[1] / s, shadow_col, dh / HO["r"]))
    bx = [cam(p)[0] for _, f in body + lid for p in f] + [cam(p)[0] for p in reach]
    by = [cam(p)[1] for _, f in body + lid for p in f] + [cam(p)[1] for p in reach]
    print("v4 body+shadow box centre (%.2f, %.2f)" % ((min(bx) + max(bx)) / 2, (min(by) + max(by)) / 2))
    print("wrote", out_path)
    return o, marks

def build_release():
    """The app's icon asset set, laid out like F-shaker-cube: pre-composited
    masters (1024 canvas, 824 squircle body) and Icon Composer layers (1024 =
    the squircle body, transparent, no tile) that stack back into the master."""
    rel = Path(__file__).with_name("release")
    sx0, sy0, ssz = MODEL4["frame"]["squircle"]
    k = 1024 / ssz
    to_layer = "matrix(%.6f 0 0 %.6f %.4f %.4f)" % (k, k, -sx0 * k, -sy0 * k)
    doc = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
    renders = {}
    for name, fn in (("light", "icon.svg"), ("dark", "icon-dark.svg"), ("freezing", "icon-freezing.svg"),
                     ("ember", "icon-ember.svg"), ("mono", "icon-mono.svg")):
        rel.mkdir(parents=True, exist_ok=True)
        renders[name] = build_v4(PALETTES4[name] or None, rel / fn, report=False)
    for name, sub in (("light", ""), ("dark", "dark"), ("mono", "mono")):
        o, mk = renders[name]
        d = rel / "layers" / sub if sub else rel / "layers"
        d.mkdir(parents=True, exist_ok=True)
        defs = "\n".join(o[1:mk["field"]])
        for fn, a, b in (("1-cube.svg", "cube", "woofer"), ("2-lid.svg", "lid", "end"), ("3-woofer.svg", "woofer", "lid")):
            body = "\n".join(o[mk[a]:mk[b]])
            (d / fn).write_text(f'{doc}\n{defs}\n<g transform="{to_layer}">\n{body}\n</g>\n</svg>\n')
        bga, bgb = (dict(MODEL4, **PALETTES4[name]))["background"]
        (d / "background.svg").write_text(
            f'{doc}<defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{bga}"/>'
            f'<stop offset="1" stop-color="{bgb}"/></linearGradient></defs>'
            f'<rect width="1024" height="1024" fill="url(#bg)"/></svg>\n')
        srgb = lambda h: ",".join("%.5f" % (v / 255) for v in hexc(h))
        print("%-5s field gradient (0,0)->(1,1): srgb:%s,1  ->  srgb:%s,1" % (name, srgb(bga), srgb(bgb)))
    print("wrote", rel)


# =====================================================================
# Menu-bar template (python3 gen.py --menubar -> mac/Resources/source/menubar-icon.svg)
# MODEL4's cube seen through ANGLED_CAMERA, drawn in the one-colour template
# style: a solid silhouette, cut lines on the real projected bevel centrelines,
# the woofer as a cut ring around a solid hub, and the lid as an island with
# cut-out holes. Sizes below are in points of the 18 pt menu-bar box, except
# the hole layout (body units, on the lid's top plane), enlarged so the holes
# survive at 1x.
# =====================================================================
MENUBAR = dict(
    box=18.0, units_per_pt=20.0, height_pt=17.2,   # silhouette fills the box like the old mark
    edge_cut_pt=1.0,       # top-left / top-right / front-vertical face separations
    lid_gap_pt=0.0,        # gap around the lid island (0 = no island: at 18 px it merges with the edge cut)
    bottom_stop_pt=1.6,    # the front-edge cut stops this far above the base (old mark: round cap)
    hub=0.55,              # solid hub radius, fraction of the woofer radius
    hole_r=0.056, hole_pitch=0.16, segments=96,
)


def build_menubar():
    MB, B, LD, WF = MENUBAR, MODEL4["body"], MODEL4["lid"], MODEL4["woofer"]
    W, D, H, c = B["w"], B["d"], B["h"], B["bevel"]
    upt = MB["units_per_pt"]
    body = loft([rect_ring(0, W, 0, D, 0, c, 0), rect_ring(0, W, 0, D, c, 0, c),
                 rect_ring(0, W, 0, D, H - c, 0, c), rect_ring(0, W, 0, D, H, c, 0)])
    lx0, lx1, ly0, ly1 = LD["inset"], W - LD["inset"], LD["inset"], D - LD["inset"]
    lc, lz1, rdg = LD["bevel"], H + LD["height"], LD["ridge"]
    span = (lx1 - lc) - (lx0 + lc)
    def tent(x, y):
        return lz1 + rdg * (1 - abs((x - lx0) - (y - ly0)) / span)
    lid_pts = (rect_ring(lx0, lx1, ly0, ly1, H, 0, lc) + rect_ring(lx0, lx1, ly0, ly1, lz1 - lc, 0, lc)
               + [(x, y, tent(x, y)) for (x, y, _) in rect_ring(lx0, lx1, ly0, ly1, lz1, lc, 0)])
    body_pts = [p for _, f in body for p in f]

    def hull(pts):
        pts = sorted(set((round(a, 6), round(b, 6)) for a, b in pts))
        def cr(o, a, b):
            return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
        lo, hi = [], []
        for q in pts:
            while len(lo) >= 2 and cr(lo[-2], lo[-1], q) <= 0:
                lo.pop()
            lo.append(q)
        for q in reversed(pts):
            while len(hi) >= 2 and cr(hi[-2], hi[-1], q) <= 0:
                hi.pop()
            hi.append(q)
        return lo[:-1] + hi[:-1]

    # fit: silhouette height = height_pt, centred in the box
    cam0 = Cam3(ANGLED_CAMERA["yaw"], ANGLED_CAMERA["pitch"])
    p0 = [cam0(p) for p in body_pts + lid_pts]
    xs, ys = [q[0] for q in p0], [q[1] for q in p0]
    s = MB["height_pt"] * upt / (max(ys) - min(ys))
    half = MB["box"] * upt / 2
    cam = Cam3(ANGLED_CAMERA["yaw"], ANGLED_CAMERA["pitch"], s,
               half - s * (max(xs) + min(xs)) / 2, half - s * (max(ys) + min(ys)) / 2)
    V = cam.view

    def d(pts2, close=True):
        return "M" + "L".join("%.1f %.1f" % q for q in pts2) + ("Z" if close else "")

    shapes = []
    def fill(pts2, paint):
        shapes.append(f'<path d="{d(pts2)}" fill="{paint}"/>')
    def cut(pts2, width_pt, close=False, cap="butt"):
        shapes.append(f'<path d="{d(pts2, close)}" fill="none" stroke="black" stroke-width="{width_pt * upt:.1f}" '
                      f'stroke-linejoin="round" stroke-linecap="{cap}"/>')

    # 1. solid body silhouette
    sil = hull([cam(p) for p in body_pts])
    fill(sil, "white")
    # 2. face separations along the side faces' top edges (where the top bevel meets
    #    them), so the bevel stays with the top and leaves room for the lid gap, plus
    #    the front vertical bevel's centreline; ends run past the silhouette
    over = c
    left_end, right_end = (-over, D, H - c), (W, -over, H - c)
    a_, b_ = (W - c, D, H - c), (W, D - c, H - c)
    assert all(v_dot(n, V) > 0 for n in ((0, 1, 1), (1, 0, 1), (1, 1, 0))), "bevels must face the camera"
    cut([cam(left_end), cam(a_), cam(b_), cam(right_end)], MB["edge_cut_pt"])
    zb = c + MB["bottom_stop_pt"] * upt / s / math.cos(math.radians(ANGLED_CAMERA["pitch"]))
    cut([cam((W - c / 2, D - c / 2, H - c)), cam((W - c / 2, D - c / 2, zb))], MB["edge_cut_pt"], cap="round")
    # 3. woofer: its real projected circle on the face plane, cut, with a solid hub
    wx, wz = WF["cx"] * W, WF["cz"] * H
    R = min(W - 2 * c, H - 2 * c) / 2 - WF["margin"]
    n = MB["segments"]
    ring = lambda r, z0=D: [cam((wx + r * math.cos(2 * math.pi * i / n), z0, wz + r * math.sin(2 * math.pi * i / n)))
                            for i in range(n)]
    fill(ring(R), "black")
    fill(ring(R * MB["hub"]), "white")
    # 4. lid: an island (gap cut around its silhouette, then the lid itself)
    lid_sil = hull([cam(p) for p in lid_pts])
    if MB["lid_gap_pt"] > 0:
        cut(lid_sil, 2 * MB["lid_gap_pt"], close=True)
        fill(lid_sil, "white")
    # 5. holes: real circles on the lid's top plane, projected
    hc = ((lx0 + lx1) / 2, (ly0 + ly1) / 2)
    centres = [hc] + [(hc[0] + MB["hole_pitch"] * math.cos(math.radians(MODEL4["holes"]["angle"] + 60 * j)),
                       hc[1] + MB["hole_pitch"] * math.sin(math.radians(MODEL4["holes"]["angle"] + 60 * j)))
                      for j in range(6)]
    for hx, hy in centres:
        assert max(abs(hx - hc[0]), abs(hy - hc[1])) + MB["hole_r"] < span / 2, "holes must sit on the lid top"
        fill([cam((hx + MB["hole_r"] * math.cos(2 * math.pi * i / n), hy + MB["hole_r"] * math.sin(2 * math.pi * i / n),
                   tent(hx + MB["hole_r"] * math.cos(2 * math.pi * i / n), hy + MB["hole_r"] * math.sin(2 * math.pi * i / n))))
              for i in range(n)], "black")

    size = MB["box"] * upt
    svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size:g} {size:g}" fill="none" role="img" '
           f'aria-label="Bass Shaker toolbar template" data-view="mono"><title>Bass Shaker toolbar template</title>'
           f'<defs><mask id="shaker-mark-cutouts" maskUnits="userSpaceOnUse" x="0" y="0" width="{size:g}" '
           f'height="{size:g}" style="mask-type:luminance">' + "".join(shapes) + '</mask></defs>'
           f'<path d="M0 0L{size:g} 0L{size:g} {size:g}L0 {size:g}Z" fill="black" mask="url(#shaker-mark-cutouts)"/></svg>\n')
    out = Path(__file__).resolve().parents[4] / "mac" / "Resources" / "source" / "menubar-icon.svg"
    out.write_text(svg)
    bx, by = [p[0] for p in sil], [p[1] for p in sil]
    hole_minor = 2 * MB["hole_r"] * s * math.sin(math.radians(ANGLED_CAMERA["pitch"])) / upt
    ring_w = R * (1 - MB["hub"]) * s * v_dot((0, 1, 0), V) / upt
    print("menubar: silhouette %.2f x %.2f pt; woofer ring >= %.2f pt; hole minor axis %.2f pt"
          % ((max(bx) - min(bx)) / upt, (max(by) - min(by)) / upt, ring_w, hole_minor))
    print("wrote", out)


if __name__ == "__main__":
    if "--menubar" in sys.argv:
        build_menubar()
    elif "--release" in sys.argv:
        build_release()
    elif "--v4" in sys.argv:
        build_v4()
    elif "--v3" in sys.argv:
        build_v3()
    else:
        build()
        print("wrote", OUT)
