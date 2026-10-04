package scene

import me "../memory/"
import "core:fmt"
import "core:math/linalg"
import gl "vendor:OpenGL"
import "vendor:cgltf"


Light_Ortho :: struct {
	half_extent: f32,
	z_near:      f32,
	z_far:       f32,
}

DirectionLight :: struct {
	position:              [3]f32,
	direction:             [3]f32,
	color:                 [3]f32,
	intensity:             f32,
	gl_shadow_map_texture: u32,
	gl_shadow_map_fbo:     u32,
}

PointLight :: struct {
	position:              [3]f32,
	color:                 [3]f32,
	intensity:             f32,
	gl_shadow_map_fbo:     u32,
	gl_shadow_map_texture: u32,
}

direction_lights: #soa[MAX_LIGHT_COUNT]DirectionLight
direction_light_count: u32
point_lights: #soa[MAX_LIGHT_COUNT]PointLight
point_light_count: u32


DirectionLightProjViewMat :: proc(
	light_pos: [3]f32,
	light_direction: [3]f32,
	light_up: [3]f32 = {},
) -> Transform {
	dir := linalg.normalize(light_direction)
	up := light_up
	if up == {} do up = abs(dir.y) > 0.99 ? [3]f32{0, 0, 1} : [3]f32{0, 1, 0}
	if abs(linalg.dot(dir, linalg.normalize(up))) > 0.999 do fmt.eprintln("[x] the light's up vector is parallel to its direction, so its look-at basis is degenerate; pass a different light_up")
	view := linalg.matrix4_look_at_f32(light_pos, light_pos + dir, up)

	s := GetSceneAABB(view)
	half_xy := max(
		max(abs(s.minmax_offset_x[0]), abs(s.minmax_offset_x[1])),
		max(abs(s.minmax_offset_y[0]), abs(s.minmax_offset_y[1])),
	)
	// far before near, deliberately. The light looks down its own -z, so points in the scene
	// carry negative light-space z; the larger that z is, the closer the point is to the light.
	// matrix_ortho3d_f32 maps near to the start of the depth range and far to its end, so
	// passing (min_z, max_z) hands it the farthest plane as "near" and inverts the entire
	// depth axis. Every shadow comparison then reads the map backwards: a surface standing on
	// the ground is judged to be behind the ground, and the map records the receiver instead
	// of the caster, which is visible as the floor's depth gradient running the wrong way.
	proj := linalg.matrix_ortho3d_f32(
		-half_xy,
		half_xy,
		-half_xy,
		half_xy,
		s.minmax_offset_z[1],
		s.minmax_offset_z[0],
		false,
	)
	return linalg.mul(proj, view)
}
