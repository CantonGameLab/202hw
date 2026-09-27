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

	sam.LoadaGLTF("resource/assets/marble_bust_model/marble_bust_01_4k.gltf")

	for {
	
		// Just a simpe s3 event module that copy from my another project

		if event.Poll() {
			break
		}
		
		render.Render()
	}
	return 
}
