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
	sam.direction_lights.intensity[DIRECTIONAL_LIGHT] = .0
	sam.direction_light_count = 1

	// Four point lights on a ring around the bust, one per quadrant of the ground
	// plane. What puts them at four angles rather than one is the shadow: each light
	// throws the bust's silhouette onto the floor along its own direction, so one
	// light can only ever show one shadow, and a second at the same angle would
	// redraw the first one rather than add to it.
	//
	// The radius and height are both set against the falloff. Irradiance goes as
	// 1 / d^2, so a light placed close to the floor drowns it while the same light
	// raised up reaches the bust with less to spare; the ring radius trades the two
	// against each other, and 0.8 m of height against 1.3 m of radius leaves every
	// lit surface inside about 1.4 m of its nearest light.
	//
	// The intensity is what keeps the sum under the 1.0 the 8-bit framebuffer can
	// hold, there being no tonemapping in the pipeline. The brightest point in the
	// frame -- the floor under the nearest light -- collects roughly 1.0 of the 0.7
	// from that light, 0.2 from each of the two beside it, and almost nothing from
	// the one opposite, and the directional light's 1.1 is what is left on top.
	POINT_LIGHT_RADIUS :: 1.3
	POINT_LIGHT_HEIGHT :: 0.8

	POINT_LIGHT_FRONT_RIGHT :: 0
	POINT_LIGHT_FRONT_LEFT  :: 1
	POINT_LIGHT_BACK_LEFT   :: 2
	POINT_LIGHT_BACK_RIGHT  :: 3

	sam.point_lights.position[POINT_LIGHT_FRONT_RIGHT] = { POINT_LIGHT_RADIUS, POINT_LIGHT_HEIGHT,  POINT_LIGHT_RADIUS}
	sam.point_lights.position[POINT_LIGHT_FRONT_LEFT]  = {-POINT_LIGHT_RADIUS, POINT_LIGHT_HEIGHT,  POINT_LIGHT_RADIUS}
	sam.point_lights.position[POINT_LIGHT_BACK_LEFT]   = {-POINT_LIGHT_RADIUS, POINT_LIGHT_HEIGHT, -POINT_LIGHT_RADIUS}
	sam.point_lights.position[POINT_LIGHT_BACK_RIGHT]  = { POINT_LIGHT_RADIUS, POINT_LIGHT_HEIGHT, -POINT_LIGHT_RADIUS}

	// One colour per light, all near white and none the same. A tint is what tells
	// the four shadows apart on the floor: with identical colours, an overlap reads
	// as a patch of shade, and only the separate edges say how many lights made it.
	sam.point_lights.color[POINT_LIGHT_FRONT_RIGHT] = {1.00, 0.93, 0.82}
	sam.point_lights.color[POINT_LIGHT_FRONT_LEFT]  = {0.82, 0.90, 1.00}
	sam.point_lights.color[POINT_LIGHT_BACK_LEFT]   = {0.90, 1.00, 0.88}
	sam.point_lights.color[POINT_LIGHT_BACK_RIGHT]  = {1.00, 0.86, 0.90}

	sam.point_lights.intensity[POINT_LIGHT_FRONT_RIGHT] = 0.
	sam.point_lights.intensity[POINT_LIGHT_FRONT_LEFT]  = 0.
	sam.point_lights.intensity[POINT_LIGHT_BACK_LEFT]   = 0.
	sam.point_lights.intensity[POINT_LIGHT_BACK_RIGHT]  = 10.

	sam.point_light_count = 4
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
