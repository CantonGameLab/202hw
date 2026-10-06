import math

lo = (-0.12288019, -0.02825936, -0.14459643)
hi = (0.14886943, 0.48668385, 0.15511724)
R = 0.55

bx = min(max(R, lo[0]), hi[0])
bz = min(max(-R, lo[2]), hi[2])
d_horiz = math.hypot(R - bx, -R - bz)

print(f"light at ({R:.2f}, h, {-R:.2f}), bust near the origin")
print(f"horizontal distance from the light to the bust's lowest part: {d_horiz:.4f}")
print()
print("The lit region is the cone from the light down to y=0, whose radius is the height,")
print("so the bust's base is inside it only when the height reaches that horizontal distance.")
print()
print(f"{'height':>7} {'base lit?':>10} {'irradiance there':>17} {'shadow visible':>15}")
for h in (0.55, 0.60, 0.70, 0.75, 0.78, 0.80, 0.85, 0.90, 1.00, 1.20, 1.50):
    ok = h >= d_horiz
    d = math.hypot(R - bx, h - lo[1], -R - bz)
    irr = 1.0 / (d * d)
    print(f"{h:7.2f} {('yes' if ok else 'no'):>10} {irr:17.4f} {('yes' if ok else 'no'):>15}")
