// F: Shaker Cube. A frosted jelly cube that is a subwoofer (front-left face) and a salt shaker (three holes on top).
// Generated with the "anatomy" isometric kit (MIT, vendored in ./kit): projection, prism solids with four-tone
// face buckets, the kit's light for every round part, and depth-sorted painter's order. No strokes anywhere:
// form comes from face tones, soft gradients and translucency only.
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
const PALETTES = {
  default: {
    bg: ["#EFF4FA", "#DCE5F0"],
    shadow: "#5B729A", shadowOpacity: 0.3,
    top: "#F3F7FC", rim: "#FFFFFF",
    sides: ["#AFC0D7", "#BCCBDF", "#C8D5E6", "#D4DEEC"], // kit buckets 0 (away from light) .. 3 (lit)
    interior: "#9DB1CF", faceAlpha: 0.7, frost: 0.38,
    sole: ["#93A7C6", "#A0B3D0", "#AEBFDA", "#BACAE2"],
    hole: ["#7D93B6", "#93A8C8", "#AFC0DA", "#C9D6E8"], holeFloor: "#6C83AA",
    glow: "#3D7BF0", glowOpacity: 0.85,
    surround: ["#1D47A3", "#2A5FCC", "#3D7BF0", "#6C9BF6"],
    cone: ["#2A5FCC", "#3D7BF0", "#6F9DF6", "#A7C4FF"],
    cap: ["#3D7BF0", "#7AA5F8", "#A7C4FF", "#E6EEFF"],
  },
  dark: {
    bg: ["#243049", "#0F1522"],
    shadow: "#000000", shadowOpacity: 0.45,
    top: "#DCE5F1", rim: "#F2F6FB",
    sides: ["#7286A8", "#8195B5", "#90A3C1", "#9FB1CD"],
    interior: "#55698E", faceAlpha: 0.72, frost: 0.3,
    sole: ["#5A6D90", "#65799C", "#7085A8", "#7B90B3"],
    hole: ["#4C6088", "#5E739B", "#7489B0", "#8C9FC2"], holeFloor: "#33456A",
    glow: "#4D8BFF", glowOpacity: 0.8,
    surround: ["#1D47A3", "#2A5FCC", "#4A86F5", "#7AA7FA"],
    cone: ["#2F66D8", "#4583F5", "#7AA7FA", "#B4CDFF"],
    cap: ["#4583F5", "#86AEFA", "#B4CDFF", "#F0F5FF"],
  },
  mono: { // tinted/clear annotation: hero (woofer) white, everything else greys
    bg: ["#3A3A3C", "#1C1C1E"],
    shadow: "#000000", shadowOpacity: 0.45,
    top: "#9C9C9C", rim: "#AAAAAA",
    sides: ["#5E5E5E", "#676767", "#707070", "#7A7A7A"],
    interior: "#505050", faceAlpha: 0.85, frost: 0.18,
    sole: ["#4A4A4A", "#525252", "#5A5A5A", "#626262"],
    hole: ["#3E3E3E", "#4C4C4C", "#5C5C5C", "#6C6C6C"], holeFloor: "#2E2E2E",
    glow: "#FFFFFF", glowOpacity: 0.28,
    surround: ["#C9C9C9", "#DADADA", "#EDEDED", "#FFFFFF"],
    cone: ["#D4D4D4", "#E4E4E4", "#F3F3F3", "#FFFFFF"],
    cap: ["#E6E6E6", "#F2F2F2", "#FAFAFA", "#FFFFFF"],
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

// ---------- world model (units ~ 1, cube 100 x 100 x 100) ----------
const AZ = 57, EL = 28;           // slightly dimetric: the woofer face (+y) turns toward the viewer
const EDGE_R = 11;                // vertical edge radius, 11% of the face
const TOP_R = 12, BOT_R = 6;      // top / bottom edge roundings (stacked slabs)
const H = 100, SOLE = 4;
const PLAN = { x: 0, y: 0, w: 100, d: 100, r: EDGE_R };
const ART = 1024, OBJECT = 630;   // hero box ~62% of the Icon Composer canvas width

const fit = K.fitProjection(K.boxCorners(PLAN, 0, H), OBJECT, ART, { pad: 0, azimuth: AZ, elevation: EL }); // width-fit
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
function slab(plan, z, h, tones, top, { steps = 10, alpha = 1 } = {}) {
  const s = K.slabOf(plan, z, h, P, steps);
  const shades = s.shades.map((p, i) => (p ? `<path d="${p}" fill="${tones[i]}" stroke="${tones[i]}" stroke-width="0.6"${alpha < 1 ? ` fill-opacity="${alpha}" stroke-opacity="${alpha}"` : ""}/>` : "")).join("");
  return { s, svg: shades + (top ? `<path d="${s.top}" fill="${top}"/>` : "") };
}

// Rounded edge as a stack of thin kit slabs, each inset along a quarter circle and tinted toward `toward`.
function roundStack(z0, R, n, from, toward, up) {
  let svg = "";
  for (let i = 0; i < n; i++) {
    const a0 = (i / n) * (Math.PI / 2), a1 = ((i + 1) / n) * (Math.PI / 2), am = (a0 + a1) / 2;
    const inset = R * (1 - Math.cos(am));
    const lift = up ? [z0 + R * Math.sin(a0), z0 + R * Math.sin(a1)] : [z0 - R * Math.sin(a1), z0 - R * Math.sin(a0)];
    const f = up ? Math.pow(Math.sin(am), 1.4) : Math.sin(am) * 0.5;
    const tones = from.map((c) => mix(c, toward, f));
    const next = up ? Math.pow(Math.sin(a1), 1.4) : f;
    svg += slab(K.insetPlan(PLAN, inset), lift[0], lift[1] - lift[0], tones, mix(mix(from[1], from[2], 0.5), toward, next)).svg;
  }
  return svg;
}

function art(pal) {
  const defs = [];
  const BODY_Z0 = SOLE + BOT_R, BODY_Z1 = H - TOP_R;
  const TOPP = K.insetPlan(PLAN, TOP_R);

  // ---- contact shadow (only in the pre-composited master; Icon Composer draws its own) ----
  defs.push(`<filter id="soft" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="16"/></filter>`);
  const shadow = `<g filter="url(#soft)" transform="translate(0 12)"><path d="${K.haloOf(K.insetPlan(PLAN, -3), 0, 0.01, P)}" fill="${pal.shadow}" opacity="${pal.shadowOpacity}"/></g>`;

  // ---- cube group: sole band, bottom rounding, translucent body with the woofer glowing inside, top rounding ----
  const sole = slab(K.insetPlan(PLAN, 3), 0, SOLE, pal.sole, null).svg;
  const bottom = roundStack(BODY_Z0, BOT_R, 4, pal.sides, pal.interior, false);
  const body = K.slabOf(PLAN, BODY_Z0, BODY_Z1 - BODY_Z0, P, 10);
  defs.push(`<clipPath id="bodyClip"><path d="${body.fill}"/></clipPath>`);
  const g = at([68, 80, 48]), wo = at([50, 100, 50]);
  const objW = at([100, 0, 0])[0] - at([0, 100, 0])[0];
  defs.push(`<radialGradient id="glow" gradientUnits="userSpaceOnUse" cx="${g[0]}" cy="${g[1]}" r="${objW * 0.42}"><stop offset="0" stop-color="${pal.glow}" stop-opacity="${pal.glowOpacity}"/><stop offset="0.55" stop-color="${pal.glow}" stop-opacity="${pal.glowOpacity * 0.35}"/><stop offset="1" stop-color="${pal.glow}" stop-opacity="0"/></radialGradient>`);
  const yTop = at([0, 0, BODY_Z1])[1], yBot = at([100, 100, BODY_Z0])[1];
  const top = at([0, 0, BODY_Z1]), bot = at([100, 100, BODY_Z0]);
  defs.push(`<linearGradient id="frost" gradientUnits="userSpaceOnUse" x1="0" y1="${at([100, 100, BODY_Z1])[1]}" x2="0" y2="${bot[1]}"><stop offset="0" stop-color="#FFFFFF" stop-opacity="${pal.frost}"/><stop offset="0.45" stop-color="#FFFFFF" stop-opacity="0"/><stop offset="0.9" stop-color="#FFFFFF" stop-opacity="0"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="${pal.frost * 0.5}"/></linearGradient>`);
  const faces = body.shades.map((p, i) => (p ? `<path d="${p}" fill="${pal.sides[i]}" fill-opacity="${pal.faceAlpha}"/>` : "")).join("");
  const frost = body.shades.filter(Boolean).map((p) => `<path d="${p}" fill="url(#frost)"/>`).join("");
  const jelly = `<path d="${body.fill}" fill="${pal.interior}"/><g clip-path="url(#bodyClip)"><path d="${body.fill}" fill="url(#glow)"/></g>${faces}${frost}`;
  const rim = roundStack(BODY_Z1, TOP_R, 28, pal.sides, pal.rim, true);
  defs.push(`<linearGradient id="topFace" gradientUnits="userSpaceOnUse" x1="0" y1="${at([0, 0, H])[1]}" x2="0" y2="${at([100, 100, H])[1]}"><stop offset="0" stop-color="${pal.top}"/><stop offset="1" stop-color="${mix(pal.top, pal.sides[3], 0.15)}"/></linearGradient>`);
  const topFace = `<path d="${K.slabOf(TOPP, H, 0, P, 10).top}" fill="url(#topFace)"/>`;
  void yTop; void yBot; void top; void wo;
  const cube = sole + bottom + jelly + rim + topFace;

  // ---- holes group: three real bores in the top face (soft lip, wall, floor), clipped to their openings ----
  let holes = "";
  [225, 345, 105].forEach((deg, i) => {
    const a = (deg * Math.PI) / 180, hx = 50 + 19 * Math.cos(a), hy = 50 + 19 * Math.sin(a);
    const F = G.frameAlong([hx, hy, H], [0, 0, 1]);
    defs.push(`<clipPath id="hole${i}"><path d="${circle(F, 0, 10.5)}"/></clipPath>`);
    const wall = revolve(F, [[0, 10.5], [-1.6, 8.8], [-4, 8.6], [-7, 8.5], [-10, 8.5]], pal.hole, {
      steps: 72, darken: { color: pal.holeFloor, k: (s) => Math.min(1, Math.max(0, (-s - 1.6) / 9)) * 0.85 },
    });
    holes += `<g clip-path="url(#hole${i})"><path d="${circle(F, -10, 8.6)}" fill="${pal.holeFloor}"/>${painted(wall)}</g>`;
  });

  // ---- woofer group: surround (half torus), concave cone, dust cap dome, on the +y face ----
  const W = G.frameAlong([50, 100, (BODY_Z0 + BODY_Z1) / 2 + 1], [0, 1, 0]);
  const RO = 35, RI = 27.5, RC = 11.5, DEPTH = 7.5;
  defs.push(`<filter id="halo" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="10"/></filter>`);
  const halo = `<path d="${circle(W, 0, RO + 3)}" fill="${pal.glow}" opacity="${pal.glowOpacity * 0.45}" filter="url(#halo)"/>`;
  const torus = Array.from({ length: 13 }, (_, i) => {
    const phi = (i / 12) * Math.PI, mid = (RO + RI) / 2, rad = (RO - RI) / 2;
    return [rad * 0.95 * Math.sin(phi), mid + rad * Math.cos(phi)];
  });
  const cone = revolve(W, [[0, RI], [-DEPTH, RC]], pal.cone, { steps: 120, darken: { color: pal.cone[0], k: (s) => (-s / DEPTH) * 0.25 } });
  const capProfile = Array.from({ length: 25 }, (_, i) => {
    const phi = (i / 24) * (Math.PI / 2);
    return [-DEPTH + 6.5 * Math.sin(phi), RC * Math.cos(phi) + 0.001];
  });
  const cap = revolve(W, capProfile, pal.cap, { steps: 96 });
  defs.push(`<clipPath id="coneClip"><path d="${circle(W, 0, RI + 0.3)}"/></clipPath>`);
  const woofer = halo + `<g clip-path="url(#coneClip)"><path d="${circle(W, 0, RI + 0.3)}" fill="${pal.cone[0]}"/>${painted(cone)}${painted(cap)}</g>` + painted(revolve(W, torus, pal.surround, { steps: 120 }));

  return { defs: defs.join(""), shadow, cube, holes, woofer };
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
const LABEL = "The Bass Shaker: a frosted cube with a blue woofer on its side and three shaker holes on top";

function master(pal) {
  const a = art(pal);
  const tile = squircle(512, 512, 412);
  const k = 824 / 1024;
  return svgDoc(
    `<defs>${bgGrad(pal, 100, 924)}<clipPath id="tile"><path d="${tile}"/></clipPath>${a.defs}</defs>` +
      `<g clip-path="url(#tile)"><rect x="100" y="100" width="824" height="824" fill="url(#bg)"/>` +
      `<g transform="translate(100 100) scale(${k})">${a.shadow}${a.cube}${a.holes}${a.woofer}</g></g>`,
    LABEL,
  );
}

function layers(pal, dir) {
  const a = art(pal);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "background.svg"), svgDoc(`<defs>${bgGrad(pal, 0, 1024)}</defs><rect width="1024" height="1024" fill="url(#bg)"/>`, "background"));
  writeFileSync(join(dir, "1-cube.svg"), svgDoc(`<defs>${a.defs}</defs>${a.cube}`, "cube"));
  writeFileSync(join(dir, "2-holes.svg"), svgDoc(`<defs>${a.defs}</defs>${a.holes}`, "shaker holes"));
  writeFileSync(join(dir, "3-woofer.svg"), svgDoc(`<defs>${a.defs}</defs>${a.woofer}`, "woofer"));
}

writeFileSync(join(HERE, "icon.svg"), master(PALETTES.default));
writeFileSync(join(HERE, "icon-dark.svg"), master(PALETTES.dark));
writeFileSync(join(HERE, "icon-mono.svg"), master(PALETTES.mono));
layers(PALETTES.default, join(HERE, "layers"));
layers(PALETTES.dark, join(HERE, "layers", "dark"));
layers(PALETTES.mono, join(HERE, "layers", "mono"));
console.log("wrote icon.svg, icon-dark.svg, icon-mono.svg, layers/");
