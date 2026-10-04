package entity

import "vendor:cgltf"
import gl "vendor:OpenGL"
import s3 "vendor:sdl3"
import "core:fmt"
import me "../memory/"
import sam "../scene/"
import "../event/"
import "../paths/"
import "core:strings"
import "core:math/linalg"
import "core:math"

Scancode :: s3.Scancode
Node :: sam.Node
Transform :: matrix[4,4]f32
MAX_ENTITY_COUNT :: 2000
ZERO3 :: [3]f32{0., 0., 0.}


Entity :: struct {
	using node : Node,
	node_id : u32,
}

entities : me.GenArray(MAX_ENTITY_COUNT, Entity)

marble_bust_entity : Entity
floor_entity : Entity

CameraEntity :: struct {
	//parameters
	move_speed : f32,
	rotate_speed : f32,
	//states
	yaw : f32,
	pitch : f32,
	position : [3]f32,
}

main_camera_entity : CameraEntity

InitScene :: proc() {
	marble_bust_model_path := "resource/assets/marble_bust_model/marble_bust_01_4k.gltf"
	mesh_id_, ret := sam.LoadAGLTFToAMesh(marble_bust_model_path)
	if ret != .Success {
		fmt.eprintln("Something goes wrong guys!")
	}
	marble_bust_entity.mesh_id = mesh_id_
	marble_bust_entity.transform = 1
	me.RefRetain(&sam.meshes, mesh_id_)
	marble_bust_entity.node_id = me.ArrayAlloc(&sam.nodes)
	node := me.ArrayGet(&sam.nodes, marble_bust_entity.node_id)
	node^ = marble_bust_entity.node

	floor_model_path := "resource/assets/stone_floor/stone_floor.gltf"
	floor_mesh_id, floor_ret := sam.LoadAGLTFToAMesh(floor_model_path)
	if floor_ret != .Success {
		fmt.eprintln("[x] the floor asset failed to load:", floor_ret)
	}
	floor_entity.mesh_id = floor_mesh_id
	floor_entity.transform = 1
	me.RefRetain(&sam.meshes, floor_mesh_id)
	floor_entity.node_id = me.ArrayAlloc(&sam.nodes)
	floor_node := me.ArrayGet(&sam.nodes, floor_entity.node_id)
	floor_node^ = floor_entity.node

	target := linalg.Vector3f32{0.0, 0.23, 0.0}
	up := linalg.Vector3f32{0.0, 1.0, 0.0}
	eye := linalg.Vector3f32{0.0, 0.34, 1.05}

	sam.Main_Camera.fov_y = math.to_radians_f32(45)
	sam.Main_Camera.near = 0.1
	sam.Main_Camera.far = 1000

	main_camera_entity.move_speed = 0.5
	main_camera_entity.rotate_speed = 45
	main_camera_entity.position = eye

	forward_initial := linalg.vector_normalize(target - eye)
	main_camera_entity.yaw = math.atan2(forward_initial.x, -forward_initial.z)
	main_camera_entity.pitch = math.asin(clamp(forward_initial.y, -1.0, 1.0))

	sam.Main_Camera.transform = linalg.matrix4_inverse(
		linalg.matrix4_look_at_f32(main_camera_entity.position, target, up)
	)

	DIRECTIONAL_LIGHT :: 0
	FILL_LIGHT        :: 1
	RIM_LIGHT         :: 2

	sam.direction_lights.position[DIRECTIONAL_LIGHT]  = {2.0, 3.0, 2.0}
	sam.direction_lights.direction[DIRECTIONAL_LIGHT] = {-0.496139, -0.744208, -0.496139}
	sam.direction_lights.color[DIRECTIONAL_LIGHT]     = {1.0, 0.96, 0.90}
	sam.direction_lights.intensity[DIRECTIONAL_LIGHT] = 1.5

	sam.direction_light_count = 1

	POINT_LIGHT :: 0

	sam.point_lights.position[POINT_LIGHT]  = {0.7, 0.6, -0.7}
	sam.point_lights.color[POINT_LIGHT]     = {1.0, 0.95, 0.85}
	sam.point_lights.intensity[POINT_LIGHT] = 3.0

	sam.point_light_count = 1
}

Update :: proc(delta : f64) {
	using input := &event.Input_State
	using cam := &main_camera_entity

	delta_f32 := f32(delta)

	move_forward := f32(i32(key_down[Scancode.W])) - f32(i32(key_down[Scancode.S]))
	move_right := f32(i32(key_down[Scancode.D])) - f32(i32(key_down[Scancode.A]))
	move_local := [3]f32{move_right, 0., -move_forward}
	if move_local != ZERO3 {
		move_local = linalg.vector_normalize(move_local)
	}
	move_local *= move_speed * delta_f32

	rotate_up := f32(i32(key_down[Scancode.UP])) - f32(i32(key_down[Scancode.DOWN]))
	rotate_right := f32(i32(key_down[Scancode.RIGHT])) - f32(i32(key_down[Scancode.LEFT]))
	rotate_up *= math.to_radians_f32(rotate_speed) * delta_f32
	rotate_right *= math.to_radians_f32(rotate_speed) * delta_f32

	pitch += rotate_up
	pitch = math.min(math.max(pitch, math.to_radians_f32(-89.9)), math.to_radians_f32(89.9))
	yaw += rotate_right

	forward : [3]f32 = {
		math.cos(pitch) * math.sin(yaw),
		math.sin(pitch),
		-math.cos(pitch) * math.cos(yaw),
	}

	world := linalg.matrix4_inverse(
		linalg.matrix4_look_at_f32(position, position + forward, [3]f32{0., 1., 0.})
	)

	move_world := linalg.mul(world, [4]f32{move_local.x, move_local.y, move_local.z, 0.})
	position += {move_world.x, move_world.y, move_world.z}

	sam.Main_Camera.transform = world
}
