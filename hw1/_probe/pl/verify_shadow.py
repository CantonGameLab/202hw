"""Check the point-light shadow against geometry, not against taste.

The scene is one bust and one floor, both at the identity transform, so a shadow ray is
easy to test directly: a floor point is in shadow when the segment from it to the light
passes through the bust's box. That is an independent answer to the question the shader
answers with a cube map, and comparing the two images against it says whether the shadow
lands where it should rather than merely whether some shadow appeared.
"""

import numpy as np
from PIL import Image

CAM_EYE = np.array([0.0, 0.34, 1.05])
CAM_TARGET = np.array([0.0, 0.23, 0.0])
FOV_Y = np.radians(45.0)
W, H = 1920, 1080

LIGHT = np.array([1.3, 0.8, -1.3])


def look_at(eye, target, up):
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


def pixel_rays():
    """A world-space ray per pixel, from the same matrices the shader is fed."""
    view = look_at(CAM_EYE, CAM_TARGET, np.array([0.0, 1.0, 0.0]))
    aspect = W / H
    t = np.tan(FOV_Y / 2.0)
    xs = (np.arange(W) + 0.5) / W * 2.0 - 1.0
    ys = 1.0 - (np.arange(H) + 0.5) / H * 2.0
    gx, gy = np.meshgrid(xs, ys)
    # Camera looks down -Z with a right-handed view matrix.
    dir_cam = np.stack([gx * t * aspect, gy * t, -np.ones_like(gx)], axis=-1)
    rot = view[:3, :3].T
    dirs = dir_cam @ rot.T
    dirs /= np.linalg.norm(dirs, axis=-1, keepdims=True)
    return dirs


def hit_aabb(origin, dirs, lo, hi):
    """Slab test for a whole image of rays at once. Returns t of entry, inf for a miss."""
    inv = 1.0 / np.where(np.abs(dirs) < 1e-12, 1e-12, dirs)
    t0 = (lo - origin) * inv
    t1 = (hi - origin) * inv
    tmin = np.maximum.reduce(np.minimum(t0, t1), axis=-1)
    tmax = np.minimum.reduce(np.maximum(t0, t1), axis=-1)
    ok = (tmax >= np.maximum(tmin, 0.0))
    return np.where(ok, np.maximum(tmin, 0.0), np.inf)


def segment_blocked(a, b, lo, hi):
    """True where the segment a->b passes through the box. Vectorised over pixels."""
    d = b - a
    inv = 1.0 / np.where(np.abs(d) < 1e-12, 1e-12, d)
    t0 = (lo - a) * inv
    t1 = (hi - a) * inv
    tmin = np.maximum.reduce(np.minimum(t0, t1), axis=-1)
    tmax = np.minimum.reduce(np.maximum(t0, t1), axis=-1)
    return (tmax >= np.maximum(tmin, 0.0)) & (tmin <= 1.0) & (tmax >= 0.0)


def main():
    dirs = pixel_rays()

    # The floor asset is a plane at y = -0.028 over roughly [-1.45, 1.45]; the bust box is
    # read off the shadow map's own near/far and the probe's earlier measurements.
    floor_y = -0.028
    t_floor = (floor_y - CAM_EYE[1]) / dirs[..., 1]
    floor_hit = (t_floor > 0) & np.isfinite(t_floor)
    floor_pt = CAM_EYE + dirs * np.where(np.isfinite(t_floor), t_floor, 0.0)[..., None]
    on_floor = floor_hit & (np.abs(floor_pt[..., 0]) <= 1.45) & (np.abs(floor_pt[..., 2]) <= 1.45)

    bust_lo = np.array([-0.30, -0.028, -0.30])
    bust_hi = np.array([0.30, 0.62, 0.30])
    t_bust = hit_aabb(CAM_EYE, dirs, bust_lo, bust_hi)
    bust_pixel = np.isfinite(t_bust)

    shadowed = segment_blocked(floor_pt, LIGHT, bust_lo, bust_hi) & on_floor

    disk = np.asarray(Image.open("00_disk.png").convert("RGB"), dtype=np.float64)
    fixed = np.asarray(Image.open("02_all_units.png").convert("RGB"), dtype=np.float64)

    lum_disk = disk.mean(axis=-1)
    lum_fixed = fixed.mean(axis=-1)
    delta = lum_fixed - lum_disk

    print("pixels on the floor            :", int(on_floor.sum()))
    print("floor pixels geometry says dark:", int(shadowed.sum()))
    print()
    print("mean luminance, floor not shadowed by geometry :",
          round(float(lum_disk[on_floor & ~shadowed].mean()), 2), "->",
          round(float(lum_fixed[on_floor & ~shadowed].mean()), 2))
    print("mean luminance, floor shadowed by geometry     :",
          round(float(lum_disk[on_floor & shadowed].mean()), 2), "->",
          round(float(lum_fixed[on_floor & shadowed].mean()), 2))
    print()
    print("mean change where geometry says shadowed :", round(float(delta[on_floor & shadowed].mean()), 2))
    print("mean change where geometry says lit      :", round(float(delta[on_floor & ~shadowed].mean()), 2))

    # Agreement between the shader's darkening and the ray test, over the floor.
    darkened = delta < -8.0
    both = int((darkened & shadowed & on_floor).sum())
    only_shader = int((darkened & ~shadowed & on_floor).sum())
    only_geom = int((~darkened & shadowed & on_floor).sum())
    print()
    print("floor pixels darkened by the new build and also shadowed by geometry :", both)
    print("floor pixels darkened only by the build (false shadows)              :", only_shader)
    print("floor pixels shadowed by geometry but not darkened (missed)          :", only_geom)
    print()
    print("bust pixels in frame:", int(bust_pixel.sum()),
          " mean luminance", round(float(lum_fixed[bust_pixel].mean()), 2))

    # Where the difference actually is, so the shadow can be described rather than assumed.
    ys, xs = np.nonzero(delta < -8.0)
    if len(xs):
        print("darkened region bounds  x:", int(xs.min()), "..", int(xs.max()),
              " y:", int(ys.min()), "..", int(ys.max()), " pixels:", len(xs))


main()
