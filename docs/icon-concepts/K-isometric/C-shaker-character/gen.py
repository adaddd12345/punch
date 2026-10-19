#!/usr/bin/env python3
"""The Bass Shaker, "Shaker character": a low-poly octagonal salt shaker in true
isometric (30 deg) projection, with a kawaii face and a bass-thump ripple.
Every shape is projected from 3D points; run `python3 gen.py` to write icon.svg."""
import math, os

# ---------- palette (6 flat colours + background field) ----------
BG_TOP, BG_BOT = "#e6edfe", "#cfdaf8"   # pale periwinkle field
BLUE_HI  = "#6f93f0"   # lit facet (left)
COBALT   = "#3a63d6"   # brand cobalt (front)
BLUE_LO  = "#2a46a8"   # shade facet (right), holes, ripple
WHITE    = "#ffffff"   # cap top, eye glints
MIST     = "#dce4f8"   # cap lit facets, "~" cheeks
CREST    = "#c6d1ec"   # cap shade facets (the wave's grey crest)
EYE      = "#2b1d1a"   # glossy dark-brown eyes, mouth
BLUSH    = MIST
WHITE_LIT = "#eef2fd"   # dome lit facets
CREST_LO = "#aab8e0"   # cap side, away from light

C30, S30 = math.cos(math.radians(30)), math.sin(math.radians(30))
CX, CY = 512.0, 512.0      # recentred after the bbox is known
def iso(p):
    x, y, z = p
    return ((x - y) * C30, (x + y) * S30 - z)

def norm(v):
    l = math.sqrt(sum(c * c for c in v)); return tuple(c / l for c in v)
def sub(a, b): return tuple(i - j for i, j in zip(a, b))
def cross(a, b): return (a[1]*b[2]-a[2]*b[1], a[2]*b[0]-a[0]*b[2], a[0]*b[1]-a[1]*b[0])
def dot(a, b): return sum(i * j for i, j in zip(a, b))
DEBUG = os.environ.get("DEBUG")
VIEW = norm((1, 1, 1))
LIGHT = norm((-0.3, 0.9, 1.3))           # top-left, slightly toward the viewer

def octagon(a, c, z):
    """Chamfered square (half-size a, chamfer c) at height z, counter-clockwise."""
    b = a - c
    pts = [(a, -b), (a, b), (b, a), (-b, a), (-a, b), (-a, -b), (-b, -a), (b, -a)]
    return [(x, y, z) for x, y in pts]

# ---------- geometry (world units ~ px) ----------
A, CH = 152.0, 0.586 * 152.0   # regular octagon: chamfer = a*2/(2+sqrt2)
LIFT  = 30.0                   # hop gap above the floor
H     = 280.0                  # body height
LEDGE = 11.0                   # bevel: ledge inset == collar height == cap lip
CAP1  = 30.0                   # cap side height
CHAMF = 0.26                   # cap chamfer inset (fraction of a)
CHAMF_H = 34.0                 # cap chamfer rise

shapes = []   # (group, svg string) in paint order
def poly(pts2, fill, extra=""):
    d = "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in pts2) + "Z"
    if not extra: extra = f' stroke="{fill}" stroke-width="1" stroke-linejoin="round"'
    return f'<path d="{d}" fill="{fill}"{extra}/>'

def prism_faces(bot, top, ramp, group):
    """Side faces of a frustum between two rings; ramp = [(lambert threshold, colour)], brightest first."""
    n = len(bot)
    for i in range(n):
        p0, p1, q1, q0 = bot[i], bot[(i+1) % n], top[(i+1) % n], top[i]
        nrm = norm(cross(sub(p1, p0), sub(q0, p0)))
        if dot(nrm, VIEW) <= 1e-6: continue
        lam = dot(nrm, LIGHT)
        col = next(c for t, c in ramp if lam > t)
        if DEBUG: print(group, [round(v, 2) for v in nrm], round(lam, 2), col)
        shapes.append((group, poly([iso(p) for p in (p0, p1, q1, q0)], col)))

def cap_face(ring, col, group):
    shapes.append((group, poly([iso(p) for p in ring], col)))

def iso_circle(cx, cy, z, r, n=96):
    return [iso((cx + r * math.cos(t), cy + r * math.sin(t), z))
            for t in (2 * math.pi * k / n for k in range(n))]

R_CIRC = math.hypot(A, A - CH)

# floor: bass thump ripple + hop shadow
for k, (r, w, op) in enumerate([(1.22, 12, 0.55), (1.44, 9, 0.32)]):
    pts = iso_circle(0, 0, 0, R_CIRC * r)
    d = "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in pts) + "Z"
    shapes.append(("sound", f'<path d="{d}" fill="none" stroke="{COBALT}" stroke-width="{w}" stroke-opacity="{op}"/>'))
shapes.append(("shadow", poly(iso_circle(0, 0, 0, R_CIRC * 0.92), BLUE_LO, ' fill-opacity="0.20"')))

# body
z0, z1 = LIFT, LIFT + H
body_bot, body_top = octagon(A, CH, z0), octagon(A, CH, z1)
prism_faces(body_bot, body_top, [(0.42, BLUE_HI), (0.05, COBALT), (-9, BLUE_LO)], "body")
cap_face(body_top, BLUE_HI, "body")                      # the visible ledge
# collar (inset by LEDGE, height LEDGE)
s = (A - LEDGE) / A
col_bot = octagon(A - LEDGE, CH * s, z1); col_top = octagon(A - LEDGE, CH * s, z1 + LEDGE)
prism_faces(col_bot, col_top, [(0.42, COBALT), (-9, BLUE_LO)], "cap")
# cap: lip back out to full size, sides, faceted dome
zc = z1 + LEDGE
cap_bot, cap_top = octagon(A, CH, zc), octagon(A, CH, zc + CAP1)
prism_faces(cap_bot, cap_top, [(0.42, MIST), (0.05, CREST), (-9, CREST_LO)], "cap")
k = 1 - CHAMF
dome_top = octagon(A * k, CH * k, zc + CAP1 + CHAMF_H)
prism_faces(cap_top, dome_top, [(0.85, WHITE_LIT), (0.6, MIST), (-9, CREST)], "cap")
cap_face(dome_top, WHITE, "cap")
# holes: 7 in a hex on the top face
ztop = zc + CAP1 + CHAMF_H
hr, hs = 10.5, 38.0
for hx, hy in [(0, 0)] + [(hs * math.cos(math.radians(60 * i + 15)), hs * math.sin(math.radians(60 * i + 15))) for i in range(6)]:
    shapes.append(("holes", poly(iso_circle(hx, hy, ztop, hr, 40), BLUE_LO)))

# face: on the front facet (normal 45 deg), which projects to an upright rectangle
fx, fy = A - CH / 2, A - CH / 2
fc_x, _ = iso((fx, fy, 0))
face_z = z0 + H * 0.50
_, fc_y = iso((fx, fy, face_z))
front_w = CH * math.sqrt(2) * C30 * math.sqrt(2) / math.sqrt(2)  # projected width of front facet
ex, ew, eh = 38.0, 19.0, 25.0          # eye half-spacing, radii
eyes = []
for sgn in (-1, 1):
    x = fc_x + sgn * ex
    eyes.append(f'<ellipse cx="{x:.2f}" cy="{fc_y:.2f}" rx="{ew}" ry="{eh}" fill="{EYE}"/>')
    eyes.append(f'<circle cx="{x - 6:.2f}" cy="{fc_y - 9.5:.2f}" r="6.5" fill="{WHITE}"/>')
    eyes.append(f'<circle cx="{x + 7:.2f}" cy="{fc_y + 8:.2f}" r="2.8" fill="{WHITE}"/>')
shapes.append(("face-eyes", "".join(eyes)))
cheeks = []
for sgn in (-1, 1):
    x0, y0 = fc_x + sgn * 62 - 14, fc_y + 36
    d = f"M{x0:.2f} {y0:.2f} q7 -8 14 0 t14 0"
    cheeks.append(f'<path d="{d}" fill="none" stroke="{BLUSH}" stroke-width="6" stroke-linecap="round" stroke-linejoin="round"/>')
shapes.append(("face-cheeks", "".join(cheeks)))
my = fc_y + 36
shapes.append(("face-mouth", f'<path d="M{fc_x - 9:.2f} {my:.2f} q4.5 6.5 9 0 q4.5 6.5 9 0" fill="none" stroke="{EYE}" stroke-width="5.5" stroke-linecap="round" stroke-linejoin="round"/>'))

# ---------- centring: optical centre of the object bbox ----------
import re
xs, ys = [], []
for g, svg in shapes:
    if g in ("sound",):   # ripple is allowed wider; centre on shaker + shadow
        continue
    for m in re.finditer(r'd="([^"]+)"', svg):
        nums = [float(v) for v in re.findall(r"-?\d+\.?\d*", m.group(1))]
        if svg.find(" q") >= 0: continue
        xs += nums[0::2]; ys += nums[1::2]
bx, by = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
OPT = -4.0   # lift slightly so the ripple keeps its margin from the bottom edge
tx, ty = 512 - bx, 512 - by + OPT

# ---------- squircle (superellipse n=5) for the 824 body ----------
def squircle(cx, cy, r, n=5.0, steps=360):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s_ = math.cos(t), math.sin(t)
        pts.append((cx + r * math.copysign(abs(c) ** (2 / n), c),
                    cy + r * math.copysign(abs(s_) ** (2 / n), s_)))
    return "M" + " L".join(f"{x:.2f} {y:.2f}" for x, y in pts) + "Z"

groups = {}
order = []
for g, svg in shapes:
    if g not in groups: groups[g] = []; order.append(g)
    groups[g].append(svg)

out = ['<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">',
       '<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
       f'<stop offset="0" stop-color="{BG_TOP}"/><stop offset="1" stop-color="{BG_BOT}"/></linearGradient>'
       f'<clipPath id="shape"><path d="{squircle(512, 512, 412)}"/></clipPath></defs>',
       f'<path id="field" d="{squircle(512, 512, 412)}" fill="url(#bg)"/>',
       f'<g clip-path="url(#shape)"><g id="shaker" transform="translate({tx:.2f} {ty:.2f})">']
for g in order:
    out.append(f'<g id="{g}">' + "".join(groups[g]) + '</g>')
out.append('</g></g></svg>')
here = os.path.dirname(os.path.abspath(__file__))
open(os.path.join(here, "icon.svg"), "w").write("\n".join(out))
print("bbox", min(xs), max(xs), min(ys), max(ys), "translate", tx, ty)
