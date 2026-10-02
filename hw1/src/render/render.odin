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
	program.u_light_directions = gl.GetUniformLocation(program.program, cstring("u_light_directions"))
	program.u_camera_transform = gl.GetUniformLocation(program.program, cstring("u_camera_transform"))
	program.u_shininess = gl.GetUniformLocation(program.program, cstring("u_shininess"))
	program.u_specular_strength = gl.GetUniformLocation(program.program, cstring("u_specular_strength"))

	gl.UseProgram(program.program)
	gl.Uniform1i(program.u_base_color_texture, 0)
	gl.Uniform1f(program.u_shininess, 64.0)
	gl.Uniform1f(program.u_specular_strength, 0.35)

	//Init the multisapmle pass
	w, h := i32(INIT_WINDOW_WIDTH), i32(INIT_WINDOW_HEIGHT)

	msaa.width, msaa.height = w, h
	
	gl.GenRenderbuffers(1, &msaa.rbo_color)
	gl.BindRenderbuffer(gl.RENDERBUFFER, msaa.rbo_color)
	gl.RenderbufferStorageMultisample(gl.RENDERBUFFER, MSAA_SAMPLES, gl.RGBA16F, w, h)

	gl.GenRenderbuffers(1, &msaa.rbo_depth)
	gl.BindRenderbuffer(gl.RENDERBUFFER, msaa.rbo_depth)
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
	
	//Init the fullscreen pass
	vs := compileShader(gl.VERTEX_SHADER, "resource/shaders/fullscreen.vert")
	fs := compileShader(gl.FRAGMENT_SHADER, "resource/shaders/fullscreen.frag")
	blit_program = linkProgram(vs, fs)
	gl.UseProgram(blit_program)
	// Unit 0 is where the resolve result is bound.
	gl.Uniform1i(gl.GetUniformLocation(blit_program, cstring("u_screen_texture")), 0)
	gl.DeleteShader(vs)
	gl.DeleteShader(fs)

	//Init the simple and dumb shadow mapping
	vs = compileShader(gl.VERTEX_SHADER, "resource/shaders/shadow_mapping.vert")
	fs = compileShader(gl.FRAGMENT_SHADER, "resource/shaders/shadow_mapping.frag")
	shadow_mapping_program.program = linkProgram(vs, fs)
	shadow_mapping_program.u_light_mvp = gl.GetUniformLocation(shadow_mapping_program.program, cstring("u_light_mvp"))

	// The map's size. These were declared on the struct and never assigned, so they
	// stayed zero, and a zero-sized TexImage2D allocates no storage at all -- GL permits
	// the call and simply creates an empty texture. Attaching that to a framebuffer
	// gives FRAMEBUFFER_INCOMPLETE_ATTACHMENT, which is exactly the message this caused.
	//
	// 2048 square over a box of roughly 4.24 m puts one texel at about 2 mm, against a
	// bust half a metre tall. Halving it to 1024 would still be adequate and would cut
	// the storage per light from 12 MB to 3 MB.
	shadow_mapping_program.resolution_width = 2048
	shadow_mapping_program.resolution_height = 2048

	// The array uniforms are queried one element at a time rather than once for the
	// whole array. Element locations are not guaranteed to be contiguous -- measured on
	// this driver, [1] came back as 1 but [7] as 17 -- so a base location plus an offset
	// would silently write to the wrong uniform.
	//
	// These live in the PBR program, not the shadow program: no_light.frag is what
	// samples the map, so the lookups are made against program.program even though the
	// values are stored alongside the shadow pass that publishes them.
	for i in 0 ..< sam.MAX_LIGHT_COUNT {
		program.u_light_view_projs[i] = gl.GetUniformLocation(program.program, fmt.ctprintf("u_light_view_projs[%d]", i))
		program.u_light_shadow_maps[i] = gl.GetUniformLocation(program.program, fmt.ctprintf("u_light_shadow_maps[%d]", i))
	}
	program.u_light_has_shadow = gl.GetUniformLocation(program.program, cstring("u_light_has_shadow[0]"))
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

	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	gl.Clear(gl.DEPTH_BUFFER_BIT | gl.COLOR_BUFFER_BIT)

	//shadow mapping pass
	//
	// Only directional lights are rendered into. RasterizationShadowMap builds an
	// orthographic matrix from the light's position and direction, which is the shape a
	// directional light has; a point light emits in every direction and would need a cube
	// map, so running it here would produce a plausible-looking map covering the wrong
	// volume and consume a texture unit for nothing.
	//
	// The creation test is an OR: a light needs a map when either name is still missing.
	// With AND, a light holding one but not the other would never be repaired and would
	// draw into framebuffer zero, which is the window.
	for i := u32(0); i < sam.lights_count; i += 1 {
		if sam.lights.kind[i] != .Directional {
			continue
		}
		if sam.lights.gl_shadow_map_fbo[i] == 0 || sam.lights.gl_shadow_map_texture[i] == 0 {
			CreateShadowTexture(i)
		}
		RasterizationShadowMap(i)
	}

	UniformShadowMapping()
	MSAABind()
	for i := u32(1); i <= sam.nodes.next; i += 1 {
		if !sam.nodes.in_use[i] {
			continue
		}
		DrawPBRNode(i, w, h)
	}
	MSAAResolve()
	BlitToFramebuffer(0, msaa.tex_resolved, i32(w), i32(h))

	s3.GL_SwapWindow(window)
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
