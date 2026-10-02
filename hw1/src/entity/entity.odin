package entity

import "vendor:cgltf"
import gl "vendor:OpenGL"
import s3 "vendor:sdl3"
import "core:fmt"
import me "../memory/"
import sam "../scene/"
import "../paths"
import "core:strings"
import "core:math/linalg"
import "core:math"

Node :: sam.Node
Transform :: matrix[4,4]f32
MAX_ENTITY_COUNT :: 2000

Entity :: struct {
	using node : Node,
	node_id : u32,
}

entities : me.GenArray(MAX_ENTITY_COUNT, Entity)

marble_bust_entity : Entity
floor_entity : Entity

InitScene :: proc() {
	// A string literal lives in read-only data, so there is nothing to free here.
	// Deleting it corrupts the heap: measured on this machine as
	// 0xC0000374 STATUS_HEAP_CORRUPTION in a minimal repro, and elsewhere as an
	// intermittent segfault in unrelated code later on.
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

	// The floor is authored flat in its own XY plane at z = 0 with +Z up, which glTF
	// exports as a plane in XZ at y = 0, so the identity transform already places it
	// correctly: 3 m x 3 m centred on the origin, facing up. No rotation or scale is
	// needed, and adding one would only introduce a chance of getting the axes wrong.
	//
	// The bust's measured bounds put its base at y = -0.028, so it sinks 28 mm into
	// the floor. That is deliberate rather than overlooked: a base slightly below the
	// surface reads as resting on it, and lifting the model to sit exactly flush would
	// move it off the point the camera below is framed around.
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

	sam.Main_Camera.transform = linalg.matrix4_inverse(linalg.matrix4_look_at_f32(eye, target, up))
	sam.Main_Camera.fov_y = math.to_radians_f32(45)   // fov_y is radians, not degrees
	sam.Main_Camera.near = 0.1
	sam.Main_Camera.far = 1000

	// The directional light is the one that casts shadows, so it is also the key: a
	// shadow is only visible where the light producing it is the dominant
	// contribution. It sits front-right and high, at roughly 48 degrees of elevation,
	// which throws the bust's shadow back and to the left where the camera can see it.
	//
	// direction is the direction the light travels, which is why it is the negation
	// of the position-to-origin vector. Its position is what the shadow pass uses as
	// the eye of an orthographic camera; for a directional light the distance along
	// that direction does not change the shadow map's shape.
	//
	// Intensity has no attenuation term to divide by, so unlike the two point lights
	// below, this number is the radiance directly. 0.35 keeps the combined peak under
	// 1.0: with no tone mapping in the pipeline, anything above 1.0 is clamped flat
	// white by the 8-bit framebuffer.
	DIRECTIONAL_LIGHT :: 0
	FILL_LIGHT        :: 1
	RIM_LIGHT         :: 2

	sam.lights.kind[DIRECTIONAL_LIGHT]      = .Directional
	sam.lights.position[DIRECTIONAL_LIGHT]  = {2.0, 3.0, 2.0}
	sam.lights.direction[DIRECTIONAL_LIGHT] = {-0.496139, -0.744208, -0.496139}
	sam.lights.color[DIRECTIONAL_LIGHT]     = {1.0, 0.96, 0.90}
	sam.lights.intensity[DIRECTIONAL_LIGHT] = 2.

	
	sam.lights_count = 1
}

Update :: proc() { //This is just an empty function because we haven't planned to implement any game logic yet
	return
}
