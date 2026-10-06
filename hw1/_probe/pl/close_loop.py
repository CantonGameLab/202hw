"""The closed loop: the shader's own visibility, recovered from the render, against the
visibility a ray-cast predicts.

Three frames of the same shader are available, drawn with the point light's contribution
scaled by 0, 1 and 2. With ambient A and point contribution P, they are A, A + P*v and
A + 2*P*v, so v = (I2 - I1) / (I1 - I0) per pixel. That is the visibility the renderer
actually applied, recovered without knowing any material colour or light intensity.

Against it goes the same quantity computed the honest way: the segment from each floor point
to the light, tested against the bust's 17,456 triangles with Moller-Trumbore. No shadow map,
no projection, no convention.
"""

import numpy as np
from PIL import Image

LIGHT = np.array([1.3, 0.8, -1.3])
W, H = 1920, 1080
BIN = (r"C:\Users\GroupTheory\Source\202hw\hw1\resource\assets"
       r"\marble_bust_model\marble_bust_01_4k.bin")


def load_bust():
    raw = open("positions.bin", "rb").read()
    nl = raw.index(b"\n")
    stride = int(raw[:nl].decode().split()[2])
    off, bust = nl + 1, None
    while off < len(raw):
        nl2 = raw.index(b"\n", off)
        meta = raw[off:nl2].decode().split()
        n = int(meta[meta.index("verts") + 1])
        start = nl2 + 1
        block = np.frombuffer(raw[start:start + n * stride], dtype="<f4")
        pos = block.reshape(n, stride // 4)[:, 0:3].astype(np.float64)
        if pos[:, 1].max() - pos[:, 1].min() > 0.1:
            bust = pos
        off = start + n * stride
    idx = np.frombuffer(open(BIN, "rb").read()[311872:311872 + 52368 * 2],
                        dtype="<u2").astype(np.int64).reshape(-1, 3)
    return bust, idx


def camera_floor_points(indices):
    eye = np.array([0.0, 0.34, 1.05]); tgt = np.array([0.0, 0.23, 0.0])
    f = tgt - eye; f /= np.linalg.norm(f)
    s = np.cross(f, [0, 1, 0]); s /= np.linalg.norm(s); u = np.cross(s, f)
    view = np.eye(4); view[0, :3], view[1, :3], view[2, :3] = s, u, -f
    view[0, 3] = -s @ eye; view[1, 3] = -u @ eye; view[2, 3] = f @ eye
    t = np.tan(np.radians(45.0) / 2)
    px = indices % W
    py = indices // W
    x = (px + 0.5) / W * 2 - 1
    y = 1 - (py + 0.5) / H * 2
    dc = np.stack([x * t * (W / H), y * t, -np.ones_like(x)], -1)
    d = dc @ view[:3, :3]
    d /= np.linalg.norm(d, axis=-1, keepdims=True)
    with np.errstate(divide="ignore", invalid="ignore"):
        tt = (0.0 - eye[1]) / d[:, 1]
    pts = eye + d * tt[:, None]
    return pts, tt


def occluded(pts, verts, tris):
    """Moller-Trumbore over every triangle, batched by point."""
    v0 = verts[tris[:, 0]]
    e1 = verts[tris[:, 1]] - v0
    e2 = verts[tris[:, 2]] - v0
    # A bounding sphere per triangle rejects almost everything before the real test.
    centre = (verts[tris[:, 0]] + verts[tris[:, 1]] + verts[tris[:, 2]]) / 3.0
    radius = np.linalg.norm(verts[tris] - centre[:, None, :], axis=-1).max(axis=1)

    out = np.zeros(len(pts), dtype=bool)
    for k, p in enumerate(pts):
        seg = LIGHT - p
        seg_len = np.linalg.norm(seg)
        if seg_len < 1e-6:
            continue
        d = seg / seg_len
        # Distance from each triangle's centre to the segment's line, as a cheap reject.
        to_c = centre - p
        proj = to_c @ d
        perp = np.linalg.norm(to_c - proj[:, None] * d, axis=1)
        keep = (perp <= radius + 1e-9) & (proj > -radius) & (proj < seg_len + radius)
        if not keep.any():
            continue
        h = np.cross(d, e2[keep])
        a = np.einsum("ij,ij->i", e1[keep], h)
        ok = np.abs(a) > 1e-12
        if not ok.any():
            continue
        f = np.zeros_like(a); f[ok] = 1.0 / a[ok]
        s = p - v0[keep]
        u = f * np.einsum("ij,ij->i", s, h)
        q = np.cross(s, e1[keep])
        v = f * (q @ d)
        tt = f * np.einsum("ij,ij->i", e2[keep], q)
        good = ok & (u >= 0) & (v >= 0) & (u + v <= 1) & (tt > 1e-6) & (tt < seg_len)
        if good.any():
            out[k] = True
    return out


def main():
    v0 = np.asarray(Image.open("real_vis_0.ppm").convert("RGB"), dtype=np.float64)
    v1 = np.asarray(Image.open("real_vis_1.ppm").convert("RGB"), dtype=np.float64)
    v2 = np.asarray(Image.open("real_vis_2.ppm").convert("RGB"), dtype=np.float64)

    # Visibility as the renderer applied it. Averaged over the three channels so a colour tint
    # cancels; the material and the light's own colour divide out of the ratio.
    num = (v2 - v1).mean(axis=-1)
    den = (v1 - v0).mean(axis=-1)
    with np.errstate(divide="ignore", invalid="ignore"):
        vis_render = np.where(np.abs(den) > 3.0, num / den, np.nan)
    vis_render = np.clip(vis_render, 0.0, 1.0)

    verts, tris = load_bust()
    print(f"bust: {len(tris)} triangles")

    # Sample a regular grid of floor pixels, so the ray test stays tractable.
    step = 3
    px = np.arange(100, W, step)
    py = np.arange(520, H, step)
    gx, gy = np.meshgrid(px, py)
    idx = (gy * W + gx).ravel()

    pts, tt = camera_floor_points(idx)
    on_floor = (np.isfinite(tt) & (tt > 0)
                & (np.abs(pts[:, 0]) <= 1.5) & (np.abs(pts[:, 2]) <= 1.5))
    rv = vis_render.ravel()[idx]
    have = on_floor & np.isfinite(rv)
    print(f"sampled floor pixels: {int(have.sum())}")

    sh = occluded(pts[have], verts, tris)
    vis = rv[have]

    print()
    print("visibility the renderer applied, against the ray-cast answer on the same pixels:")
    print(f"  pixels the triangles say are shadowed : {int(sh.sum())}")
    print(f"  pixels the triangles say are lit      : {int((~sh).sum())}")
    print(f"  mean visibility where shadowed        : {vis[sh].mean():.4f}"
          f"   (a correct shadow gives 0)")
    print(f"  mean visibility where lit             : {vis[~sh].mean():.4f}"
          f"   (a correct shadow gives 1)")
    print()
    dark = vis < 0.5
    tp = int((dark & sh).sum()); fp = int((dark & ~sh).sum())
    fn = int((~dark & sh).sum()); tn = int((~dark & ~sh).sum())
    print(f"  agreement at a 0.5 cut: {(tp + tn) / len(vis) * 100:.2f}%")
    print(f"    shadowed and dark   {tp}")
    print(f"    dark but lit        {fp}   <- shadow where there is none")
    print(f"    shadowed but lit    {fn}   <- missing shadow")


main()
