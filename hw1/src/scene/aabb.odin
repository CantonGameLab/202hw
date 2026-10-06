package scene

import me "../memory"
import "core:math"
import "core:math/linalg"

AABB :: struct {
	minmax_offset_x : [2]f32,
	minmax_offset_y : [2]f32,
	minmax_offset_z : [2]f32,
}

GetSceneAABB :: proc(view_model : Transform) -> AABB {
	aabb : AABB = {
		minmax_offset_x = {max(f32), -max(f32)},
		minmax_offset_y = {max(f32), -max(f32)},
		minmax_offset_z = {max(f32), -max(f32)},
	}

	for i := u32(1); i <= nodes.next; i += 1 {
		if !nodes.in_use[i] do continue
		node := &nodes.data[i]
		mesh := me.RefGet(&meshes, node.mesh_id)
		if mesh == nil do continue
		for i in 0..<8 {
			p := [4]f32{
				mesh.aabb.minmax_offset_x[i & 1],
				mesh.aabb.minmax_offset_y[(i >> 1) & 1],
				mesh.aabb.minmax_offset_z[(i >> 2) & 1],
				1.,
			}
			world_position := linalg.mul(node.transform, p)
			view_position := linalg.mul(view_model, world_position)
	//		if !has_minmax_offset {
	//			aabb.minmax_offset_x[0] = view_position.x
	//			aabb.minmax_offset_x[1] = view_position.x
	//			aabb.minmax_offset_y[0] = view_position.y
	//			aabb.minmax_offset_y[1] = view_position.y
	//			aabb.minmax_offset_z[0] = view_position.z
	//			aabb.minmax_offset_z[1] = view_position.z
	//			continue
	//		}
			aabb.minmax_offset_x[0] = math.min(view_position.x, aabb.minmax_offset_x[0])
			aabb.minmax_offset_x[1] = math.max(view_position.x, aabb.minmax_offset_x[1])
			aabb.minmax_offset_y[0] = math.min(view_position.y, aabb.minmax_offset_y[0])
			aabb.minmax_offset_y[1] = math.max(view_position.y, aabb.minmax_offset_y[1])
			aabb.minmax_offset_z[0] = math.min(view_position.z, aabb.minmax_offset_z[0])
			aabb.minmax_offset_z[1] = math.max(view_position.z, aabb.minmax_offset_z[1])
		}
	}
	return aabb
}
