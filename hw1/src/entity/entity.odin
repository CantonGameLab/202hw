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

MAX_ENTITY_COUNT	:: 2000
ZERO3				:: [3]f32{0., 0., 0.}


Entity :: struct {
	using node : Node,
	node_index : u32,
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

PointLightEntity :: struct {
	position : [3]f32,
	point_index : u32,
	node_index : u32,
	using node : Node,
}

point_light_entity : PointLightEntity

main_camera_entity : CameraEntity

global_time : f64

InitScene :: proc() {
	
	marble_bust_model_path := "resource/assets/marble_bust_model/marble_bust_01_4k.gltf"
	mesh_id_, ret := sam.LoadAGLTFToAMesh(marble_bust_model_path)
	marble_bust_entity.mesh_id = mesh_id_
	marble_bust_entity.transform = 1
	me.RefRetain(&sam.meshes, mesh_id_)
	marble_bust_entity.node_index = me.ArrayAlloc(&sam.nodes)
	node := me.ArrayGet(&sam.nodes, marble_bust_entity.node_index)
	node^ = marble_bust_entity.node

	floor_model_path := "resource/assets/stone_floor/stone_floor.gltf"
	floor_mesh_id, floor_ret := sam.LoadAGLTFToAMesh(floor_model_path)
	floor_entity.mesh_id = floor_mesh_id
	floor_entity.transform = 1
	me.RefRetain(&sam.meshes, floor_mesh_id)
	floor_entity.node_index = me.ArrayAlloc(&sam.nodes)
	floor_node := me.ArrayGet(&sam.nodes, floor_entity.node_index)
	floor_node^ = floor_entity.node

	target := linalg.Vector3f32{0.0, 0.23, 0.0}
	up := linalg.Vector3f32{0.0, 1.0, 0.0}
	eye := linalg.Vector3f32{0.0, 0.34, 1.05}

	sam.Main_Camera.fov_y = math.to_radians_f32(45)
	sam.Main_Camera.near = 0.1
	sam.Main_Camera.far = 1000

	main_camera_entity.move_speed = 0.5
	main_camera_entity.rotate_speed = 45.
	main_camera_entity.position = eye

	forward_initial := linalg.vector_normalize(target - eye)
	main_camera_entity.yaw = math.atan2(forward_initial.x, -forward_initial.z)
	main_camera_entity.pitch = math.asin(clamp(forward_initial.y, -1.0, 1.0))

	sam.Main_Camera.transform = linalg.matrix4_inverse(
		linalg.matrix4_look_at_f32(main_camera_entity.position, target, up)
	)


	sam.point_lights[0].color = {1.00, 0.93, 0.92}
	sam.point_lights[0].intensity = 1.4
	sam.point_lights[0].pcss_width = 0.05

	point_light_entity.point_index = 0

	light_ball_model_path := "resource/assets/light_ball/light_ball.gltf"
	light_ball_mesh_id, light_ball_ret := sam.LoadAGLTFToAMesh(light_ball_model_path)
	if light_ball_ret != .Success {
		fmt.eprintln("[x] the light ball asset failed to load:", light_ball_ret)
	}
	point_light_entity.mesh_id = light_ball_mesh_id
	point_light_entity.transform = linalg.matrix4_translate_f32(point_light_entity.position)
	me.RefRetain(&sam.meshes, light_ball_mesh_id)
	point_light_entity.node_index = me.ArrayAlloc(&sam.nodes)
	light_ball_node := me.ArrayGet(&sam.nodes, point_light_entity.node_index)
	light_ball_node^ = point_light_entity.node

	sam.point_lights[0].light_node_id = point_light_entity.node_index

	sam.point_light_count = 1
}

Update :: proc(delta : f64) {

	global_time += delta

	f32_delta := f32(delta)
	f32_global_time := f32(global_time)

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

	light_xz_length : f32 = math.sqrt(f32(2)) * 0.6
	light_rotate_speed : f32 = 0.1
	point_light_entity.position = [3]f32{math.cos(light_rotate_speed * f32_global_time) * light_xz_length, 0.9, math.sin(light_rotate_speed * f32_global_time) * light_xz_length}
	sam.point_lights[point_light_entity.point_index].position = point_light_entity.position
	point_light_entity.transform = linalg.matrix4_translate_f32(point_light_entity.position)
	light_ball_node := me.ArrayGet(&sam.nodes, point_light_entity.node_index)
	light_ball_node^ = point_light_entity.node
}
