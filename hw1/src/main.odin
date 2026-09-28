package main

import "core:fmt"
import s3 "vendor:sdl3"
import gl "vendor:OpenGL"
import "event/"
import "render/"
import sam "scene_and_models/"

main :: proc() {
	render.Init()
	render.InitATriangle()

	mesh_id, load_result := sam.LoadAGLTFToAMesh("resource/assets/marble_bust_model/marble_bust_01_4k.gltf")

	if load_result != .Success {
		fmt.eprintln("[x] failed to load the model, LoadResult =", load_result)
		return
	}

	// The loader returns the id WITHOUT a retain; the caller is the owner, so this is
	// where the single owning retain happens. Releasing it later is what cascades down
	// into the material and texture edges and eventually the GPU objects.
	if !sam.RetainMesh(mesh_id) {
		fmt.eprintln("[x] could not take ownership of the loaded mesh, id =", mesh_id)
		return
	}

	for {
	
		// Just a simpe s3 event module that copy from my another project

		if event.Poll() {
			break
		}
		
		render.Render()
	}
	return 
}
