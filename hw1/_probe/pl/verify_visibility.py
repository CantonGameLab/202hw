"""Agreement between the cube filter's visibility and a ray-cast answer, per bias.

The scene is a bust box over a floor plane, both at the identity transform, so "is this
floor point lit" has an exact answer that uses no shadow map at all: walk the segment from
the point to the light and see whether it crosses the bust. The shader writes its own
answer into one channel per bias, and the two are compared over the floor.
"""

import sys
import numpy as np
from PIL import Image

CAM_EYE = np.array([0.0, 0.34, 1.05])
CAM_TARGET = np.array([0.0, 0.23, 0.0])
FOV_Y = np.radians(45.0)
W, H = 1920, 1080

BUST_LO = np.array([-0.12288019, -0.02825936, -0.14459643])
BUST_HI = np.array([0.14886943, 0.48668385, 0.15511724])
FLOOR_Y = 0.0
FLOOR_HALF = 1.5
LIGHT = np.array([1.3, 0.8, -1.3])

BIASES = ["0", "1e-05", "0.0001", "0.0002", "0.0005", "0.0015"]
MEASURES = ["euclid", "axis"]


def view_matrix(eye, target, up):
    f = target - eye
    f /= np.linalg.norm(f)
    s = np.cross(f, up)
    s /= np.linalg.norm(s)
    u = np.cross(s, f)
    m = np.eye(4)
    m[0, :3] = s
    m[1, :3] = u
    m[2, :3] = -f
    m[0, 3] = -s @ eye
    m[1, 3] = -u @ eye
    m[2, 3] = f @ eye
    return m


def camera_rays():
    view = view_matrix(CAM_EYE, CAM_TARGET, np.array([0.0, 1.0, 0.0]))
    t = np.tan(FOV_Y / 2.0)
    aspect = W / H
    xs = (np.arange(W) + 0.5) / W * 2.0 - 1.0
    ys = 1.0 - (np.arange(H) + 0.5) / H * 2.0
    gx, gy = np.meshgrid(xs, ys)
    dir_cam = np.stack([gx * t * aspect, gy * t, -np.ones_like(gx)], axis=-1)
    dirs = dir_cam @ view[:3, :3]
    return dirs / np.linalg.norm(dirs, axis=-1, keepdims=True)


def slab(origin, d, lo, hi):
    inv = 1.0 / np.where(np.abs(d) < 1e-12, 1e-12, d)
    t0 = (lo - origin) * inv
    t1 = (hi - origin) * inv
    lo_t = np.maximum.reduce(np.minimum(t0, t1), axis=-1)
    hi_t = np.minimum.reduce(np.maximum(t0, t1), axis=-1)
    return lo_t, hi_t


def build_masks():
    dirs = camera_rays()
    b_lo, b_hi = slab(CAM_EYE, dirs, BUST_LO, BUST_HI)
    t_bust = np.where((b_hi >= np.maximum(b_lo, 0)) & (b_hi > 0), np.maximum(b_lo, 0.0), np.inf)

    with np.errstate(divide="ignore", invalid="ignore"):
        t_floor = (FLOOR_Y - CAM_EYE[1]) / dirs[..., 1]
    t_floor = np.where((t_floor > 0) & np.isfinite(t_floor), t_floor, np.inf)

    is_floor = (t_floor < t_bust) & np.isfinite(t_floor)
    pt = CAM_EYE + dirs * np.where(np.isfinite(t_floor), t_floor, 0.0)[..., None]
    is_floor &= (np.abs(pt[..., 0]) <= FLOOR_HALF) & (np.abs(pt[..., 2]) <= FLOOR_HALF)

    seg = LIGHT - pt
    s_lo, s_hi = slab(pt, seg, BUST_LO, BUST_HI)
    occluded = (s_hi >= np.maximum(s_lo, 0.0)) & (s_lo <= 1.0) & (s_hi >= 0.0)
    occluded &= np.linalg.norm(seg, axis=-1) > 1e-3
    return is_floor, occluded, pt


def main():
    is_floor, occluded, pt = build_masks()
    print("floor pixels:", int(is_floor.sum()),
          " of which geometry says occluded:", int((occluded & is_floor).sum()))
    print()
    print(f"{'measure':>7} {'bias':>9} {'agreement':>10} {'false lit':>10} {'false dark':>11} "
          f"{'mean vis lit':>13} {'mean vis occl':>14}")

    results = {}
    for measure in MEASURES:
        for tag in BIASES:
            img = np.asarray(Image.open(f"vis_{measure}_bias_{tag}.ppm").convert("RGB"), dtype=np.float64)
            vis = img.mean(axis=-1) / 255.0
            lit = vis > 0.5
            tp = int((lit & ~occluded & is_floor).sum())
            fp = int((lit & occluded & is_floor).sum())
            tn = int((~lit & occluded & is_floor).sum())
            fn = int((~lit & ~occluded & is_floor).sum())
            tot = tp + fp + tn + fn
            agree = (tp + tn) / tot * 100.0 if tot else float("nan")
            results[(measure, tag)] = (agree, fp, fn)
            print(f"{measure:>7} {tag:>9} {agree:>9.2f}% {fp:>10} {fn:>11} "
                  f"{vis[is_floor & ~occluded].mean():>13.4f} {vis[is_floor & occluded].mean():>14.4f}")

    print()
    best = max(results.items(), key=lambda kv: kv[1][0])
    print("best agreement:", best[0][0], "at bias", best[0][1], "->",
          round(best[1][0], 3), "%")


main()
