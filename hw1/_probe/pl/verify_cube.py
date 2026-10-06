"""Does the cube actually contain the caster?

The cube's texels are read back verbatim. For each texel the ray from the light through
that texel's direction is intersected with two known solids -- the bust's box and the floor
plane -- and the stored depth is compared against what each would have written. A texel
where the bust is nearer than the floor but the stored value matches the floor's distance is
a texel the caster never reached.
"""

import numpy as np

BUST_LO = np.array([-0.12288019, -0.02825936, -0.14459643])
BUST_HI = np.array([0.14886943, 0.48668385, 0.15511724])
FLOOR_Y = 0.0
FLOOR_HALF = 1.5


def parse(path):
    with open(path, "rb") as f:
        header = b""
        while not header.endswith(b"\n"):
            header += f.read(1)
        parts = header.decode().split()
        assert parts[0] == "PLCB", header
        size = int(parts[1])
        nfaces = int(parts[2])
        light = np.array([float(parts[3]), float(parts[4]), float(parts[5])])
        zn, zf = float(parts[6]), float(parts[7])
        faces = np.frombuffer(f.read(size * size * 4 * nfaces), dtype=np.float32)
        faces = faces.reshape(nfaces, size, size)
    return size, light, zn, zf, faces

def face_dirs(face, u, v):
    """Directions a face's (u, v) grid names, in world axes, for GL's cube convention."""
    if face == 0:
        d = np.stack([np.ones_like(u), -v, -u], axis=-1)
    elif face == 1:
        d = np.stack([-np.ones_like(u), -v, u], axis=-1)
    elif face == 2:
        d = np.stack([u, np.ones_like(u), v], axis=-1)
    elif face == 3:
        d = np.stack([u, -np.ones_like(u), -v], axis=-1)
    elif face == 4:
        d = np.stack([u, -v, np.ones_like(u)], axis=-1)
    else:
        d = np.stack([-u, -v, -np.ones_like(u)], axis=-1)
    return d / np.linalg.norm(d, axis=-1, keepdims=True)


def dist_to_bust(origin, d):
    """Nearest positive hit distance against the box, inf where the ray misses."""
    inv = 1.0 / np.where(np.abs(d) < 1e-12, 1e-12, d)
    t0 = (BUST_LO - origin) * inv
    t1 = (BUST_HI - origin) * inv
    tmin = np.maximum.reduce(np.minimum(t0, t1), axis=-1)
    tmax = np.minimum.reduce(np.maximum(t0, t1), axis=-1)
    ok = (tmax >= np.maximum(tmin, 0.0))
    return np.where(ok, np.maximum(tmin, 0.0), np.inf)


def dist_to_floor(origin, d):
    """Distance to the floor plane inside its own extent, inf otherwise."""
    with np.errstate(divide="ignore", invalid="ignore"):
        t = (FLOOR_Y - origin[1]) / d[..., 1]
    hit = np.isfinite(t) & (t > 0)
    p = origin + d * np.where(hit, t, 0.0)[..., None]
    hit &= (np.abs(p[..., 0]) <= FLOOR_HALF) & (np.abs(p[..., 2]) <= FLOOR_HALF)
    return np.where(hit, t, np.inf)


def distance_to_depth(dist, zn, zf):
    return (1.0 / dist - 1.0 / zn) / (1.0 / zf - 1.0 / zn)


def depth_to_distance(stored, zn, zf):
    return (zn * zf) / (zf - stored * (zf - zn))


def main():
    size, light, zn, zf, faces = parse("cube_raw.bin")
    print(f"cube {size}x{size}, light {light}, near {zn:.6f} far {zf:.6f}")

    u = ((np.arange(size) + 0.5) / size * 2.0 - 1.0)[None, :].repeat(size, 0)
    v = ((np.arange(size) + 0.5) / size * 2.0 - 1.0)[:, None].repeat(size, 1)

    totals = {"bust nearer, stored matches bust": 0,
              "bust nearer, stored matches floor": 0,
              "floor nearer, stored matches floor": 0,
              "neither matches": 0,
              "stored empty": 0}

    for face in range(6):
        stored = faces[face]
        empty = stored >= 0.9999
        d = face_dirs(face, u, v)
        db = dist_to_bust(light, d)
        df = dist_to_floor(light, d)

        stored_dist = depth_to_distance(stored.astype(np.float64), zn, zf)
        bust_nearer = db < df

        # "Matches" allows the texel's own quantization: a face of a cube is 1 K texels
        # across and a distance lands somewhere inside one.
        tol = 0.02 * np.maximum(stored_dist, 1.0)
        m_bust = np.abs(stored_dist - db) <= tol
        m_floor = np.abs(stored_dist - df) <= tol

        totals["stored empty"] += int(empty.sum())
        valid = ~empty
        totals["bust nearer, stored matches bust"] += int((valid & bust_nearer & m_bust).sum())
        totals["bust nearer, stored matches floor"] += int((valid & bust_nearer & m_floor & ~m_bust).sum())
        totals["floor nearer, stored matches floor"] += int((valid & ~bust_nearer & m_floor).sum())
        totals["neither matches"] += int((valid & ~m_bust & ~m_floor).sum())

        if face in (1, 3, 5):
            nb = int((valid & bust_nearer).sum())
            print(f"  face {face}: texels where the bust is the nearest solid: {nb}")

    print()
    for k, val in totals.items():
        print(f"  {k:<38} {val}")


main()
