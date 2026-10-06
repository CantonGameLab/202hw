import sys, os
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")

def load(name):
    return Image.open(os.path.join(OUT, name)).convert("RGB")

def sheet(names, dest, cols=5, scale=0.28, labels=None):
    ims = [(n, load(n)) for n in names]
    w, h = ims[0][1].size
    tw, th = int(w * scale), int(h * scale)
    rows = (len(ims) + cols - 1) // cols
    pad = 22
    canvas = Image.new("RGB", (cols * tw, rows * (th + pad)), (18, 18, 18))
    d = ImageDraw.Draw(canvas)
    for i, (n, im) in enumerate(ims):
        r, c = divmod(i, cols)
        x, y = c * tw, r * (th + pad)
        canvas.paste(im.resize((tw, th), Image.LANCZOS), (x, y))
        d.text((x + 4, y + th + 4), (labels[i] if labels else n), fill=(255, 220, 120))
    canvas.save(os.path.join(OUT, dest))
    print("wrote", dest, canvas.size)

if __name__ == "__main__":
    heights = ["0.5", "0.6", "0.7", "0.75", "0.8", "0.9", "1", "1.2", "1.5", "2"]
    sheet([f"h_{h}.ppm" for h in heights], "sweep.png", cols=5, scale=0.30,
          labels=[f"h={h}" for h in heights])
