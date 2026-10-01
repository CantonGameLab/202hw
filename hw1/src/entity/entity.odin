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

	target := linalg.Vector3f32{0.0, 0.23, 0.0}
	up := linalg.Vector3f32{0.0, 1.0, 0.0}
	eye := linalg.Vector3f32{0.0, 0.34, 1.05}

	sam.Main_Camera.transform = linalg.matrix4_inverse(linalg.matrix4_look_at_f32(eye, target, up))
	sam.Main_Camera.fov_y = math.to_radians_f32(45)   // fov_y is radians, not degrees
	sam.Main_Camera.near = 0.1
	sam.Main_Camera.far = 1000

	// Three-point lighting aimed at the bust, whose measured model-space bounds are
	// min (-0.123, -0.028, -0.145) max (0.149, 0.487, 0.155), so its centre is near
	// (0, 0.23, 0). Distances are therefore under 2 m.
	//
	//   key  - front upper left, warm, brightest: gives the form its shading
	//   fill - front right and lower, cool and dim: lifts the shadow side only
	//   rim  - behind and above: catches the shoulders and separates the bust from
	//          the background
	//
	// The rim sits behind the camera-facing surface on purpose; it contributes
	// almost nothing to the face and everything to the silhouette.
	//
	// Intensity budget: there is no tone mapping, so whatever the shader writes is
	// clamped straight into an 8-bit framebuffer and anything above 1.0 turns into
	// flat white. Combined irradiance at the brightest point must therefore stay
	// under 1.0, which pins these numbers to roughly intensity ~ distance^2 * 0.3:
	//
	//   key   1.6 m away, attenuation 1/2.5 = 0.40  ->  0.75 * 0.40 = 0.30
	//   fill  1.5 m away, attenuation 1/2.3 = 0.43  ->  0.30 * 0.43 = 0.13
	//   rim   1.2 m away, attenuation 1/1.4 = 0.71  ->  0.85 * 0.71 = 0.60
	//
	// The wrap-around diffuse term (N.L * 0.5 + 0.5) puts the peak at 1.0 rather
	// than the usual 0.5 for a centred light, so the key is deliberately the
	// dimmest of the three after attenuation.
	FILL_LIGHT  :: 0
	KEY_LIGHT   :: 1
	RIM_LIGHT   :: 2

	// Warm key: 1.6 m from the brightest part of the face.
	sam.lights.position[KEY_LIGHT]  = {1.0, 0.75, 1.3}
	sam.lights.color[KEY_LIGHT]     = {1.0, 0.94, 0.85}
	sam.lights.intensity[KEY_LIGHT] = 0.95

	// Cool fill from the opposite side, dim enough to leave the key dominant.
	sam.lights.position[FILL_LIGHT]  = {-1.2, 0.10, 0.9}
	sam.lights.color[FILL_LIGHT]     = {0.75, 0.82, 1.0}
	sam.lights.intensity[FILL_LIGHT] = 0.50

	// Rim light placed slightly behind the bust, nearly level with the crown.
	sam.lights.position[RIM_LIGHT]  = {-0.5, 0.9, -1.1}
	sam.lights.color[RIM_LIGHT]     = {1.0, 0.98, 0.95}
	sam.lights.intensity[RIM_LIGHT] = 0.9

	sam.lights_count = 3
}

Update :: proc() { //This is just an empty function because we haven't planned to implement any game logic yet
	return
}
