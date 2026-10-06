package probe

import "core:fmt"
import "core:math"

// The two bias formulas, both reduced to metres, so they can be compared directly. A bias
// expressed in normalised depth converts to metres through the inverse of the depth curve.
//
//   depth(axis) = (z_far * z_near) / (axis * (z_far - z_near)) * (axis - z_near) / axis
//              = (1/axis - 1/z_near) / (1/z_far - 1/z_near)
main :: proc() {
	z_near: f32 = 0.31331617
	z_far: f32 = 3.1016674
	dd := z_far - z_near
	texels: f32 = 1024

	// The old formula: a world-space bias converted to depth.
	old_bias_depth :: proc(axis, z_near, z_far, dd, texels, n_dot_l: f32) -> f32 {
		texel_world := 2.0 * axis / texels
		slope := min((1.0 - n_dot_l) / max(n_dot_l, 1e-3), 4.0)
		bias_world := 2.0 * texel_world * (0.25 + slope)
		d_depth_d_axis := (z_far * z_near) / max(axis * dd, 1e-6)
		return bias_world * d_depth_d_axis
	}

	// The new formula: a margin in depth, sized from the face's own depth slope.
	new_bias_depth :: proc(axis, z_near, z_far, dd, texels, n_dot_l: f32) -> f32 {
		slope := min((1.0 - n_dot_l) / max(n_dot_l, 1e-3), 4.0)
		return 4.0 * (dd / (z_far * z_near)) * (0.25 + slope) * axis * axis
	}

	// Depth back to metres: invert the curve.
	depth_to_axis :: proc(d, z_near, z_far: f32) -> f32 {
		return 1.0 / ((d) * (1.0 / z_far - 1.0 / z_near) + 1.0 / z_near)
	}

	fmt.println("z_near", z_near, " z_far", z_far)
	fmt.println("the floor under the light is at axis", 0.82825935, " and the far corner at", 3.015)
	fmt.println()
	fmt.println("   axis    n_dot_l   old depth    old metres    new depth    new metres")

	for axis in ([5]f32{0.83, 1.0, 1.5, 2.0, 3.0}) {
		for ndl in ([2]f32{1.0, 0.5}) {
			ob := old_bias_depth(axis, z_near, z_far, dd, texels, ndl)
			nb := new_bias_depth(axis, z_near, z_far, dd, texels, ndl)
			base := (1.0/axis - 1.0/z_near) / (1.0/z_far - 1.0/z_near)
			om := depth_to_axis(base - ob, z_near, z_far)
			nm := depth_to_axis(base - nb, z_near, z_far)
			fmt.println(
				"  ", axis, "   ", ndl, "   ", ob, "   ", axis - om, "   ", nb, "   ", axis - nm,
			)
		}
	}
	fmt.println()
	fmt.println("(the metre columns are how far the receiver is pushed toward the light,")
	fmt.println(" so they are the depth error each formula is willing to forgive)")
}
