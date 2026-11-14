#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Tạo AppIcon 1024px cho Open Photobooth (không dùng tài nguyên bản quyền)."""
from PIL import Image, ImageDraw

W = 1024
img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# Nền bo góc gradient tím - xanh
def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(4))

top = (98, 91, 255, 255)     # tím
bottom = (46, 130, 255, 255) # xanh
body_h = int(W * 0.90)
for y in range(body_h):
    t = y / max(1, body_h - 1)
    d.line([(0, y), (W, y)], fill=lerp(top, bottom, t))
mask = Image.new("L", (W, W), 0)
md = ImageDraw.Draw(mask)
md.rounded_rectangle([8, 8, W - 8, W - 8], radius=180, fill=255)
bg = Image.new("RGBA", (W, W), (0, 0, 0, 0))
bg.paste(img, (0, 0), mask)
d = ImageDraw.Draw(bg)

# Thân máy ảnh
cx, cy = W // 2, int(W * 0.52)
body_w, body_h2 = int(W * 0.56), int(W * 0.38)
bx0, by0 = cx - body_w // 2, cy - body_h2 // 2
d.rounded_rectangle([bx0, by0, bx0 + body_w, by0 + body_h2], radius=64, fill=(255, 255, 255, 255))

# Cụm gương máy
d.rounded_rectangle([cx - 170, by0 - 56, cx + 170, by0 + 40], radius=40, fill=(255, 255, 255, 255))

# Ống kính
r = int(W * 0.105)
d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(40, 52, 90, 255))
r2 = int(r * 0.62)
d.ellipse([cx - r2, cy - r2, cx + r2, cy + r2], fill=(120, 190, 255, 255))
r3 = int(r * 0.30)
d.ellipse([cx - r3 + 40, cy - r3 - 40, cx + r3 + 40, cy + r3 - 40], fill=(235, 248, 255, 255))

# Dải ảnh photostrip góc dưới
strip_w, strip_h = int(W * 0.34), int(W * 0.16)
sx, sy = int(W * 0.56), int(W * 0.70)
d.rounded_rectangle([sx, sy, sx + strip_w, sy + strip_h], radius=16, fill=(255, 244, 214, 255))
for i in range(2):
    yy = sy + 14 + i * (strip_h - 24) // 2
    d.rectangle([sx + 12, yy, sx + strip_w - 12, yy + 22], fill=(86, 108, 255, 255))
for i in range(4):
    hx = sx + 16 + i * (strip_w - 32) // 3
    d.ellipse([hx - 7, sy + strip_h - 14, hx + 7, sy + strip_h], fill=(200, 160, 60, 255))

bg.save("/home/z/my-project/download/OpenPhotobooth/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
print("AppIcon.png created")
