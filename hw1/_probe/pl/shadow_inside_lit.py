"""For each light height, asks whether a shadow is visible inside the lit region.

Measuring the darkest pixel anywhere on the floor answers nothing, because the darkest pixel is
outside the lit circle no matter what. What matters is whether a lit patch has a dark patch
next to it, which is what a shadow is. So the lit region is found first -- the brightest part of
the floor -- and the shadow is looked for only within it.
"""

import glob
import re
import numpy as np
from PIL import Image

FLOOR = (slice(560, 1080), slice(0, 1920))
SHADOW_FRACTION = 0.45


def main():
    files = sorted(glob.glob("h_*.ppm"),
                   key=lambda f: float(re.search(r"h_([0-9.]+)\.ppm", f).group(1)))
    print(f"{'height':>7} {'lit p95':>8} {'shadowed':>9} {'shadow px':>10} "
          f"{'bust lum':>9} {'bust acne':>10}")
    for path in files:
        h = re.search(r"h_([0-9.]+)\.ppm", path).group(1)
        img = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64).mean(axis=-1)
        floor = img[FLOOR]

        lit_level = np.percentile(floor, 95)
        # Inside the lit region: bright enough to be lit at all.
        is_lit = floor > 0.55 * lit_level
        if is_lit.sum() == 0:
            print(f"{h:>7} {lit_level:8.1f} {'-':>9} {0:>10} {'-':>9} {'-':>10}")
            continue
        # Within the lit region, dark means shadow.
        shadowed = is_lit & (floor < SHADOW_FRACTION * lit_level)

        # The bust: a lit surface that is speckled with its own shadow reads as acne.
        bust = img[190:520, 820:1080]
        bust_lit = bust[bust > 0.5 * bust.max()] if bust.max() > 0 else np.array([0.0])
        acne = float(bust_lit.std()) if bust_lit.size else 0.0

        print(f"{h:>7} {lit_level:8.1f} {int(shadowed.sum()):9d} "
              f"{shadowed.sum() / max(is_lit.sum(), 1) * 100:9.2f}% "
              f"{bust.mean():9.1f} {acne:10.2f}")


main()
