package main

import "core:fmt"
import s3 "vendor:sdl3"
import gl "vendor:OpenGL"
import "event/"
import "render/"
import "scene/"
import "entity/"

main :: proc() {
	render.Init()
	render.InitShader()
	entity.InitScene()

	for {
		if event.Poll() {
			break
		}
		
		render.Render()
	}
	return 
}
