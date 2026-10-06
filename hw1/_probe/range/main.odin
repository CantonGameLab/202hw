package probe

import "core:fmt"
import "core:math"
import gl "vendor:OpenGL"
import s3 "vendor:sdl3"

import render "../../src/render"
import scene "../../src/scene"
import entity "../../src/entity"

// For every point on a grid over the floor: the direction from the light, which cube face
// that direction selects, whether it is inside that face's 45 degree half-angle, and
// whether its distance is inside near .. far. Anything outside one of those is a point the
// shadow map has no depth for.
main :: proc() {
	if !render.Init() {
		fmt.eprintln("init failed")
		return
	}
	render.InitShader()
	entity.InitScene()
	scene.PreComputation()

	world := scene.GetSceneAABB(1)
	lo := [3]f32{world.minmax_offset_x[0], world.minmax_offset_y[0], world.minmax_offset_z[0]}
	hi := [3]f32{world.minmax_offset_x[1], world.minmax_offset_y[1], world.minmax_offset_z[1]}

	for i in u32(0) ..< scene.point_light_count {
		lp := scene.point_lights[i].position
		zn := scene.point_lights[i].near
		zf := scene.point_lights[i].far
		fmt.println("light", i, "at", lp, " near =", zn, " far =", zf)
		fmt.println("   floor y =", lo.y, " so the light is", lp.y - lo.y, "above it")
		fmt.println("   the floor spans -1.5 .. 1.5 in x and z")
		fmt.println()

		steps := 41
		outside_cone := 0
		outside_range := 0
		min_angle: f32 = 0
		max_angle: f32 = 0
		min_dist: f32 = 1e9
		max_dist: f32 = 0
		total := 0
		for gz in 0 ..< steps {
			for gx in 0 ..< steps {
				x := -1.5 + 3.0 * f32(gx) / f32(steps - 1)
				z := -1.5 + 3.0 * f32(gz) / f32(steps - 1)
				d := [3]f32{x - lp.x, lo.y - lp.y, z - lp.z}
				dist := f32(math.sqrt(f64(d.x*d.x + d.y*d.y + d.z*d.z)))
				if dist < 1e-6 do continue
				n := [3]f32{d.x/dist, d.y/dist, d.z/dist}
				ax := abs(n.x); ay := abs(n.y); az := abs(n.z)
				best := max(ax, max(ay, az))
				angle := f32(math.acos(f64(best)) * 180.0 / math.PI)
				total += 1
				if angle > 45.0 do outside_cone += 1
				if dist < zn || dist > zf do outside_range += 1
				if gx == 0 && gz == 0 {
					min_angle = angle
					max_angle = angle
					min_dist = dist
					max_dist = dist
				} else {
					if angle < min_angle do min_angle = angle
					if angle > max_angle do max_angle = angle
					if dist < min_dist do min_dist = dist
					if dist > max_dist do max_dist = dist
				}
			}
		}
		fmt.println("   over", total, "floor points:")
		fmt.println("      angle from the nearest face axis:", min_angle, "..", max_angle, " degrees (45 is the limit)")
		fmt.println("      distance from the light:", min_dist, "..", max_dist, " (range is", zn, "..", zf, ")")
		fmt.println("      outside the 45 degree cone:", outside_cone)
		fmt.println("      outside the near..far range:", outside_range)
		fmt.println()
	}

	s3.Quit()
}
