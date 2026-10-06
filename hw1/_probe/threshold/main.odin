package probe

import "core:fmt"
import "core:math"

// The set of floor points where the shader's radiance equals 1.0, without any reference to
// the shadow map: the light is above a flat floor, so radiance depends only on the
// horizontal distance and the light's height.
//
// If the hard edge in the render is this curve, then it is a saturation threshold and not
// a shadow, a cube face seam, or anything the sampler produced.
main :: proc() {
	lp := [3]f32{0.55, 0.8, 0.55}
	floor_y: f32 = -0.02825936
	intensity: f32 = 2.4
	h := lp.y - floor_y

	fmt.println("the shader's own expression, with visibility left at 1:")
	fmt.println("   radiance = intensity * (max(N.L,0) * 0.5 + 0.5) / d^2")
	fmt.println("   light", lp, " height above the floor", h, " intensity", intensity)
	fmt.println()

	radiance_at :: proc(h, intensity, r: f32) -> f32 {
		d := f32(math.sqrt(f64(h*h + r*r)))
		n_dot_l := (h / d) * 0.5 + 0.5
		return intensity * n_dot_l / (d * d)
	}

	radius_where :: proc(h, intensity, level: f32) -> f32 {
		lo: f32 = 0
		hi: f32 = 50
		for _ in 0 ..< 80 {
			r := (lo + hi) * 0.5
			if radiance_at(h, intensity, r) > level {
				lo = r
			} else {
				hi = r
			}
		}
		return lo
	}

	r1 := radius_where(h, intensity, 1.0)
	fmt.println("radiance crosses 1.0 at horizontal radius", r1)
	fmt.println("so the clipped (pure white) region is a disc of that radius around (", lp.x, ",", lp.z, ")")
	fmt.println()

	fmt.println("the whole profile, radially, so the step at 1.0 can be seen:")
	fmt.println("     radius    N.L term   radiance   8-bit value")
	steps := 40
	for k in 0 ..< steps {
		r := f32(k) / f32(steps-1) * 2.4
		d := f32(math.sqrt(f64(h*h + r*r)))
		n_dot_l := (h / d) * 0.5 + 0.5
		rad := intensity * n_dot_l / (d * d)
		shown := rad
		if shown > 1.0 {
			shown = 1.0
		}
		fmt.println(
			"    ", r, "   ", n_dot_l, "   ", rad, "   ",
			int(shown * 255.0), rad > 1.0 ? "  <- would be higher, stored as 255" : "",
		)
	}
	fmt.println()

	fmt.println("what the radii become for other intensities:")
	for i in ([5]f32{2.4, 1.6, 1.0, 0.686, 0.4}) {
		rr := radius_where(h, i, 1.0)
		peak := radiance_at(h, i, 0)
		fmt.println("   intensity", i, " peak radiance", peak, " radius where it hits 1.0:", rr)
	}
}
