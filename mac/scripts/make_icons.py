# Regenerates AppIcon.png + MenuBarIcon*.png from the source artwork:
#   python3 mac/scripts/make_icons.py mac/Resources/source/icon-source.webp mac/Resources /tmp/icon-preview.png
import sys
import numpy as np
from PIL import Image, ImageFilter

src, outdir, preview = sys.argv[1], sys.argv[2], sys.argv[3]
im = np.asarray(Image.open(src).convert("RGB")).astype(np.float32)
bg = np.array([216.0, 216.0, 216.0])
cream = np.array([252.0, 249.0, 241.0])

# --- app icon: cut the rounded tile out of the grey background -----------
dist = np.linalg.norm(im - bg, axis=2)
dcream = np.linalg.norm(cream - bg)
alpha = np.clip(dist / dcream, 0, 1)
ys, xs = np.where(alpha > 0.5)
y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
tile = im[y0:y1, x0:x1]
a = alpha[y0:y1, x0:x1][..., None]
# Un-blend the antialiased edge from the grey background.
rgb = np.where(a > 1e-3, (tile - (1 - a) * bg) / np.maximum(a, 1e-3), 0)
rgba = np.concatenate([np.clip(rgb, 0, 255), a * 255], axis=2).astype(np.uint8)
tile_img = Image.fromarray(rgba, "RGBA")

# macOS icon grid: 824 px tile centred on a 1024 canvas, soft drop shadow.
S = 1024
T = 824
tile_img = tile_img.resize((T, T), Image.LANCZOS)
canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
sh_alpha = tile_img.split()[3].point(lambda v: int(v * 0.35))
shadow.paste(Image.new("RGBA", (T, T), (0, 0, 0, 255)), ((S - T) // 2, (S - T) // 2 + 12), sh_alpha)
shadow = shadow.filter(ImageFilter.GaussianBlur(14))
canvas = Image.alpha_composite(canvas, shadow)
canvas.alpha_composite(tile_img, ((S - T) // 2, (S - T) // 2))
canvas.save(f"{outdir}/AppIcon.png")

# --- menu bar template: the black shaker only ----------------------------
lum = tile.mean(axis=2)
ink = np.clip((cream.mean() - lum) / (cream.mean() - 8.0), 0, 1)
ink[a[..., 0] < 0.99] = 0  # ignore the tile edge
ys, xs = np.where(ink > 0.5)
cy0, cy1, cx0, cx1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
glyph = ink[cy0:cy1, cx0:cx1]
h, w = glyph.shape
side = int(max(h, w) * 1.04)  # tiny margin so antialiasing isn't clipped
sq = np.zeros((side, side), np.float32)
sq[(side - h) // 2:(side - h) // 2 + h, (side - w) // 2:(side - w) // 2 + w] = glyph
mask = Image.fromarray((sq * 255).astype(np.uint8), "L")
for px, name in [(18, "MenuBarIcon.png"), (36, "MenuBarIcon@2x.png"), (54, "MenuBarIcon@3x.png")]:
    m = mask.resize((px, px), Image.LANCZOS)
    out = Image.new("RGBA", (px, px), (0, 0, 0, 0))
    out.putalpha(m)
    out.save(f"{outdir}/{name}")

# Preview sheet: app icon + menu bar sizes on light and dark bars.
sheet = Image.new("RGBA", (1100, 560), (245, 245, 245, 255))
sheet.alpha_composite(canvas.resize((512, 512), Image.LANCZOS), (20, 24))
for row, (bgc, tint) in enumerate([((236, 236, 236, 255), (0, 0, 0)), ((40, 40, 44, 255), (255, 255, 255))]):
    bar = Image.new("RGBA", (520, 120), bgc)
    x = 20
    for px in (18, 36, 54):
        m = mask.resize((px, px), Image.LANCZOS)
        g = Image.new("RGBA", (px, px), tint + (255,))
        g.putalpha(m)
        big = g.resize((px * 2, px * 2), Image.NEAREST)  # magnify to inspect pixels
        bar.alpha_composite(big, (x, (120 - px * 2) // 2))
        x += px * 2 + 40
    sheet.alpha_composite(bar, (560, 40 + row * 160))
sheet.save(preview)
print("tile bbox", (x0, y0, x1, y1), "glyph", (cx0, cy0, cx1, cy1))
