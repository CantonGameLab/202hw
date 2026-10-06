package probe

import "core:fmt"
import "core:math"
import s3 "vendor:sdl3"

import render "../../src/render"
import scene "../../src/scene"
import entity "../../src/entity"

// The irradiance the shader would compute on the floor, with the same expression it uses,
// so the region that clips to white in an 8-bit target can be seen without rendering.
//
// The shader does: n_dot_l = max(dot(N, L), 0) * 0.5 + 0.5, attenuation = 1 / d^2, and
// radiance = colour * intensity * attenuation * visibility. The floor's normal is +Y and
// the light is above it, so dot(N, L) is the cosine between straight up and the direction
// to the light.
main :: proc() {
	if !render.Init() {
		fmt.eprintln("init failed")
		return
	}
	render.InitShader()
	entity.InitScene()
	scene.PreComputation()

	world := scene.GetSceneAABB(1)
	floor_y := world.minmax_offset_y[0]

	for i in u32(0) ..< scene.point_light_count {
		lp := scene.point_lights[i].position
		intensity := scene.point_lights[i].intensity
		col := scene.point_lights[i].color
		fmt.println("light", i, "at", lp, " intensity =", intensity, " colour =", col)
		fmt.println("   irradiance is the shader's own expression, times AMBIENT = 0.11")
		fmt.println()

		// Walk out from directly under the light along +x, and report the shader's value.
		fmt.println("   along +x from directly under the light, floor albedo assumed 1:")
		fmt.println("      distance   horizontal   N.L term   attenuation   radiance   clipped")
		steps := 24
		under := [3]f32{lp.x, floor_y, lp.z}
		for k in 0 ..< steps {
			frac := f32(k) / f32(steps - 1) * 2.0
			px := under.x + frac * 1.5
			if px > 1.5 do continue
			to_light := [3]f32{lp.x - px, lp.y - floor_y, lp.z - under.z}
			dist := f32(math.sqrt(f64(to_light.x*to_light.x + to_light.y*to_light.y + to_light.z*to_light.z)))
			nl := to_light.y / dist
			n_dot_l := max(nl, 0.0) * 0.5 + 0.5
			attenuation := 1.0 / max(dist * dist, 1e-4)
			radiance := intensity * attenuation * n_dot_l
			fmt.println(
				"     ", dist, "  ", frac, "  ", n_dot_l, "  ", attenuation, "  ", radiance,
				radiance >= 1.0 ? "   CLIPPED" : "",
			)
		}
		fmt.println()

		// The same walk with the light raised, to show what the height does to the pool.
		fmt.println("   the horizontal radius at which the pool falls below 1.0:")
		for h in ([4]f32{0.4, 0.8, 1.6, 3.2}) {
			// Solve intensity * n_dot_l / d^2 = 1 for the horizontal offset, by bisection.
			lo_r: f32 = 0
			hi_r: f32 = 20
			for _ in 0 ..< 60 {
				mid := (lo_r + hi_r) * 0.5
				ty := lp.y - floor_y
				dx := mid
				dz: f32 = 0
				d := f32(math.sqrt(f64(dx*dx + ty*ty + dz*dz)))
				nl := ty / d
				v := intensity * (max(nl, 0.0) * 0.5 + 0.5) / (d * d)
				if v > 1.0 {
					lo_r = mid
				} else {
					hi_r = mid
				}
			}
			fmt.println("      light height", h, " -> radius", lo_r, " (this scene uses", lp.y - floor_y, ")")
		}
		fmt.println()
	}

	s3.Quit()
}
