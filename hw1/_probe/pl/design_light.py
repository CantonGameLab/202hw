"""Picks a point-light position and intensity for the existing scene.

The constraints are geometric, not aesthetic:

  * The lit region of the floor is the cone from the light down to y = 0, so its radius is
    the light's height. The bust sits at the floor's centre, so it is inside the lit region
    only when the light's height is at least its horizontal distance from the bust.
  * A shadow's length grows as the light gets lower relative to the caster. A light that
    only just clears the caster throws a very short shadow, and one that is far above throws
    almost none; the ratio of the two decides it.
  * The shadow has to land on floor that is itself lit, which is the same condition as the
    caster being lit.
  * Irradiance falls as 1/d^2, so raising the light to satisfy the first constraint forces
    the intensity up by roughly the square of the distance.

Everything below is solved against the bust's own bounds and the floor's extent, so the
numbers that come out are the ones the scene actually needs.
"""

import math

BUST_LO = (-0.12288019, -0.02825936, -0.14459643)
BUST_HI = (0.14886943, 0.48668385, 0.15511724)
BUST_CENTRE = tuple((a + b) / 2 for a, b in zip(BUST_LO, BUST_HI))
FLOOR_HALF = 1.5
AMBIENT = 0.11
BASE_ROUGH = 0.35


def evaluate(height, radius, intensity):
    """What a light at (radius, height, -radius) does to this scene."""
    light = (radius, height, -radius)
    d_horiz = math.hypot(light[0] - BUST_CENTRE[0], light[2] - BUST_CENTRE[2])
    lit_radius = height

    # The bust's foot is what decides whether it can cast a shadow into lit floor at all.
    bust_inside = d_horiz <= lit_radius

    # Where the bust's top edge lands on the floor: the far end of the shadow.
    top = (BUST_CENTRE[0], BUST_HI[1], BUST_CENTRE[2])
    dy = top[1] - light[1]
    if dy == 0:
        return None
    t = (0.0 - light[1]) / dy
    shadow_tip = tuple(light[i] + (top[i] - light[i]) * t for i in range(3))
    shadow_len = math.hypot(shadow_tip[0] - top[0], shadow_tip[2] - top[2])

    tip_dist = math.hypot(shadow_tip[0] - light[0], shadow_tip[2] - light[2])
    tip_lit = tip_dist <= lit_radius
    tip_on_floor = abs(shadow_tip[0]) <= FLOOR_HALF and abs(shadow_tip[2]) <= FLOOR_HALF

    # Brightness a fragment at the bust's height sees, and one on the open floor below.
    d_bust = math.dist(light, top)
    d_floor = math.hypot(light[0], light[1], light[2])
    rad_bust = intensity / (d_bust * d_bust)
    rad_floor = intensity / (d_floor * d_floor)

    lit_bust = (BASE_ROUGH * (rad_bust * 0.75 + AMBIENT)) * 255
    lit_floor = (BASE_ROUGH * (rad_floor * 0.75 + AMBIENT)) * 255
    shadow_floor = (BASE_ROUGH * AMBIENT) * 255

    return dict(
        d_horiz=d_horiz, lit_radius=lit_radius, bust_inside=bust_inside,
        shadow_len=shadow_len, tip=shadow_tip, tip_lit=tip_lit,
        tip_on_floor=tip_on_floor, mid_dist=math.hypot(
            light[0] - (BUST_CENTRE[0] + shadow_tip[0]) / 2,
            light[1],
            light[2] - (BUST_CENTRE[2] + shadow_tip[2]) / 2),
        lit_bust=lit_bust, lit_floor=lit_floor, shadow_floor=shadow_floor,
        shadow_contrast=lit_floor - shadow_floor,
    )


def main():
    print("照到胸像的条件: 灯高 >= 灯到胸像的水平距离")
    print()
    print("  灯高  水平半径  灯到胸像水平距  照得到?  影长(m)  影子落在照亮区?  地板亮度  胸像亮度  影/亮对比")
    good = []
    for height in (0.8, 1.2, 1.5, 1.8, 2.0, 2.5):
        for radius in (0.7, 1.0, 1.2, 1.5):
            # Intensity chosen so the bust lands near the middle of the 8-bit range.
            probe = evaluate(height, radius, 1.0)
            if probe is None:
                continue
            target_bust = 150.0
            intensity = target_bust / probe["lit_bust"]
            r = evaluate(height, radius, intensity)
            mark = ""
            if r["bust_inside"] and r["tip_lit"] and r["tip_on_floor"] and r["shadow_len"] > 0.35:
                good.append((height, radius, intensity, r))
                mark = " <=="
            print(f"  {height:4.1f}  {radius:7.1f}  {r['d_horiz']:13.2f}  "
                  f"{'是' if r['bust_inside'] else '否':>6}  {r['shadow_len']:7.2f}  "
                  f"{'是' if r['tip_lit'] else '否':>14}  {r['lit_floor']:8.0f}  "
                  f"{r['lit_bust']:8.0f}  {r['shadow_contrast']:9.0f}{mark}")
    print()
    print("满足全部约束的候选:")
    for height, radius, intensity, r in good:
        print(f"  灯 ({radius}, {height}, {-radius})  强度 {intensity:.1f}"
              f"   影长 {r['shadow_len']:.2f} m  影子尖端 {tuple(round(v, 2) for v in r['tip'])}")
    return good


main()
