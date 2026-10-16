# 33 · Bento geometry: gaps, corners, edges

Tokens live in `BentoRadius` (BentoView.swift) and `Drawer` (DrawerBlocks.swift).

## Rules (from the pros)
1. **Concentric corners.** Inner radius = outer radius − inset (Apple: WWDC25 "Get to know the new
   design system", concentricity; SwiftUI `ContainerRelativeShape` / `.containerShape`). Never draw a
   child rounder than its container at a small inset.
2. **Siblings on one edge share one radius.** Every block that sits the same inset from the container
   gets the same corner, whatever its size (widgets: `ContainerRelativeShape` gives all of them one
   radius; Apple's bento keynote slides, Linear/Vercel/Raycast feature grids use one card radius).
3. **Edge padding ≥ gap.** Apple widgets: 16 pt margins, 8 pt between groups (HIG Widgets); Control
   Center modules: one uniform gutter. Padding 1–1.5× the gap reads as a frame, not a seam.
4. **Floor for small things.** When the inset ≥ the radius, the inner corner takes its own small
   radius (6 here) or becomes a capsule; don't go square.
5. **Edges: one device pixel, lit from above.** A 1 px (`1 / displayScale`) top-lit highlight that
   fades by a third of the way down; no full outline, no blur. Shadows small and tight (≤ 1.5 blur,
   ≤ 5 % black, none in dark). Liquid Glass draws its own rim: add none on top (HIG Materials).

## This app (360 pt popover, NSPopover corner measured ≈ 20 pt on macOS 26)
| token | before | after |
|---|---|---|
| edge padding / gap | 12 / 8 | 12 / 8 (kept: 1.5×) |
| tile radius | 14 (Drawer 12) | 12 everywhere (corner gap 13.7 vs 12 edge; 14 gave 14.5) |
| hero radius | 22 (rounder than the popover) | 12 (= tile; sibling rule) |
| inner (chips in tiles) | 6 | 6 (floor; 12 − 8 = 4 is too sharp) |
| row chips on the edge (output, apps) | 8 at 24 high | 12 (= tile, a capsule) |
| banners (status, Now Playing, Take Control) | 10 / 10 / 14 | 12 |
| ears rows hover (inset 4) | 6 | 8 (12 − 4) |
| rim | 0.75 pt linear white 0.65→0.12 (L), 0.18→0.03 (D) | 1 px, 0.75 → 0.20 @35 % → 0.10 (L); 0.20 → 0.05 → 0.02 (D) |
| outline look | 0.75 pt, primary 0.26→0.10 | 1 px, primary 0.34→0.14 |

Exempt: Mini's capsule hero (28) and its 16 pt volume tile (capsule family; 28 − 12 = 16 with 32 discs),
and the footer (its own pills).

Sources: developer.apple.com/videos/play/wwdc2025/356 (concentricity); developer.apple.com/documentation/swiftui/containerrelativeshape;
developer.apple.com/design/human-interface-guidelines/widgets (margins, spacing); …/materials (Liquid Glass edges);
Apple WWDC/keynote bento summary slides; linear.app and vercel.com feature grids (single card radius, hairline top-lit borders).
