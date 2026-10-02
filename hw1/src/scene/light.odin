package scene

import "vendor:cgltf"
import "core:fmt"
import gl "vendor:OpenGL"
import me "../memory/"
import "core:math/linalg"

LightKind :: enum {
	Point,
	Directional,
}

Light_Ortho :: struct {
	half_extent : f32,
	z_near : f32,
	z_far : f32,
}

Light :: struct {
	kind : LightKind,
	position : [3]f32,
	direction : [3]f32,
	color : [3]f32,
	intensity : f32,
	gl_shadow_map_texture : u32,
	gl_shadow_map_fbo : u32,
}

lights : #soa[MAX_LIGHT_COUNT]Light
lights_count : i32

LightProjViewMat :: proc(light_pos : [3]f32, light_direction : [3]f32, light_up : [3]f32 = {}) -> Transform {
	dir := linalg.normalize(light_direction)
	up := light_up
	if up == {} do up = abs(dir.y) > 0.99 ? [3]f32{0, 0, 1} : [3]f32{0, 1, 0}
	if abs(linalg.dot(dir, linalg.normalize(up))) > 0.999 do fmt.eprintln("[x] the light's up vector is parallel to its direction, so its look-at basis is degenerate; pass a different light_up")
	view := linalg.matrix4_look_at_f32(light_pos, light_pos + dir, up)

	s := GetSceneAABB(view)
	half_xy := max(max(abs(s.minmax_offset_x[0]), abs(s.minmax_offset_x[1])), max(abs(s.minmax_offset_y[0]), abs(s.minmax_offset_y[1])))

	proj := linalg.matrix_ortho3d_f32(
		-half_xy, half_xy,
		-half_xy, half_xy,
		s.minmax_offset_z[0], s.minmax_offset_z[1],
		false,
	)
	return linalg.mul(proj, view)
}
