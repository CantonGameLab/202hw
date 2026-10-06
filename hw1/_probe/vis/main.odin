package probe

import "core:fmt"
import "core:os"
import "core:strings"
import gl "vendor:OpenGL"
import s3 "vendor:sdl3"

import render "../../src/render"
import scene "../../src/scene"
import entity "../../src/entity"

// Filled from the window in main, because Render() sizes its targets from the window and
// a probe that disagrees with it draws into a mismatched framebuffer.
W: int
H: int

pixels: []u8

SaveBMP :: proc(path: string, p: []u8, w, h: int) {
	row_bytes := w * 3
	pad := (4 - (row_bytes % 4)) % 4
	image_size := (row_bytes + pad) * h
	file_size := 54 + image_size
	f, err := os.create(path)
	if err != nil {
		fmt.eprintln("cannot create", path, err)
		return
	}
	defer os.close(f)
	hdr: [54]u8
	hdr[0] = 'B'
	hdr[1] = 'M'
	put_u32 :: proc(dst: []u8, at: int, v: u32) {
		dst[at + 0] = u8(v & 0xff)
		dst[at + 1] = u8((v >> 8) & 0xff)
		dst[at + 2] = u8((v >> 16) & 0xff)
		dst[at + 3] = u8((v >> 24) & 0xff)
	}
	put_u32(hdr[:], 2, u32(file_size))
	put_u32(hdr[:], 10, 54)
	put_u32(hdr[:], 14, 40)
	put_u32(hdr[:], 18, u32(w))
	put_u32(hdr[:], 22, u32(h))
	hdr[26] = 1
	hdr[28] = 24
	put_u32(hdr[:], 34, u32(image_size))
	put_u32(hdr[:], 38, 2835)
	put_u32(hdr[:], 42, 2835)
	os.write(f, hdr[:])
	pad_bytes: [3]u8
	row := make([]u8, row_bytes)
	defer delete(row)
	for y in 0 ..< h {
		for x in 0 ..< w {
			src := (y*w + x) * 3
			row[x * 3 + 0] = p[src + 2]
			row[x * 3 + 1] = p[src + 1]
			row[x * 3 + 2] = p[src + 0]
		}
		os.write(f, row)
		if pad > 0 do os.write(f, pad_bytes[:pad])
	}
	fmt.println("wrote", path)
}

// Builds a copy of the shipping fragment shader whose final colour is the point light's
// visibility, so the light's own falloff and the shadow test can be told apart.
MakeVisibilityShader :: proc(src_path, out_path: string) -> bool {
	data, err := os.read_entire_file_from_path(src_path, context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", src_path, err)
		return false
	}
	defer delete(data)
	text := string(data)

	// A variable the point-light loop can write to and the end of main can read.
	text, _ = strings.replace_all(text, "	vec3 lit = vec3(0.0);", "	vec3 lit = vec3(0.0);\n	float probe_vis = 1.0;")
	text, _ = strings.replace_all(
		text,
		"		vec3 radiance = u_point_light_colors[i] * u_point_light_intensities[i] * attenuation * visibility;",
		"		probe_vis = visibility;\n		vec3 radiance = u_point_light_colors[i] * u_point_light_intensities[i] * attenuation * visibility;",
	)
	text, _ = strings.replace_all(text, "	FragColor = vec4(lit, base.a);", "	FragColor = vec4(vec3(probe_vis), 1.0);")

	// The first replacement is a declaration, so it has to be reported when it misses.
	if !strings.contains(text, "probe_vis = visibility;") {
		fmt.eprintln("the radiance line was not found; the shader's shape has changed")
		return false
	}
	if !strings.contains(text, "vec4(vec3(probe_vis), 1.0)") {
		fmt.eprintln("the FragColor line was not found; the shader's shape has changed")
		return false
	}
	write_err := os.write_entire_file(out_path, transmute([]u8)text)
	if write_err != nil {
		fmt.eprintln("cannot write", out_path, write_err)
		return false
	}
	fmt.println("wrote", out_path, len(text), "bytes")
	return true
}

// DrawWith draws one frame with the given program.
//
// The program is swapped only around the node draws. UniformShadowMapping sets the
// renderer's own program itself, and every location it uploads was looked up against that
// program, so pointing render.program.program at another one first makes those uploads
// land on locations belonging to a different program, which the driver rejects with
// GL_INVALID_OPERATION and which leaves the frame at the clear colour.
DrawWith :: proc(prog: u32, verbose: bool) {
	saved := render.program.program
	render.program.program = saved
	if verbose do for gl.GetError() != 0 {}
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	gl.Clear(gl.DEPTH_BUFFER_BIT | gl.COLOR_BUFFER_BIT)
	if verbose do fmt.println("      clear          =", gl.GetError())
	render.RasterizeShadowMap()
	if verbose do fmt.println("      rasterize      =", gl.GetError())
	render.UniformShadowMapping()
	if verbose do fmt.println("      uniforms       =", gl.GetError())

	render.program.program = prog
	UploadTo(prog)
	if verbose do fmt.println("      probe uploads  =", gl.GetError())
	render.MSAABind()
	if verbose do fmt.println("      msaa bind      =", gl.GetError())
	for i := u32(1); i <= scene.nodes.next; i += 1 {
		if !scene.nodes.in_use[i] do continue
		render.DrawPBRNode(i, u32(W), u32(H))
		if verbose do fmt.println("      draw node", i, "   =", gl.GetError())
	}
	render.MSAAResolve()
	if verbose do fmt.println("      msaa resolve   =", gl.GetError())
	render.BlitToFramebuffer(0, render.msaa.tex_resolved, i32(W), i32(H))
	if verbose do fmt.println("      blit           =", gl.GetError())
	render.program.program = saved
}

// UploadTo sets, on the given program, the shadow uniforms that UniformShadowMapping
// uploaded to the renderer's program. Uniform locations belong to one program each, so
// the renderer's uploads reach the renderer's program and nothing else: a probe program
// borrowing those locations gets none of them, every cube sampler stays on unit zero, and
// the light reaches nothing. DrawPBRNode supplies the rest (m_view, m_proj, m_model,
// m_normal, u_camera_transform and the material), so those are not repeated here.
UploadTo :: proc(prog: u32) {
	gl.UseProgram(prog)

	for i in 0 ..< int(scene.MAX_POINT_LIGHT_COUNT) {
		unit: i32 = 0
		flag: i32 = 0
		if i < int(scene.point_light_count) {
			unit = i32(render.SHADOW_MAP_UNIT_BASE + scene.direction_light_count) + i32(i)
			flag = 1
		}
		gl.Uniform1i(gl.GetUniformLocation(prog, fmt.ctprintf("u_point_light_shadow_maps[%d]", i)), unit)
		gl.Uniform1i(gl.GetUniformLocation(prog, fmt.ctprintf("u_point_light_has_shadow[%d]", i)), flag)
	}

	for i in u32(0) ..< scene.point_light_count {
		unit := render.SHADOW_MAP_UNIT_BASE + scene.direction_light_count + i
		gl.Uniform1f(gl.GetUniformLocation(prog, fmt.ctprintf("u_point_light_nears[%d]", i)), scene.point_lights[i].near)
		gl.Uniform1f(gl.GetUniformLocation(prog, fmt.ctprintf("u_point_light_fars[%d]", i)), scene.point_lights[i].far)
		gl.ActiveTexture(gl.TEXTURE0 + u32(unit))
		gl.BindTexture(gl.TEXTURE_CUBE_MAP, scene.point_lights[i].gl_shadow_map_texture)
	}

	gl.Uniform1i(gl.GetUniformLocation(prog, cstring("u_point_light_count")), i32(scene.point_light_count))
	gl.Uniform3fv(
		gl.GetUniformLocation(prog, cstring("u_point_light_positions")),
		i32(scene.point_light_count), transmute([^]f32)rawptr(&scene.point_lights.position[0]),
	)
	gl.Uniform3fv(
		gl.GetUniformLocation(prog, cstring("u_point_light_colors")),
		i32(scene.point_light_count), transmute([^]f32)rawptr(&scene.point_lights.color[0]),
	)
	gl.Uniform1fv(
		gl.GetUniformLocation(prog, cstring("u_point_light_intensities")),
		i32(scene.point_light_count), transmute([^]f32)rawptr(&scene.point_lights.intensity[0]),
	)

	// The directional block, which this scene leaves empty but the shader still reads.
	gl.Uniform1i(gl.GetUniformLocation(prog, cstring("u_light_count")), 0)
}

main :: proc() {
	if !render.Init() {
		fmt.eprintln("init failed")
		return
	}
	render.InitShader()
	entity.InitScene()
	scene.PreComputation()

	// The window's real size. Render() asks for this every frame and passes it to
	// DrawPBRNode, which uses it to size the MSAA resolve; a probe that hands over its own
	// idea of the size instead draws into a target whose dimensions disagree with the one
	// the pass chain sized, and DrawPBRNode answers GL_INVALID_OPERATION.
	w, h := render.GetWindowSize()
	fmt.println("window =", w, "x", h)
	W = int(w)
	H = int(h)
	pixels = make([]u8, W * H * 3)
	defer delete(pixels)

	for i in u32(0) ..< scene.point_light_count {
		fmt.println(
			"point light", i, " position =", scene.point_lights[i].position,
			" intensity =", scene.point_lights[i].intensity,
			" near =", scene.point_lights[i].near, " far =", scene.point_lights[i].far,
		)
	}
	for i in u32(0) ..< scene.direction_light_count {
		fmt.println("direction light", i, " intensity =", scene.direction_lights[i].intensity)
	}
	world := scene.GetSceneAABB(1)
	fmt.println(
		"scene box x", world.minmax_offset_x, " y", world.minmax_offset_y, " z", world.minmax_offset_z,
	)

	// The shipping shader first, so the cubes are created and filled.
	for _ in 0 ..< 3 {
		DrawWith(render.program.program, false)
		s3.GL_SwapWindow(render.window)
	}
	for gl.GetError() != 0 {}

	// The same shader with the point light's visibility as its output.
	src := "resource/shaders/no_light.frag"
	out := "resource/shaders/_probe_vis.frag"
	if !MakeVisibilityShader(src, out) {
		s3.Quit()
		return
	}

	// Control zero: the renderer's own program through the very same code path.
	for gl.GetError() != 0 {}
	DrawWith(render.program.program, true)

	vs := render.compileShader(gl.VERTEX_SHADER, "resource/shaders/no_light.vert")

	// A control first: a fragment shader that reads nothing at all. The scene's own vertex
	// shader and vertex arrays are used, so if this one draws, the geometry side is fine
	// and whatever fails later is a uniform or a sampler.
	ctrl_err := os.write_entire_file("resource/shaders/_probe_ctrl.frag", transmute([]u8)string(
		"#version 440 core\nout vec4 FragColor;\nvoid main() { FragColor = vec4(0.5, 0.25, 0.75, 1.0); }\n",
	))
	if ctrl_err != nil {
		fmt.eprintln("cannot write the control shader", ctrl_err)
		s3.Quit()
		return
	}
	fs_ctrl := render.compileShader(gl.FRAGMENT_SHADER, "resource/shaders/_probe_ctrl.frag")
	pc := render.linkProgram(vs, fs_ctrl)
	fmt.println("control program =", pc, " (0 = did not build)")
	if pc != 0 {
		for gl.GetError() != 0 {}
		DrawWith(pc, true)
		gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
		gl.ReadPixels(0, 0, i32(W), i32(H), gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
		mid := ((H/2)*W + W/2) * 3
		fmt.println("   control centre pixel =", pixels[mid], pixels[mid+1], pixels[mid+2])
	}

	fs := render.compileShader(gl.FRAGMENT_SHADER, out)
	p := render.linkProgram(vs, fs)
	fmt.println("visibility program =", p, " (0 = did not build)")
	if p == 0 {
		s3.Quit()
		return
	}

	for _ in 0 ..< 3 {
		DrawWith(p, false)
		s3.GL_SwapWindow(render.window)
	}

	for gl.GetError() != 0 {}
	DrawWith(p, true)
	fmt.println("gl error for the whole frame =", gl.GetError())

	gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
	gl.ReadPixels(0, 0, i32(W), i32(H), gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))
	SaveBMP("_probe\\vis.bmp", pixels, W, H)

	// How many pixels each verdict covers, and where the shadowed ones are.
	lit := 0
	shaded := 0
	partial := 0
	min_x, min_y, max_x, max_y := W, H, -1, -1
	for y in 0 ..< H {
		for x in 0 ..< W {
			i := (y*W + x) * 3
			v := pixels[i]
			switch {
			case v > 250:
				lit += 1
			case v < 5:
				shaded += 1
			case:
				partial += 1
				if x < min_x do min_x = x
				if x > max_x do max_x = x
				if y < min_y do min_y = y
				if y > max_y do max_y = y
			}
		}
	}
	fmt.println("lit =", lit, " shadowed =", shaded, " partial (PCF edge) =", partial)
	if max_x >= 0 {
		fmt.println("the partial band lies inside x", min_x, "..", max_x, " y", min_y, "..", max_y)
	}

	s3.Quit()
}
