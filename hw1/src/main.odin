package main

import "core:fmt"
import s3 "vendor:sdl3"
import gl "vendor:OpenGL"
import "render/"

main :: proc() {
	render.Init()
	render.InitATriangle()

	for {
		render.Render()
	}
	return 
}
