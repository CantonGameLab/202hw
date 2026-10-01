package scene

import "vendor:cgltf"
import "core:fmt"
import gl "vendor:OpenGL"
import me "../memory/"

LightKind :: enum {
	Point,
	Directional,
}

Light :: struct {
	kind : LightKind,
	position : [3]f32,
	direction : [3]f32,
	color : [3]f32,
	intensity : f32,
}

lights : #soa[MAX_LIGHT_COUNT]Light
lights_count : i32
