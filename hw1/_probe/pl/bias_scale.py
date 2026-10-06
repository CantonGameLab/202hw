"""What the shadow bias actually evaluates to, across light heights.

The shader derives its bias from the cube's texel footprint rather than a fixed constant. That
makes it behave differently at different distances, and the interesting question is whether it
stays the right size when the caster is close to the light -- which is exactly the range a point
light has to live in to cast a visible shadow at all.
"""

import math

NEAR_FLOOR = 0.01
FOV = math.pi / 2
RES = 1024
BIAS_TEXELS = 2.0
SLOPE_CLAMP = 4.0

# The bust, from the mesh itself.
LO = (-0.12288019, -0.02825936, -0.14459643)
HI = (0.14886943, 0.48668385, 0.15511724)

R = 0.55


def axis_dist(p, light):
    d = [abs(p[i] - light[i]) for i in range(3)]
    return max(d)


def main():
    print(f"{'height':>7} {'near':>7} {'far':>7} {'depth range':>12} "
          f"{'bust axis':>10} {'texel world':>12} {'bias world':>11} {'bias depth':>11}")
    for h in (0.5, 0.6, 0.75, 0.8, 1.0, 1.2, 1.5, 2.0):
        light = (R, h, -R)
        # PointLightDepthRange, as scene/light.odin computes it.
        centre = [(LO[i] + HI[i]) / 2 for i in range(3)]
        half_diag = math.dist(LO, HI) / 2
        nearest = [min(max(light[i], LO[i]), HI[i]) for i in range(3)]
        z_near = max(math.dist(light, nearest), half_diag * 0.01)
        z_far = math.dist(light, centre) + half_diag

        # The bust's surface closest to the light, roughly its top corner.
        top = (HI[0], HI[1], HI[2])
        axis = axis_dist(top, light)
        axis = max(axis, z_near * 1.01)

        texel_world = (2.0 * axis) / RES
        # Grazing: the light comes in at a shallow angle to the surface normal.
        n_dot_l = 0.15
        slope = min((1.0 - n_dot_l) / max(n_dot_l, 1e-3), SLOPE_CLAMP)
        bias_world = BIAS_TEXELS * texel_world * (0.25 + slope)

        dd = max(z_far - z_near, 1e-6)
        bias_depth = bias_world * (z_far * z_near) / max(axis * dd, 1e-6)

        print(f"{h:7.2f} {z_near:7.3f} {z_far:7.3f} {z_far - z_near:12.3f} "
              f"{axis:10.3f} {texel_world:12.5f} {bias_world:11.5f} {bias_depth:11.6f}")


main()
