package scene_and_models

import "vendor:cgltf"
import "core:fmt"
import gl "vendor:OpenGL"
import me "../memory/"

Scene :: struct {
	nodes : []Node,
}
