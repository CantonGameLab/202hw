package scene

import "core:math"
import "core:math/linalg"

Camera :: struct {
	transform : Transform,
	fov_y : f32,
	near : f32,
	far : f32,
}

Main_Camera : Camera

ViewMatrix :: proc(camera : ^Camera) -> matrix[4,4]f32 {
	return linalg.matrix4_inverse(camera.transform)
}

ProjMatrix :: proc(camera : ^Camera, aspect : f32) -> matrix[4,4]f32 {
	return linalg.matrix4_perspective_f32(camera.fov_y, aspect, camera.near, camera.far)
}
