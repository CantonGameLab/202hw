package render

import "core:fmt"
import s3 "vendor:sdl3"
import gl "vendor:OpenGL"
import "core:c"
import "core:os"
import "core:strings"
import "core:math/linalg"
import me "../memory/"
import sam "../scene/"

INIT_WINDOW_WIDTH :: 1920
INIT_WINDOW_HEIGHT :: 1080
INIT_WINDOW_TITLE :: "CERenderer"

window : ^s3.Window
gl_context : s3.GLContext

PBRProgram :: struct {
	vs : u32,
	fs : u32,
	program : u32,
	//locations
	m_proj : i32,
	m_view : i32,
	m_model : i32,
	m_normal : i32,
	u_base_color_factor : i32,
	u_base_color_texture : i32,
	u_has_base_color_texture : i32,
	u_light_count : i32,
	u_light_positions : i32,
	u_light_colors : i32,
	u_light_intensities : i32,
	u_camera_transform : i32,
	u_shininess : i32,
	u_specular_strength : i32,
}

program : PBRProgram

InitShader :: proc() {
	program.vs = compileShader(gl.VERTEX_SHADER, "resource/shaders/no_light.vert")
	program.fs = compileShader(gl.FRAGMENT_SHADER, "resource/shaders/no_light.frag")
	program.program = linkProgram(program.vs, program.fs)
	program.m_proj = gl.GetUniformLocation(program.program, cstring("m_proj"))
	program.m_view = gl.GetUniformLocation(program.program, cstring("m_view"))
	program.m_model = gl.GetUniformLocation(program.program, cstring("m_model"))
	program.m_normal = gl.GetUniformLocation(program.program, cstring("m_normal"))
	program.u_base_color_factor = gl.GetUniformLocation(program.program, cstring("u_base_color_factor"))
	program.u_base_color_texture = gl.GetUniformLocation(program.program, cstring("u_base_color_texture"))
	program.u_has_base_color_texture = gl.GetUniformLocation(program.program, cstring("u_has_base_color_texture"))
	program.u_light_count = gl.GetUniformLocation(program.program, cstring("u_light_count"))
	program.u_light_positions = gl.GetUniformLocation(program.program, cstring("u_light_positions"))
	program.u_light_colors = gl.GetUniformLocation(program.program, cstring("u_light_colors"))
	program.u_light_intensities = gl.GetUniformLocation(program.program, cstring("u_light_intensities"))
	program.u_camera_transform = gl.GetUniformLocation(program.program, cstring("u_camera_transform"))
	program.u_shininess = gl.GetUniformLocation(program.program, cstring("u_shininess"))
	program.u_specular_strength = gl.GetUniformLocation(program.program, cstring("u_specular_strength"))

	gl.UseProgram(program.program)
	gl.Uniform1i(program.u_base_color_texture, 0)
	gl.Uniform1f(program.u_shininess, 64.0)
	gl.Uniform1f(program.u_specular_strength, 0.35)

	// Builds both framebuffers at the given pixel size.
	//
	// Cost: two framebuffer objects, three renderbuffers, one texture, and the
	// multisampled storage itself. Called only on start and on resize, never per
	// frame.
	// GPU relationship: on return, framebuffer 0 is bound again, so the caller keeps
	// rendering to the window unless it explicitly binds this pass.
	// --- Multisampled target: colour and depth, both as renderbuffers -------
	// A texture would be useless here. Multisample storage cannot be bound to a
	// sampler, so the only consumer is the blit below, and renderbuffers are the
	// cheaper object for that.
	w, h := i32(INIT_WINDOW_WIDTH), i32(INIT_WINDOW_HEIGHT)
	
	gl.GenRenderbuffers(1, &msaa.rbo_color)
	gl.BindRenderbuffer(gl.RENDERBUFFER, msaa.rbo_color)
	gl.RenderbufferStorageMultisample(gl.RENDERBUFFER, MSAA_SAMPLES, gl.RGBA16F, w, h)

	gl.GenRenderbuffers(1, &msaa.rbo_depth)
	gl.BindRenderbuffer(gl.RENDERBUFFER, msaa.rbo_depth)
	// DEPTH_COMPONENT24 matches what the window already gives us, so switching
	// targets does not change depth precision.
	gl.RenderbufferStorageMultisample(gl.RENDERBUFFER, MSAA_SAMPLES, gl.DEPTH_COMPONENT24, w, h)

	gl.GenFramebuffers(1, &msaa.multisample_fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, msaa.multisample_fbo)
	gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, msaa.rbo_color)
	gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, msaa.rbo_depth) //framebuffer <- a renderbuffer or a texture. You can imagine framebuffer as a section of water pipe that can be connected to any pipe
	// Both attachments are multisampled with the same sample count, which is what
	// FRAMEBUFFER_INCOMPLETE_MULTISAMPLE checks for; mixing a 4x colour with a
	// single-sample depth is the classic way to fail it.
	if gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE {
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		return
	}

	// --- Single-sample target: a plain texture the shading pass can sample ----
	gl.GenTextures(1, &msaa.tex_resolved)
	gl.BindTexture(gl.TEXTURE_2D, msaa.tex_resolved)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.HALF_FLOAT, nil)
	// Linear rather than a mipmap filter: this image is already resolved and is only
	// ever magnified or minified uniformly, so there is no chain to walk. A mipmap
	// min filter here would definitely be wrong, because the texture has one level.
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

	gl.GenFramebuffers(1, &msaa.fbo_resolved)
	gl.BindFramebuffer(gl.FRAMEBUFFER, msaa.fbo_resolved)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, msaa.tex_resolved, 0)

	if gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE {
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		return
	}

	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	if !MSAAInit(i32(INIT_WINDOW_WIDTH), i32(INIT_WINDOW_HEIGHT)) {
		fmt.println("something goes wrong")
	}
	
	//fullscreen init
	vs := compileShader(gl.VERTEX_SHADER, "resource/shaders/fullscreen.vert")
	fs := compileShader(gl.FRAGMENT_SHADER, "resource/shaders/fullscreen.frag")
	blit_program = linkProgram(vs, fs)
	gl.UseProgram(blit_program)
	// Unit 0 is where the resolve result is bound.
	gl.Uniform1i(gl.GetUniformLocation(blit_program, cstring("u_screen_texture")), 0)
	gl.DeleteShader(vs)
	gl.DeleteShader(fs)
}

GetWindowSize :: proc() -> (w : u32, h : u32) {
	cw, ch : c.int
	s3.GetWindowSizeInPixels(window, &cw, &ch)
	w = u32(cw)
	h = u32(ch)
	return
}

Render :: proc() {
	w, h := GetWindowSize()

	// The window's own depth buffer is cleared here and nowhere else in the frame:
	// MSAABind clears the depth of the multisampled target instead. Without this
	// line the window's depth holds whatever the driver left in it at context
	// creation, and every pass that draws to the window with GL_DEPTH_TEST enabled
	// is then judged against undefined values. That is not hypothetical -- the
	// fullscreen display pass was silently discarded on every frame because of it,
	// and glGetError() reported zero throughout. The colour clear below is not
	// load-bearing: the display pass covers the whole window anyway.
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	gl.Clear(gl.DEPTH_BUFFER_BIT | gl.COLOR_BUFFER_BIT)

	MSAABind()
	for i := u32(1); i <= sam.nodes.next; i += 1 {
		if !sam.nodes.in_use[i] {
			continue
		}
		DrawPBRNode(i, w, h)
	}
	MSAAResolve()
	// The offscreen image goes to the window; the target is named explicitly rather
	// than left to whatever the resolve happened to leave bound.
	BlitToFramebuffer(0, msaa.tex_resolved, i32(w), i32(h))

	s3.GL_SwapWindow(window)
}

DrawPBRNode :: proc(id : u32, w, h : u32) {
	node := me.ArrayGet(&sam.nodes, id)
	if node == nil {
		return
	}
	transform := node.transform
	mesh := me.RefGet(&sam.meshes, node.mesh_id)
	if mesh == nil {
		return
	}

	aspect := f32(w) / f32(h)
	view_matrix := sam.ViewMatrix(&sam.Main_Camera)
	proj_matrix := sam.ProjMatrix(&sam.Main_Camera, aspect)
	gl.UseProgram(program.program)

	gl.UniformMatrix4fv(program.m_view, 1, false, &view_matrix[0,0])
	gl.UniformMatrix4fv(program.m_proj, 1, false, &proj_matrix[0,0])
	gl.UniformMatrix4fv(program.m_model, 1, false, &node.transform[0,0])

	m3 := linalg.matrix3_from_matrix4_f32(node.transform)
	normal_matrix := linalg.transpose(linalg.matrix3_inverse_f32(m3))
	gl.UniformMatrix3fv(program.m_normal, 1, false, &normal_matrix[0,0])
	gl.UniformMatrix4fv(program.u_camera_transform, 1, false, &sam.Main_Camera.transform[0,0])
	gl.Uniform1i(program.u_light_count, sam.lights_count)
	
	if sam.lights_count > 0 {
		n := sam.lights_count
		gl.Uniform3fv(program.u_light_positions,   n, transmute([^]f32)rawptr(&sam.lights.position))
		gl.Uniform3fv(program.u_light_colors,      n, transmute([^]f32)rawptr(&sam.lights.color))
		gl.Uniform1fv(program.u_light_intensities, n, transmute([^]f32)rawptr(&sam.lights.intensity))
	}

	setMaterialUniforms :: proc(mat : ^sam.Material) {
		has_tex : i32 = 0
		if mat.base_color_texture.texture_id != 0 {
			tex := me.RefGet(&sam.textures, mat.base_color_texture.texture_id)
			if tex != nil {
				has_tex = 1
				gl.ActiveTexture(gl.TEXTURE0)
				gl.BindTexture(gl.TEXTURE_2D, tex.gl_texture_id)
			}
		}
		gl.Uniform4fv(program.u_base_color_factor, 1, raw_data(&mat.base_color_factor))
		gl.Uniform1i(program.u_has_base_color_texture, has_tex)
	}

	for &p, index in mesh.primitives {
		mat := me.RefGet(&sam.materials, p.material_id)
		if mat == nil {
			continue
		}
		setMaterialUniforms(mat)

		// The VAO remembers the element buffer binding, so no BindBuffer here.
		gl.BindVertexArray(p.gl_vao_id)
		gl.DrawElements(gl.TRIANGLES, i32(p.indices_count), gl.UNSIGNED_INT, nil)
	}
}

linkProgram :: proc(vs : u32, fs : u32) -> (program : u32) {
	program = gl.CreateProgram()
	gl.AttachShader(program, vs)
	gl.AttachShader(program, fs)

	gl.LinkProgram(program)
	
	status : i32
	gl.GetProgramiv(program, gl.LINK_STATUS, &status)
	
	if status == 0 {
		buf : [2048]byte
		gl.GetProgramInfoLog(program, i32(len(buf)), nil, &buf[0])
		fmt.eprintln("link program error", string(buf[:]))
		gl.DeleteProgram(program)
		return 0
	}

	return program
}

compileShader :: proc(shader_kind : u32, path : string) -> u32 {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	defer delete(data)
	
	if err != nil {
		fmt.eprintln("so we met a big problem that we can't find your shader source file from a path!")
		return 0
	}
	src := strings.clone_to_cstring(string(data), context.allocator)
	defer delete(src)

	srcs := [?]cstring{src}

	shader := gl.CreateShader(shader_kind)
	gl.ShaderSource(shader, 1, raw_data(srcs[:]), nil)
	gl.CompileShader(shader)
	status : i32
	gl.GetShaderiv(shader, gl.COMPILE_STATUS, &status)
	if status == 0 {
		buf : [2048]byte
		gl.GetShaderInfoLog(shader, i32(len(buf)), nil, &buf[0])
		fmt.eprintln("the fucking shader CAN'T be converted by the GL compilor into a bunch of shit bytecode that can be executed by the GPU(maybe a erotic RTX5090 just like a stunner of G cup and smooth pussy). A JIT would have compiled the same shit at runtime, called it a feature, and blamed deoptimization when it ran slow. You don't even get that excuse.", string(buf[:]))
		gl.DeleteShader(shader)
		return 0
	}
	return shader
}


Init :: proc() -> bool {

	s3.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 4)
	s3.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 4)
	s3.GL_SetAttribute(.CONTEXT_PROFILE_MASK, c.int(s3.GLProfile{.CORE}))
	s3.GL_SetAttribute(.DOUBLEBUFFER, 1)
	s3.GL_SetAttribute(.MULTISAMPLEBUFFERS, 1)
	s3.GL_SetAttribute(.MULTISAMPLESAMPLES, 4)

	if !s3.Init({.VIDEO}) {
		fmt.eprintln("SDL3 init failed. Guess what? I won't serve you anymore! GO using other terminal emulator such as the WINDOW TERMINAL. This is who specially prepared for users like YOU.", s3.GetError())
		return false
	}

	window = s3.CreateWindow(
		INIT_WINDOW_TITLE,
		INIT_WINDOW_WIDTH,
		INIT_WINDOW_HEIGHT,
		s3.WINDOW_OPENGL | s3.WINDOW_RESIZABLE
	)

	if window == nil {
		fmt.eprintln("FAILED FAILED and FAILED. You can't just create A window! Congratulations!", s3.GetError())
		return false
	}

	gl_context = s3.GL_CreateContext(window)
	if gl_context == nil {
		fmt.eprintln("The Khronos say: You don's even deserve to have an available GL_Context.", s3.GetError())
		return false
	}

	if !s3.GL_MakeCurrent(window, gl_context) {
		fmt.eprintln("The Khronos say: Even if you have a GL_Context, you don't deserve to bind it.", s3.GetError())
		return false
	}

	gl.load_up_to(
		4,
		4,
		proc(p : rawptr, name : cstring) {
			(cast(^rawptr)p)^ = cast(rawptr)s3.GL_GetProcAddress(name)
		}
	)
	//set the vsync
	s3.GL_SetSwapInterval(0) 
	
	gl.Enable(gl.DEPTH_TEST)
	gl.Enable(gl.MULTISAMPLE)
	gl.Enable(gl.CULL_FACE)

	gl.DepthFunc(gl.LESS)
	gl.CullFace(gl.BACK)
	gl.FrontFace(gl.CCW)

	return true
}
