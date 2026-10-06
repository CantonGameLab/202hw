package probe

import "core:fmt"
import "core:math"

// Where the light's pool reaches the top of the 8-bit range, worked out from the same
// expression the shader evaluates. The floor is flat, its normal is +Y, and the light is
// above it, so the only variables are the horizontal distance and the light's height.
//
// radiance = intensity * (max(N.L, 0) * 0.5 + 0.5) / d^2, and d^2 = h^2 + r^2 with
// N.L = h / d. Radiance reaches 1 at the radius solved for below.
main :: proc() {
	lp := [3]f32{0.55, 0.8, 0.55}
	floor_y: f32 = -0.02825936
	intensity: f32 = 2.4
	h := lp.y - floor_y

	fmt.println("light", lp, " intensity", intensity, " height above the floor", h)
	fmt.println()

	radius_at :: proc(h, intensity, level: f32) -> f32 {
		lo: f32 = 0
		hi: f32 = 50
		for _ in 0 ..< 80 {
			r := (lo + hi) * 0.5
			d := f32(math.sqrt(f64(h*h + r*r)))
			nl := h / d
			v := intensity * (max(nl, 0.0) * 0.5 + 0.5) / (d * d)
			if v > level {
				lo = r
			} else {
				hi = r
			}
		}
		return lo
	}

	// The pool is a circle around the point under the light, cut off by the floor's edge.
	r1 := radius_at(h, intensity, 1.0)
	fmt.println("the pool reaches 1.0 (white in an 8-bit target) at horizontal radius", r1)
	fmt.println("   that circle is centred on (", lp.x, ",", lp.z, ") and spans")
	fmt.println("      x", lp.x - r1, "..", lp.x + r1, "   z", lp.z - r1, "..", lp.z + r1)
	fmt.println("   the floor is -1.5 .. 1.5 in both, so the circle is cut by the edge at 1.5")
	fmt.println()

	fmt.println("how tall the pool is, at several thresholds:")
	for level in ([4]f32{1.0, 0.8, 0.5, 0.25}) {
		r := radius_at(h, intensity, level)
		fmt.println("   radiance >=", level, " out to radius", r)
	}
	fmt.println()

	fmt.println("the same radius if the light were higher (intensity unchanged):")
	for hh in ([6]f32{0.4, 0.8, 1.2, 1.6, 2.4, 3.2}) {
		fmt.println(
			"   height", hh, " -> radius", radius_at(hh, intensity, 1.0),
			"   (this scene's height is", h, ")",
		)
	}
	fmt.println()

	// What the light's near plane does to the depth buffer's precision, given that the
	// nearest thing to the light is the floor directly below it.
	fmt.println("the near plane against the nearest surface the light can see:")
	near := f32(0.31331617)
	far := f32(3.1016674)
	fmt.println("   near", near, " but the floor is", h, "below the light")
	fmt.println("   so", (h - near) / h * 100.0, "percent of the depth range is spent on empty space")
	fmt.println("   and the useful range is", h, "..", far)
}
