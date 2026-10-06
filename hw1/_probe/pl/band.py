import os
import numpy as np
from PIL import Image

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")

def gray(name):
    return np.asarray(Image.open(os.path.join(OUT, name)).convert("L"), dtype=np.float32)

# Sky is the top-left corner; the floor is the big lower region. The bust is near the centre.
for h in ["0.5", "0.55", "0.6", "0.65", "0.7", "0.75", "0.8"]:
    p = f"h_{h}.ppm"
    if not os.path.exists(os.path.join(OUT, p)):
        continue
    a = gray(p)
    # floor band well in front of the bust, below the plinth, across the full width
    band = a[700:1040, 100:1820]
    dark = (band < 30).sum()
    mid = ((band >= 30) & (band < 120)).sum()
    lit = (band >= 120).sum()
    tot = band.size
    # the very bottom strip of the frame (nearest floor to the camera)
    near = a[1040:1080, 100:1820]
    print(f"h={h:>5}  band mean={band.mean():6.1f}  dark<30={100*dark/tot:5.1f}%  "
          f"mid={100*mid/tot:5.1f}%  lit>=120={100*lit/tot:5.1f}%   nearstrip mean={near.mean():6.1f}")
