package main

import "core:fmt"
import s3 "vendor:sdl3"
import gl "vendor:OpenGL"
import "event/"
import "render/"

main :: proc() {
	render.Init()
	render.InitATriangle()

	for {
	
		// Just a simpe s3 event module that copy from my another project

		if event.Poll() {
			break
		}
		
		render.Render()
	}
	return 
}
