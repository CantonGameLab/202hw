import os
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")

# The floor in front of and around the bust base, where a short shadow would live.
BOX = (620, 520, 1560, 940)   # x0,y0,x1,y1 in the 1920x1080 frame

def load(name):
    return Image.open(os.path.join(OUT, name)).convert("RGB")

heights = ["0.6", "0.7", "0.8", "0.9", "1", "1.5"]
crops = [(h, load(f"h_{h}.ppm").crop(BOX)) for h in heights]
tw, th = crops[0][1].size
cols, pad = 3, 26
rows = (len(crops) + cols - 1) // cols
canvas = Image.new("RGB", (cols * tw, rows * (th + pad)), (18, 18, 18))
d = ImageDraw.Draw(canvas)
for i, (h, im) in enumerate(crops):
    r, c = divmod(i, cols)
    x, y = c * tw, r * (th + pad)
    canvas.paste(im, (x, y))
    d.text((x + 6, y + th + 6), f"h={h}   crop {BOX}", fill=(255, 220, 120))
canvas.save(os.path.join(OUT, "shadow_shape.png"))
print("wrote shadow_shape.png", canvas.size)

# Also: where is the shadow, exactly? Report the darkest floor pixel and its x offset
import numpy as np
for h in heights:
    a = np.asarray(load(f"h_{h}.ppm"), dtype=np.float32).mean(axis=2)
    floor = a[520:940, 620:1560]
    # column-wise mean brightness = where the dark band sits
    colmean = floor.mean(axis=0)
    xmin = int(np.argmin(colmean))
    print(f"h={h:>4}  darkest column x={620+xmin}  colmean_min={colmean[xmin]:6.1f}  "
          f"colmean_max={colmean.max():6.1f}  overall={floor.mean():6.1f}")
