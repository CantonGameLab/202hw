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
	initPBR()
	initMSAA()
	initShadowMapping()
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

	RasterizeShadowMap()
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
