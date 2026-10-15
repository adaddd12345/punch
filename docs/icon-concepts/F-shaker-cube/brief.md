# F: Shaker Cube, designer brief (build checklist)

## 1. Apple standard (macOS 26 Tahoe, Liquid Glass)
- [ ] Master is a **1024x1024** canvas. Icon Composer treats the canvas as the squircle body. Do not draw the rounded-rect or a mask; the system clips to its own shape, and Xcode adds the Dock margin. In the classic `.icns` grid that margin leaves an **824px body centered on 1024** (100px each side).
- [ ] Build it as **1 background plus up to 4 foreground groups**. Each layer is one Z step. Split layers by colour so dark/mono only need fill swaps. Number the exported files to fix Z order.
- [ ] Source art is **flat, opaque, simple**: SVG for vector parts, PNG (lossless, transparent) for gradients. Outline any text.
- [ ] **Bake no effects.** Specular edges, blur, translucency, refraction and shadow are set per layer or group in Icon Composer and rendered by the system. Light comes from **directly above** (26.4 material). Turn specular off on any area that goes "pillowy".
- [ ] Shadows: **Neutral** is the default. Use **Chromatic** only for coloured art on a light background.
- [ ] Six appearances: Default, Dark, Clear light/dark, Tinted light/dark. You author three annotations: **default, dark, mono**.
  - Mono: make the hero element pure white and map everything else to greys.
  - Dark: re-fill anything that sinks into black.
- [ ] Backgrounds are soft light-to-dark gradients, never pure white or black. A coloured background holds up best in dark mode.
- [ ] Apple asks for flatter, more frontal art over complex 3D perspective, which fights the system lighting. An isometric cube therefore has to stay simple and solid.
- [ ] **Pipeline gap:** `mac/scripts/bundle.sh` turns one PNG (with its own rounded tile) into `.icns`. Without a `.icon`/asset catalog, Tahoe may draw it in "squircle jail" with no dark/tinted variants.
  - Ship the art as a `.icon` compiled by `actool`, or at minimum fill the 824 squircle exactly.

## 2. What premium icons share (Things, Linear, Raycast, Arc, Craft, Bear, Apple)
- [ ] **One silhouette** you can read as a black blob at 16px.
- [ ] **2-3 material planes** at most: background, hero object, one accent detail.
- [ ] **Restrained palette:** 1 hue family plus **1 accent**, and the accent lives on the hero feature only.
- [ ] **Consistent light:** keep shading top-lit (top-left at most) to match the system light from above, with the brightest face on top.
- [ ] Only a **soft contact shadow** under the object. No outer glow, no long shadow.
- [ ] **No text, no thin lines, no hairline strokes.** Use rounded geometry so the specular edge has something to travel along.
- [ ] **Optical centering:** sit the mass 1-2% above true center, because the contact shadow adds visual weight below.
- [ ] **Dock test:** recognizable beside Finder, Music and Raycast at 64px and at a glance. **Menu-bar test:** readable at 16px.

## 3. Numbers (on a 1024 canvas)
- **Glyph size:** the hero object's bounding box is **55-65%** of canvas width (~560-660px). Keep **>=12% (~120px) clear** from each edge so the squircle corners never clip it.
- **Pixel maths for minimum feature size.** Icon Composer's 1024 maps onto the squircle body, so:
  - 32pt Dock/Finder: 1px is about **40 units**.
  - 16pt list/menu: 1px is about **80 units**.
  - Any feature that must survive is **>=48 units at 32px** and **>=96 units at 16px**.
  - Gaps between features: **>=64 units**.
  - Edge/stroke width: **>=40 units** (never under 24).
- **Soft-matte corner radii:**
  - Cube edges: **8-12% of the face edge length** (e.g. 40-60px on a 480px face).
  - Small parts (knob, cone, button): **25-50%** of their own size.
  - No sharp vertices.
- **Face tones (top / left / right):** about **L 100% / 78% / 62%** of the base lightness, so the gap between faces is >=15 L* steps. The top face is always the lightest.
- **Contact shadow:** an ellipse **70-85% of the base width**, about **10-14% of the base width tall**.
  - Blur **24-48px** at 1024; opacity **18-30%** at the core, fading to 0.
  - Offset **8-16px down**. Tint it with the background hue, not pure black.
- **Specular in source art:** none. If you add any for the `.icns` fallback, cap it at **<=12% white**, top edge only.
- **Accent:** **<=10-15% of the icon's area.** Its contrast against the face beneath must hold in mono (white vs grey, >=3:1).

## 4. Isometric cube pitfalls
- [ ] **Generic box, package or AR icon.** A bare cube reads as shipping, 3D, Blender or "Reality Composer".
  - Give it **one hero feature** on the top or front face (a speaker cone/woofer or the shaker's mute button) that says *sound*.
- [ ] **Equal face tones** flatten it into a hexagon. Keep the top/left/right ratios in section 3 and use a single light direction.
- [ ] **True 30-degree isometric is mechanical and wide.**
  - Consider a slightly **dimetric/frontal tilt** (the front face larger), per Apple's "flatter, frontal" guidance.
  - Otherwise make sure the silhouette is not a perfect hexagon.
- [ ] **Hero on a side face gets foreshortened to a sliver at 16px.** Put it on the top or the largest face, and size it to >=30% of that face.
- [ ] **Edge lines.** Do not outline cube edges. Separate faces by tone alone, which also keeps the system specular clean.
- [ ] **Busy layering.** Use cube faces as one group, the hero feature as one group and the shadow from the system. Leave the other groups unused unless they earn their place.
- [ ] **Mono/tinted collapse.** Faces turn to similar greys. Check the tinted preview early and lean on the hero's white for identity.
- [ ] **Floating look.** Without a contact shadow it reads as a 3D-model thumbnail. Keep the shadow tight and soft.

## Sources
- https://developer.apple.com/videos/play/wwdc2025/361/ (Create icons with Icon Composer)
- https://developer.apple.com/videos/play/wwdc2025/220/ (Say hello to the new look of app icons)
- https://wwdcnotes.com/documentation/wwdc25-220-say-hello-to-the-new-look-of-app-icons/
- https://developer.apple.com/icon-composer/ (26.4 material, light from above, appearances)
- https://developer.apple.com/design/human-interface-guidelines/app-icons
- https://mjtsai.com/blog/2025/10/02/how-to-export-a-mac-icon-file-with-the-proper-margins/ (Xcode adds the Mac margin)
- https://developer.apple.com/videos/play/wwdc2026/8012/ (2026 icon Q&A: tint contrast, small sizes)
