# 45: Breathing room (2026-10-19)

The reference is a spacing-system demo. Five named dials drive a dashboard:
- page margin: 20 → 40;
- section gap: 20 → 48;
- column gap: 20 → **12**;
- card padding: 12 → 24;
- sidebar: 184 → 248.

Space between groups and inside cards grew, and space between siblings shrank. Groups read as groups by proximity.

The team was two spacing auditors (the popup; the Tempo popups and drawers) and a system lead.

## What was wrong
- **Popup:** the gap between blocks was the same as the gap inside them (8 and 8), so the blocks didn't read as groups. Inside the hero, the gaps (12/16) were larger than those between blocks.
- **Tempo:**
  - The order was inverted: the two groups sat 6 apart while their cards sat 8 apart.
  - The corners didn't nest: a group corner of 14 sat inside a panel corner of 12.
  - The drawer forced a width of 360, which clipped the big-screen side-by-side pair (738 wide).

## Tokens (`Spacing.swift`)
Each value passes through three anchors and lands on the 2 pt grid:

| Token | Tight (0) | Standard (½) | Airy (1) | Used for |
|---|---|---|---|---|
| `section` | 10 | 14 | 20 | between blocks, the footer, the Dock header, the Tempo groups, Appearance's sections |
| `sibling` | 8 | 8 | 6 | tiles inside a block, cards inside a Tempo group, header to cards |
| `panelMargin` | 6 | 8 | 10 | Tempo's parent panel |
| `groupPad` | 10 | 12 | 14 | a Tempo group |

- **Siblings only tighten** as the room grows.
- **Fixed:** the 12 pt popover margin. The popover's corner, the footer capsule (radius 18, 6 pt in) and Classic Mini's 164 + 8 + 164 columns are all cut to it.
- **Also fixed:**
  - card padding: tiles have fixed heights inside;
  - hit areas, type, control sizes;
  - the 360 width.
- **Mini** stays dense at 8.
- **Tempo corners nest:** card 10, group = card + `groupPad`, and the panel (the drawer's clip, `show(corner:)`) = group + `panelMargin`. At Standard that is 10, 22 and 30.
- **Width:** the wide card stays 177 and the other card takes what's left.
- The drawer takes Tempo's own width (`show(fitsContent:)`).

## The slider
- **Where:** Appearance › Background › Breathing room, as the first card.
- **Settings:** five detents named Tight, Snug, Standard, Roomy and Airy.
- **Motion:** the popup and the Tempo panel reflow with a 0.35 s spring with no bounce (none under Reduce Motion).
- **Live preview:** Appearance's own section gaps follow, so dragging shows the change while the blocks are hidden.
- **Drawers:** they get it through `DrawerAppearance.breathingRoom`.
- **Reshuffle:** dragging blocks uses the gap captured when the drag began.
