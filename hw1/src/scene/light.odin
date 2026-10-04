package scene

import me "../memory/"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import gl "vendor:OpenGL"
import "vendor:cgltf"

LightCamera :: struct {
	near : f32,
	far : f32,
	fov_y : f32,
	proj_view : Transform,
}

DirectionLight :: struct {
	position:              [3]f32,
	direction:             [3]f32,
	color:                 [3]f32,
	intensity:             f32,
	gl_shadow_map_texture: u32,
	gl_shadow_map_fbo:     u32,

	using camera : LightCamera,
	half_extent : f32,
}

PointLight :: struct {
	position:              [3]f32,
	color:                 [3]f32,
	intensity:             f32,
	gl_shadow_map_fbo:     u32,
	gl_shadow_map_texture: u32,

	using camera : LightCamera,
	proj_views : [6]Transform,
}

direction_lights: #soa[MAX_LIGHT_COUNT]DirectionLight
direction_light_count: u32
point_lights: #soa[MAX_LIGHT_COUNT]PointLight
point_light_count: u32

POINT_LIGHT_FACE_DIRECTIONS := [6][3]f32{
	{ 1, 0, 0},
	{-1, 0, 0},
	{ 0, 1, 0},
	{ 0,-1, 0},
	{ 0, 0, 1},
	{ 0, 0,-1},
}

POINT_LIGHT_FACE_UPS := [6][3]f32{
	{0,-1, 0},
	{0,-1, 0},
	{0, 0, 1},
	{0, 0,-1},
	{0,-1, 0},
	{0,-1, 0},
}

POINT_LIGHT_FACE_TEXTURE_TARGETS := [6]u32{
	gl.TEXTURE_CUBE_MAP_POSITIVE_X,
	gl.TEXTURE_CUBE_MAP_NEGATIVE_X,
	gl.TEXTURE_CUBE_MAP_POSITIVE_Y,
	gl.TEXTURE_CUBE_MAP_NEGATIVE_Y,
	gl.TEXTURE_CUBE_MAP_POSITIVE_Z,
	gl.TEXTURE_CUBE_MAP_NEGATIVE_Z,
}


DirectionLightProjViewMat :: proc(
	light_pos: [3]f32,
	light_direction: [3]f32,
	half_extent: f32,
	z_near: f32,
	z_far: f32,
	light_up: [3]f32 = {},
) -> Transform {
	dir := linalg.normalize(light_direction)
	up := light_up
	if up == {} do up = abs(dir.y) > 0.99 ? [3]f32{0, 0, 1} : [3]f32{0, 1, 0}
	if abs(linalg.dot(dir, linalg.normalize(up))) > 0.999 do fmt.eprintln("[x] the light's up vector is parallel to its direction, so its look-at basis is degenerate; pass a different light_up")
	view := linalg.matrix4_look_at_f32(light_pos, light_pos + dir, up)

	proj := linalg.matrix_ortho3d_f32(
		-half_extent,
		half_extent,
		-half_extent,
		half_extent,
		z_near,
		z_far,
		false,
	)
	return linalg.mul(proj, view)
}


PointLightProjViewMat :: proc(
	light_pos: [3]f32,
	face: int,
	z_near: f32,
	z_far: f32,
) -> Transform {
	dir := POINT_LIGHT_FACE_DIRECTIONS[face]
	up := POINT_LIGHT_FACE_UPS[face]
	view := linalg.matrix4_look_at_f32(light_pos, light_pos + dir, up)

	proj := linalg.matrix4_perspective_f32(math.PI * 0.5, 1, z_near, z_far)
	return linalg.mul(proj, view)
}


PointLightDepthRange :: proc(light_pos: [3]f32, world: AABB) -> (z_near, z_far: f32) {
	lo := [3]f32{world.minmax_offset_x[0], world.minmax_offset_y[0], world.minmax_offset_z[0]}
	hi := [3]f32{world.minmax_offset_x[1], world.minmax_offset_y[1], world.minmax_offset_z[1]}

	centre := (lo + hi) * 0.5
	half_diagonal := linalg.length(hi - lo) * 0.5

	z_near = 0.01
	z_far = 1
	if half_diagonal <= 0 || half_diagonal >= max(f32) {
		return
	}

	nearest := [3]f32{
		math.max(lo.x, math.min(light_pos.x, hi.x)),
		math.max(lo.y, math.min(light_pos.y, hi.y)),
		math.max(lo.z, math.min(light_pos.z, hi.z)),
	}

	z_near = math.max(linalg.length(light_pos - nearest), half_diagonal * 0.01)
	z_far = linalg.length(light_pos - centre) + half_diagonal
	return
}
