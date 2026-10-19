#!/usr/bin/env python3
"""The Bass Shaker, C2 "Speaker shaker": a low-poly octagonal salt shaker in true
isometric (30 deg) projection whose front facet carries a woofer; the cone is the face.
Every shape is projected from 3D points; run `python3 gen2.py` to write icon2.svg.
Animation hooks: #woofer-ring, #woofer-cone (pump), #face-eyes (blink), #face-cheeks,
#face-mouth, #sound (ripple), #shadow (hop)."""
import math, os, re

# ---------- palette: 7 flat colours + eye brown (field gradient separate) ----------
BG_TOP, BG_BOT = "#e6edfe", "#cfdaf8"   # pale periwinkle field
BLUE_HI = "#6f93f0"   # body lit facet (left)
COBALT  = "#3a63d6"   # brand cobalt (front), ripple
BLUE_LO = "#2a46a8"   # body shade facet (right), collar, holes, woofer surround
WHITE   = "#ffffff"   # cap top, eye glints
MIST    = "#dfe6f9"   # cap lit sides, woofer cone
CREST   = "#b3c1e6"   # cap shade side
PINK    = "#f49ab8"   # "~" blush
EYE     = "#2b1d1a"   # glossy dark-brown eyes, mouth

C30, S30 = math.cos(math.radians(30)), math.sin(math.radians(30))
def iso(p):
    x, y, z = p
    return ((x - y) * C30, (x + y) * S30 - z)
def norm(v):
    l = math.sqrt(sum(c * c for c in v)); return tuple(c / l for c in v)
def sub(a, b): return tuple(i - j for i, j in zip(a, b))
def cross(a, b): return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])
def dot(a, b): return sum(i * j for i, j in zip(a, b))
VIEW = norm((1, 1, 1))
LIGHT = norm((-0.3, 0.9, 1.3))           # top-left, slightly toward the viewer

def octagon(a, c, z):
    """Chamfered square (half-size a, chamfer c) at height z, counter-clockwise.
    A large chamfer makes the 45 deg (front) facet wide enough to hold the woofer."""
    b = a - c
    pts = [(a, -b), (a, b), (b, a), (-b, a), (-a, b), (-a, -b), (-b, -a), (b, -a)]
    return [(x, y, z) for x, y in pts]

# ---------- geometry (world units ~ px) ----------
A, CH = 178.0, 0.78 * 178.0
LIFT, H = 30.0, 290.0          # hop gap, body height
LEDGE   = 11.0                 # ledge inset == collar height
CAP     = 40.0                 # cap band height

shapes = []
def poly(pts2, fill, extra=""):
    d = "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in pts2) + "Z"
    if not extra: extra = f' stroke="{fill}" stroke-width="1" stroke-linejoin="round"'
    return f'<path d="{d}" fill="{fill}"{extra}/>'

def prism_faces(bot, top, ramp, group):
    """Visible side faces between two rings; ramp = [(lambert threshold, colour)], brightest first."""
    n = len(bot)
    for i in range(n):
        p0, p1, q1, q0 = bot[i], bot[(i+1) % n], top[(i+1) % n], top[i]
        nrm = norm(cross(sub(p1, p0), sub(q0, p0)))
        if dot(nrm, VIEW) <= 1e-6: continue
        lam = dot(nrm, LIGHT)
        shapes.append((group, poly([iso(p) for p in (p0, p1, q1, q0)], next(c for t, c in ramp if lam > t))))

def iso_circle(cx, cy, z, r, n=96):
    return [iso((cx + r * math.cos(t), cy + r * math.sin(t), z)) for t in (2 * math.pi * k / n for k in range(n))]

R_CIRC = math.hypot(A, A - CH)
RAMP3 = lambda hi, mid, lo: [(0.42, hi), (0.05, mid), (-9, lo)]

# floor: bass thump ripple + hop shadow
for r, w, op in [(1.30, 8, 0.50), (1.55, 6, 0.30)]:
    pts = iso_circle(0, 0, 0, R_CIRC * r)
    d = "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in pts) + "Z"
    shapes.append(("sound", f'<path d="{d}" fill="none" stroke="{COBALT}" stroke-width="{w}" stroke-opacity="{op}"/>'))
shapes.append(("shadow", poly(iso_circle(0, 0, 0, R_CIRC * 0.92), BLUE_LO, ' fill-opacity="0.20"')))

# body + ledge
z0, z1 = LIFT, LIFT + H
body_top = octagon(A, CH, z1)
prism_faces(octagon(A, CH, z0), body_top, RAMP3(BLUE_HI, COBALT, BLUE_LO), "body")
shapes.append(("body", poly([iso(p) for p in body_top], BLUE_HI)))
# collar (cap group): inset by LEDGE, LEDGE tall
s = (A - LEDGE) / A
prism_faces(octagon(A - LEDGE, CH * s, z1), octagon(A - LEDGE, CH * s, z1 + LEDGE), [(0.42, COBALT), (-9, BLUE_LO)], "cap")
# cap: one band, three tones (white top, mist lit sides, crest shade)
zc = z1 + LEDGE
cap_top = octagon(A, CH, zc + CAP)
prism_faces(octagon(A, CH, zc), cap_top, RAMP3(MIST, MIST, CREST), "cap")
shapes.append(("cap", poly([iso(p) for p in cap_top], WHITE)))
# holes: 7 in a hex on the top face
ztop = zc + CAP
hr, hs = 12.0, 42.0
for hx, hy in [(0, 0)] + [(hs * math.cos(math.radians(60 * i + 15)), hs * math.sin(math.radians(60 * i + 15))) for i in range(6)]:
    shapes.append(("holes", poly(iso_circle(hx, hy, ztop, hr, 40), BLUE_LO)))

# woofer on the front facet (normal 45 deg). Its plane maps u (along the facet) to
# sx * sqrt(2)*cos30 and z to -sy, so a circle of radius r is an ellipse (1.2247r, r).
fx = fy = A - CH / 2
wz = z0 + H * 0.48
wcx, wcy = iso((fx, fy, wz))
U = math.sqrt(2) * C30
def facet_ellipse(r, fill, gid):
    shapes.append((gid, f'<ellipse cx="{wcx:.2f}" cy="{wcy:.2f}" rx="{U * r:.2f}" ry="{r:.2f}" fill="{fill}"/>'))
R_RING, R_CONE = 88.0, 74.0
facet_ellipse(R_RING, BLUE_LO, "woofer-ring")
facet_ellipse(R_CONE, MIST, "woofer-cone")

# face inside the cone (screen space, centred on the cone)
ex, ew, eh, ey = 46.0, 25.0, 31.0, -4.0
eyes = []
for sg in (-1, 1):
    x, y = wcx + sg * ex, wcy + ey
    eyes.append(f'<ellipse cx="{x:.2f}" cy="{y:.2f}" rx="{ew}" ry="{eh}" fill="{EYE}"/>')
    eyes.append(f'<circle cx="{x - 8:.2f}" cy="{y - 11:.2f}" r="8" fill="{WHITE}"/>')
    eyes.append(f'<circle cx="{x + 8:.2f}" cy="{y + 10:.2f}" r="3.5" fill="{WHITE}"/>')
shapes.append(("face-eyes", "".join(eyes)))
cheeks = []
for sg in (-1, 1):
    x0, y0 = wcx + sg * 66 - 13, wcy + 36
    cheeks.append(f'<path d="M{x0:.2f} {y0:.2f} q6.5 -8 13 0 t13 0" fill="none" stroke="{PINK}" '
                  f'stroke-width="7" stroke-linecap="round" stroke-linejoin="round"/>')
shapes.append(("face-cheeks", "".join(cheeks)))
my = wcy + 34
shapes.append(("face-mouth", f'<path d="M{wcx - 12:.2f} {my:.2f} q6 8 12 0 q6 8 12 0" fill="none" '
                             f'stroke="{EYE}" stroke-width="7.5" stroke-linecap="round" stroke-linejoin="round"/>'))

# ---------- centring on the shaker + shadow (ripple may run wider) ----------
xs, ys = [], []
for g, svg in shapes:
    if g == "sound" or g.startswith("face") or g.startswith("woofer"): continue
    for m in re.finditer(r'd="([^"]+)"', svg):
        nums = [float(v) for v in re.findall(r"-?\d+\.?\d*", m.group(1))]
        xs += nums[0::2]; ys += nums[1::2]
OPT = -4.0   # lift slightly so the ripple keeps its margin from the bottom edge
tx, ty = 512 - (min(xs) + max(xs)) / 2, 512 - (min(ys) + max(ys)) / 2 + OPT

def squircle(cx, cy, r, n=5.0, steps=360):
    """Superellipse |x|^n + |y|^n = r^n: Apple-style continuous corners."""
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s_ = math.cos(t), math.sin(t)
        pts.append((cx + r * math.copysign(abs(c) ** (2 / n), c), cy + r * math.copysign(abs(s_) ** (2 / n), s_)))
    return "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in pts) + "Z"

groups, order = {}, []
for g, svg in shapes:
    if g not in groups: groups[g] = []; order.append(g)
    groups[g].append(svg)
sq = squircle(512, 512, 412)
out = ['<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">',
       '<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
       f'<stop offset="0" stop-color="{BG_TOP}"/><stop offset="1" stop-color="{BG_BOT}"/></linearGradient>'
       f'<clipPath id="shape"><path d="{sq}"/></clipPath></defs>',
       f'<path id="field" d="{sq}" fill="url(#bg)"/>',
       f'<g clip-path="url(#shape)"><g id="shaker" transform="translate({tx:.2f} {ty:.2f})">']
out += [f'<g id="{g}">' + "".join(groups[g]) + '</g>' for g in order]
out.append('</g></g></svg>')
here = os.path.dirname(os.path.abspath(__file__))
open(os.path.join(here, "icon2.svg"), "w").write("\n".join(out))
print("translate", round(tx, 1), round(ty, 1), "front facet half-width", round(CH * math.sqrt(2) / 2 * U, 1))
