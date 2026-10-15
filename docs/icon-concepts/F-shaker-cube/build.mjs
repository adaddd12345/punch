// F: Shaker Cube. A frosted jelly cube that is a subwoofer (front-left face) and a salt shaker (thin steel cap, pinhole rosette).
// Generated with the "anatomy" isometric kit (MIT, vendored in ./kit): projection, prism solids with four-tone
// face buckets, the kit's light for every round part, and depth-sorted painter's order. No strokes anywhere:
// form comes from face tones, a bright rim on the top edges and the lid's rolled edge.
//
//   node build.mjs   ->  icon.svg, icon-dark.svg, icon-mono.svg, layers/**.svg
//
// Art is authored in Icon Composer space (1024 = the squircle body). icon*.svg are pre-composited masters:
// that art scaled into the 824 body centred on 1024, clipped by a squircle, over the background gradient.
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import * as K from "./kit/iso-kit.mjs";
import * as G from "./kit/lathe.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));

// ---------- palettes (default = "A Salt cube", with the "E Jelly" finish) ----------
// sides = kit shade buckets 0 (right face, away from light) .. 3 (woofer face, lit): about L 62% / 78% of the top.
const PALETTES = {
  default: {
    bg: ["#E2EAF5", "#B9C8DE"],
    shadow: "#3E5684", shadowOpacity: 0.34,
    top: "#F1F5FB", rim: "#FFFFFF",
    sides: ["#91A5C4", "#A2B4D0", "#B3C3DB", "#C3D0E3"],
    interior: "#6F86AE", depth: 0.34, frost: 0.4,
    sole: ["#7F94B6", "#8CA0C0", "#9AADCB", "#A8B9D4"],
    groove: "#8396B8",
    lidSides: ["#7F8A9B", "#96A0B0", "#B0B9C6", "#CDD3DC"], lidTop: ["#F2F4F7", "#CCD3DC"], lidRim: "#FFFFFF",
    holeFloor: "#3A4352", holeLip: "#FFFFFF",
    trim: ["#8DA1C2", "#A9BAD4", "#CAD6E7", "#E9EFF7"],
    surround: ["#132F6E", "#1B3F8F", "#2A57B6", "#4D7AD6"],
    cone: ["#2959C4", "#3A72E6", "#5D8DEE", "#88ACF6"],
    cap: ["#3A75EC", "#76A2F8", "#AAC6FF", "#E8F0FF"], spec: "#FFFFFF",
  },
  dark: {
    bg: ["#26334E", "#0E1421"],
    shadow: "#000000", shadowOpacity: 0.5,
    top: "#DEE6F1", rim: "#F6F9FD",
    sides: ["#6A7FA3", "#7A8FB1", "#8A9EBE", "#9AADCB"],
    interior: "#3E5280", depth: 0.36, frost: 0.3,
    sole: ["#4F6388", "#5A6E93", "#65799E", "#7084A9"],
    groove: "#5B6F95",
    lidSides: ["#687384", "#7E8899", "#97A1B0", "#B2BAC6"], lidTop: ["#DCE1E8", "#B3BBC7"], lidRim: "#F2F5F9",
    holeFloor: "#222A37", holeLip: "#F2F5F9",
    trim: ["#62779C", "#8A9EBF", "#B8C7DD", "#E8EEF7"],
    surround: ["#132F6E", "#1D4296", "#3060C4", "#5686E6"],
    cone: ["#2E62D2", "#4580F0", "#6E9CF4", "#98B9F8"],
    cap: ["#4583F5", "#86AEFA", "#B4CDFF", "#F0F5FF"], spec: "#FFFFFF",
  },
  mono: { // tinted/clear annotation: hero (woofer) white, everything else greys
    bg: ["#3A3A3C", "#1C1C1E"],
    shadow: "#000000", shadowOpacity: 0.5,
    top: "#9A9A9A", rim: "#B0B0B0",
    sides: ["#555555", "#606060", "#6B6B6B", "#767676"],
    interior: "#3A3A3A", depth: 0.3, frost: 0.16,
    sole: ["#444444", "#4C4C4C", "#545454", "#5C5C5C"],
    groove: "#4A4A4A",
    lidSides: ["#5A5A5A", "#666666", "#727272", "#7E7E7E"], lidTop: ["#8A8A8A", "#7C7C7C"], lidRim: "#A6A6A6",
    holeFloor: "#2A2A2A", holeLip: "#B8B8B8",
    trim: ["#9E9E9E", "#B8B8B8", "#D0D0D0", "#E6E6E6"],
    surround: ["#C2C2C2", "#D4D4D4", "#E8E8E8", "#FFFFFF"],
    cone: ["#D4D4D4", "#E4E4E4", "#F3F3F3", "#FFFFFF"],
    cap: ["#E6E6E6", "#F2F2F2", "#FAFAFA", "#FFFFFF"], spec: "#FFFFFF",
  },
};

// ---------- colour helpers ----------
const hex = (c) => [1, 3, 5].map((i) => parseInt(c.slice(i, i + 2), 16));
const toHex = (rgb) => "#" + rgb.map((v) => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, "0")).join("");
const mix = (a, b, t) => toHex(hex(a).map((v, i) => v + (hex(b)[i] - v) * t));
// Four-tone ramp keyed to the kit's light bands (lathe.mjs BANDS 0 / .2 / .42 / .62), interpolated so round
// parts shade softly instead of in hard bands.
const STOPS = [-0.05, 0.2, 0.45, 0.78];
function ramp(tones, score) {
  if (score <= STOPS[0]) return tones[0];
  for (let i = 1; i < 4; i++) if (score <= STOPS[i]) return mix(tones[i - 1], tones[i], (score - STOPS[i - 1]) / (STOPS[i] - STOPS[i - 1]));
  return tones[3];
}

// ---------- world model (units ~ 1, cube 100 x 100 x 100, plus a raised shaker lid) ----------
const AZ = 57, EL = 28;           // slightly dimetric: the woofer face (+y) turns toward the viewer
const EDGE_R = 11;                // vertical edge radius, 11% of the face
const TOP_R = 12, BOT_R = 6;      // top / bottom edge roundings (stacked slabs)
const H = 100, SOLE = 4;
const LID_IN = 15, LID_H = 4.5, LID_R = 3.5; // thin steel cap: inset from the cube edge, height, rolled top edge
const PLAN = { x: 0, y: 0, w: 100, d: 100, r: EDGE_R };
const LIDP = { ...K.insetPlan(PLAN, LID_IN), r: 15 };
const ART = 1024, OBJECT = 630;   // hero box ~62% of the Icon Composer canvas width

const fit = K.fitProjection(K.boxCorners(PLAN, 0, H + 8), OBJECT, ART, { pad: 0, azimuth: AZ, elevation: EL }); // width-fit
const P = { ...fit, origin: [fit.origin[0] + (ART - OBJECT) / 2, fit.origin[1] - 14] }; // ~1.4% optical lift
const VIEW = G.viewOf(P), LIGHT = G.lightOf(P);
const at = (p) => K.iso(p, P);
const d = (pts) => K.pathOf(pts, true);

// ---------- solids of revolution, faceted with the kit's frame, light and depth ----------
// Meridian [s, r] traversed so the surface we see is on its left; normal = u*ds - a*dr (outward on a dome,
// toward the axis inside a bore or a cone).
function revolve(F, meridian, tones, { steps = 96, darken = null } = {}) {
  const out = [];
  for (let j = 0; j < meridian.length - 1; j++) {
    const [s0, r0] = meridian[j], [s1, r1] = meridian[j + 1];
    const ds = s1 - s0, dr = r1 - r0;
    for (let k = 0; k < steps; k++) {
      const t0 = (k / steps) * Math.PI * 2, t1 = ((k + 1) / steps) * Math.PI * 2, tm = (t0 + t1) / 2;
      const n = G.unit3(G.sub3(G.mul3(G.radialOf(F, tm), ds), G.mul3(F.a, dr)));
      if (G.dot3(n, VIEW) <= 0) continue;
      const q = [G.pointOf(F, s0, r0, t0), G.pointOf(F, s0, r0, t1), G.pointOf(F, s1, r1, t1), G.pointOf(F, s1, r1, t0)];
      let fill = ramp(tones, G.dot3(n, LIGHT));
      if (darken) fill = mix(fill, darken.color, darken.k((s0 + s1) / 2));
      const c = q.reduce((a, p) => G.add3(a, G.mul3(p, 0.25)), [0, 0, 0]);
      out.push({ depth: K.depthOf(c, P), svg: `<path d="${d(q.map(at))}" fill="${fill}" stroke="${fill}" stroke-width="0.7" stroke-linejoin="round"/>` });
    }
  }
  return out;
}
const painted = (facets) => facets.sort((a, b) => a.depth - b.depth).map((f) => f.svg).join("");
const circle = (F, s, r, n = 120) => d(Array.from({ length: n }, (_, i) => at(G.pointOf(F, s, r, (i / n) * Math.PI * 2))));

// Kit prism with the four kit shade buckets filled by our tones (no outline / crease).
function slab(plan, z, h, tones, top, { steps = 10 } = {}) {
  const s = K.slabOf(plan, z, h, P, steps);
  const shades = s.shades.map((p, i) => (p ? `<path d="${p}" fill="${tones[i]}" stroke="${tones[i]}" stroke-width="0.6"/>` : "")).join("");
  return { s, svg: shades + (top ? `<path d="${s.top}" fill="${top}"/>` : "") };
}
const flatTop = (plan, z, fill) => `<path d="${K.slabOf(plan, z, 0, P, 10).top}" fill="${fill}"/>`;

// Rounded edge as a stack of thin kit slabs, each inset along a quarter circle and tinted toward `toward`.
// Going up, the tint peaks just past the middle of the arc and eases back, so the lit edge reads as a crisp
// bright rim line (a lacquered vinyl edge) instead of a gradual fade into the top face.
function roundStack(plan, z0, R, n, from, toward, up) {
  let svg = "";
  const tint = (u) => (up ? (u < 0.68 ? Math.pow(u / 0.68, 1.8) : 1 - ((u - 0.68) / 0.32) * 0.45) : u * 0.5);
  for (let i = 0; i < n; i++) {
    const a0 = (i / n) * (Math.PI / 2), a1 = ((i + 1) / n) * (Math.PI / 2), am = (a0 + a1) / 2;
    const inset = R * (1 - Math.cos(am));
    const lift = up ? [z0 + R * Math.sin(a0), z0 + R * Math.sin(a1)] : [z0 - R * Math.sin(a1), z0 - R * Math.sin(a0)];
    const f = tint(Math.sin(am));
    const tones = from.map((c) => mix(c, toward, f));
    svg += slab(K.insetPlan(plan, inset), lift[0], lift[1] - lift[0], tones, mix(mix(from[2], from[3], 0.5), toward, up ? tint(Math.sin(a1)) : f)).svg;
  }
  return svg;
}

function art(pal) {
  const defs = [];
  const BODY_Z0 = SOLE + BOT_R, BODY_Z1 = H - TOP_R;
  const TOPP = K.insetPlan(PLAN, TOP_R);
  const yOf = (z) => at([100, 100, z])[1];

  // ---- contact shadow (only in the pre-composited master; Icon Composer draws its own): a firm core + soft skirt ----
  defs.push(`<filter id="soft" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="18"/></filter>`);
  defs.push(`<filter id="core" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="6"/></filter>`);
  const shadow =
    `<g filter="url(#soft)" transform="translate(0 14)"><path d="${K.haloOf(K.insetPlan(PLAN, -2), 0, 0.01, P)}" fill="${pal.shadow}" opacity="${pal.shadowOpacity * 0.75}"/></g>` +
    `<g filter="url(#core)" transform="translate(0 6)"><path d="${K.haloOf(K.insetPlan(PLAN, 5), 0, 0.01, P)}" fill="${pal.shadow}" opacity="${pal.shadowOpacity}"/></g>`;

  // ---- cube group: sole, bottom rounding, jelly body (opaque face tones, inner depth tint, frost),
  // top rounding with a bright rim, shoulder, lid seam ----
  const sole = slab(K.insetPlan(PLAN, 3), 0, SOLE, pal.sole, null).svg;
  const bottom = roundStack(PLAN, BODY_Z0, BOT_R, 4, pal.sides, pal.interior, false);
  const body = K.slabOf(PLAN, BODY_Z0, BODY_Z1 - BODY_Z0, P, 10);
  const faces = body.shades.map((p, i) => (p ? `<path d="${p}" fill="${pal.sides[i]}" stroke="${pal.sides[i]}" stroke-width="0.6"/>` : "")).join("");
  // Inner depth: a jelly block gets denser toward its base.
  defs.push(`<linearGradient id="depth" gradientUnits="userSpaceOnUse" x1="0" y1="${yOf(BODY_Z1)}" x2="0" y2="${yOf(BODY_Z0)}"><stop offset="0.25" stop-color="${pal.interior}" stop-opacity="0"/><stop offset="1" stop-color="${pal.interior}" stop-opacity="${pal.depth}"/></linearGradient>`);
  const W = G.frameAlong([50, 100, (BODY_Z0 + BODY_Z1) / 2 + 1], [0, 1, 0]); // woofer axis on the +y face
  defs.push(`<linearGradient id="frost" gradientUnits="userSpaceOnUse" x1="0" y1="${yOf(BODY_Z1)}" x2="0" y2="${yOf(BODY_Z0)}"><stop offset="0" stop-color="#FFFFFF" stop-opacity="${pal.frost}"/><stop offset="0.4" stop-color="#FFFFFF" stop-opacity="${pal.frost * 0.25}"/><stop offset="0.85" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>`);
  const jelly = faces + `<path d="${body.fill}" fill="url(#depth)"/>` + `<path d="${body.fill}" fill="url(#frost)"/>`;
  const rim = roundStack(PLAN, BODY_Z1, TOP_R, 28, pal.sides, pal.rim, true);
  defs.push(`<linearGradient id="topFace" gradientUnits="userSpaceOnUse" x1="0" y1="${at([0, 0, H])[1]}" x2="0" y2="${at([100, 100, H])[1]}"><stop offset="0" stop-color="${pal.top}"/><stop offset="1" stop-color="${mix(pal.top, pal.sides[3], 0.18)}"/></linearGradient>`);
  const shoulder = `<path d="${K.slabOf(TOPP, H, 0, P, 10).top}" fill="url(#topFace)"/>` + flatTop(K.insetPlan(LIDP, -1.2), H, pal.groove);
  const cube = sole + bottom + jelly + rim + shoulder;

  // ---- lid group: a thin satin-steel cap with a rolled edge, and a tight rosette of seven pinholes (a dark dot
  // with a faint lit lower lip, barely recessed) ----
  const lidTop = H + LID_H;
  defs.push(`<linearGradient id="lidTop" gradientUnits="userSpaceOnUse" x1="0" y1="${at([LID_IN, LID_IN, lidTop])[1]}" x2="0" y2="${at([100 - LID_IN, 100 - LID_IN, lidTop])[1]}"><stop offset="0" stop-color="${pal.lidTop[0]}"/><stop offset="1" stop-color="${pal.lidTop[1]}"/></linearGradient>`);
  let lid = slab(LIDP, H, LID_H - LID_R, pal.lidSides, null).svg + roundStack(LIDP, lidTop - LID_R, LID_R, 10, pal.lidSides, pal.lidRim, true) +
    `<path d="${K.slabOf(K.insetPlan(LIDP, LID_R), lidTop, 0, P, 10).top}" fill="url(#lidTop)"/>`;
  const HOLE_R = 1.5, RING = 7;
  [[0, 0], ...Array.from({ length: 6 }, (_, i) => [RING * Math.cos((i * Math.PI) / 3 + Math.PI / 4), RING * Math.sin((i * Math.PI) / 3 + Math.PI / 4)])].forEach(([dx, dy]) => {
    const F = G.frameAlong([50 + dx, 50 + dy, lidTop], [0, 0, 1]);
    lid += `<path d="${circle(F, 0, HOLE_R, 32)}" fill="${pal.holeLip}" opacity="0.75" transform="translate(0 1.6)"/><path d="${circle(F, 0, HOLE_R, 32)}" fill="${pal.holeFloor}"/>`;
  });

  // ---- woofer group: thin trim ring, rubber roll surround (~11% of radius), shallow matte cone, dust cap
  // (~28% of radius) with one highlight ----
  const RO = 33, RI = 29.3, RC = 9.3, DEPTH = 4.5, TRIM = 2.4;
  const trim = revolve(W, [[0, RO + TRIM], [0.5, RO + TRIM - 0.3], [0.8, RO + TRIM * 0.5], [0.5, RO + 0.3], [0, RO]], pal.trim, { steps: 120 });
  const torus = Array.from({ length: 15 }, (_, i) => {
    const phi = (i / 14) * Math.PI, mid = (RO + RI) / 2, rad = (RO - RI) / 2;
    return [rad * 1.3 * Math.sin(phi), mid + rad * Math.cos(phi)];
  });
  const cone = revolve(W, [[0, RI], [-DEPTH * 0.55, (RI + RC) / 2 + 1.2], [-DEPTH, RC]], pal.cone, { steps: 120, darken: { color: pal.surround[0], k: (s) => (-s / DEPTH) * 0.32 } });
  const capProfile = Array.from({ length: 25 }, (_, i) => {
    const phi = (i / 24) * (Math.PI / 2);
    return [-DEPTH + 3.2 * Math.sin(phi), RC * Math.cos(phi) + 0.001];
  });
  const cap = revolve(W, capProfile, pal.cap, { steps: 96 });
  // One crisp highlight on the dust cap, on the side facing the light.
  let best = 0, bestDot = -2;
  for (let t = 0; t < Math.PI * 2; t += Math.PI / 90) { const k = G.dot3(G.radialOf(W, t), LIGHT); if (k > bestDot) { bestDot = k; best = t; } }
  const SF = G.frameAlong(G.pointOf(W, -DEPTH + 2.9, 4.0, best), W.a);
  const spec = `<path d="${circle(SF, 0, 1.6, 48)}" fill="${pal.spec}" opacity="0.85"/>`;
  defs.push(`<clipPath id="coneClip"><path d="${circle(W, 0, RI + 0.3)}"/></clipPath>`);
  const woofer = painted(trim) + `<g clip-path="url(#coneClip)"><path d="${circle(W, 0, RI + 0.3)}" fill="${pal.cone[0]}"/>${painted(cone)}${painted(cap)}${spec}</g>` + painted(revolve(W, torus, pal.surround, { steps: 120 }));

  return { defs: defs.join(""), shadow, cube, lid, woofer };
}

// ---------- squircle body (superellipse n=5, 824 centred on 1024) and files ----------
function squircle(cx, cy, a, n = 5, count = 240) {
  const pts = Array.from({ length: count }, (_, i) => {
    const t = (i / count) * Math.PI * 2, c = Math.cos(t), s = Math.sin(t);
    return [cx + a * Math.sign(c) * Math.pow(Math.abs(c), 2 / n), cy + a * Math.sign(s) * Math.pow(Math.abs(s), 2 / n)];
  });
  return K.pathOf(pts, true);
}
const svgDoc = (body, label) => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024" role="img" aria-label="${label}">${body}</svg>\n`;
const bgGrad = (pal, y0, y1) => `<linearGradient id="bg" gradientUnits="userSpaceOnUse" x1="0" y1="${y0}" x2="0" y2="${y1}"><stop offset="0" stop-color="${pal.bg[0]}"/><stop offset="1" stop-color="${pal.bg[1]}"/></linearGradient>`;
const LABEL = "The Bass Shaker: a frosted cube with a blue woofer on its side and a thin steel shaker cap with seven pinholes on top";

function master(pal) {
  const a = art(pal);
  const tile = squircle(512, 512, 412);
  const k = 824 / 1024;
  return svgDoc(
    `<defs>${bgGrad(pal, 100, 924)}<clipPath id="tile"><path d="${tile}"/></clipPath>${a.defs}</defs>` +
      `<g clip-path="url(#tile)"><rect x="100" y="100" width="824" height="824" fill="url(#bg)"/>` +
      `<g transform="translate(100 100) scale(${k})">${a.shadow}${a.cube}${a.lid}${a.woofer}</g></g>`,
    LABEL,
  );
}

function layers(pal, dir) {
  const a = art(pal);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "background.svg"), svgDoc(`<defs>${bgGrad(pal, 0, 1024)}</defs><rect width="1024" height="1024" fill="url(#bg)"/>`, "background"));
  writeFileSync(join(dir, "1-cube.svg"), svgDoc(`<defs>${a.defs}</defs>${a.cube}`, "cube"));
  writeFileSync(join(dir, "2-lid.svg"), svgDoc(`<defs>${a.defs}</defs>${a.lid}`, "shaker lid"));
  writeFileSync(join(dir, "3-woofer.svg"), svgDoc(`<defs>${a.defs}</defs>${a.woofer}`, "woofer"));
}

writeFileSync(join(HERE, "icon.svg"), master(PALETTES.default));
writeFileSync(join(HERE, "icon-dark.svg"), master(PALETTES.dark));
writeFileSync(join(HERE, "icon-mono.svg"), master(PALETTES.mono));
layers(PALETTES.default, join(HERE, "layers"));
layers(PALETTES.dark, join(HERE, "layers", "dark"));
layers(PALETTES.mono, join(HERE, "layers", "mono"));
console.log("wrote icon.svg, icon-dark.svg, icon-mono.svg, layers/");
