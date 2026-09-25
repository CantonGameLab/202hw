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
		if event.Poll() {
			break
		}
		render.Render()
	}
	return 
}
