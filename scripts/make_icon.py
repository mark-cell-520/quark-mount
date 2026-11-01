#!/usr/bin/env python3
"""生成 App 图标：蓝紫渐变圆角方块 + 白色云朵 + 下载箭头"""
from PIL import Image, ImageDraw
import os

S = 1024
import sys, os
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "icon.iconset")
os.makedirs(OUT, exist_ok=True)

def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))

TOP = (58, 123, 248)    # 蓝
BOT = (139, 92, 246)    # 紫

img = Image.new("RGB", (S, S))
d = ImageDraw.Draw(img)
# 对角渐变
for y in range(S):
    for_x = y / S
    row = [lerp(TOP, BOT, (x / S * 0.35 + for_x * 0.65)) for x in range(0, S, 8)]
    for i, x in enumerate(range(0, S, 8)):
        d.rectangle([x, y, x + 7, y], fill=row[i])

# 圆角遮罩
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=int(S * 0.235), fill=255)
out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
out.paste(img, (0, 0), mask)

d = ImageDraw.Draw(out)
cx, cy = S * 0.5, S * 0.44

# 云朵（多个圆叠加）
cloud = [(cx - 235, cy + 20, 150), (cx - 60, cy - 85, 185), (cx + 130, cy - 20, 150)]
for (x, y, r) in cloud:
    d.ellipse([x - r, y - r, x + r, y + r], fill=(255, 255, 255, 255))
d.rounded_rectangle([cx - 340, cy + 10, cx + 260, cy + 165], radius=78, fill=(255, 255, 255, 255))

# 下载箭头（紫色，从云到底部托盘）
arrow = (88, 80, 235)
ax = cx
d.rounded_rectangle([ax - 26, cy + 30, ax + 26, cy + 205], radius=26, fill=arrow)
d.polygon([(ax - 78, cy + 175), (ax + 78, cy + 175), (ax, cy + 300)], fill=arrow)
# 托盘
d.rounded_rectangle([cx - 175, cy + 330, cx + 175, cy + 392], radius=31, fill=arrow)

sizes = [(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"), (32, "icon_32x32.png"),
         (64, "icon_32x32@2x.png"), (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
         (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"), (512, "icon_512x512.png"),
         (1024, "icon_512x512@2x.png")]
for px, name in sizes:
    out.resize((px, px), Image.LANCZOS).save(os.path.join(OUT, name))
print("iconset 生成完毕:", len(sizes), "个尺寸")
