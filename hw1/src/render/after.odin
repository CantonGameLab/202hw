package render
import gl "vendor:OpenGL"
import s3 "vendor:sdl3"
import "core:c"
import "core:fmt"
import "core:os"

MSAA_SAMPLES :: 4

AfterPass :: struct {
	multisample_fbo : u32,
	rbo_color : u32,
	rbo_depth : u32,
	fbo_resolved : u32,

	tex_resolved : u32,
	width : i32,
	height : i32,
}

after : AfterPass
blit_program : u32

initAfter :: proc() {

	w, h := i32(INIT_WINDOW_WIDTH), i32(INIT_WINDOW_HEIGHT)

	after.width, after.height = w, h
	
	gl.GenRenderbuffers(1, &after.rbo_color)
	gl.BindRenderbuffer(gl.RENDERBUFFER, after.rbo_color)
	gl.RenderbufferStorageMultisample(gl.RENDERBUFFER, MSAA_SAMPLES, gl.RGBA16F, w, h)

	gl.GenRenderbuffers(1, &after.rbo_depth)
	gl.BindRenderbuffer(gl.RENDERBUFFER, after.rbo_depth)
	gl.RenderbufferStorageMultisample(gl.RENDERBUFFER, MSAA_SAMPLES, gl.DEPTH_COMPONENT24, w, h)

	gl.GenFramebuffers(1, &after.multisample_fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, after.multisample_fbo)

	gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, after.rbo_color)
	gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, after.rbo_depth)

	if gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE {
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		return
	}

	gl.GenTextures(1, &after.tex_resolved)
	gl.BindTexture(gl.TEXTURE_2D, after.tex_resolved)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.HALF_FLOAT, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

	gl.GenFramebuffers(1, &after.fbo_resolved)
	gl.BindFramebuffer(gl.FRAMEBUFFER, after.fbo_resolved)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, after.tex_resolved, 0)


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
}

bindAfter :: proc() {
	gl.BindFramebuffer(gl.FRAMEBUFFER, after.multisample_fbo)
	gl.Viewport(0, 0, after.width, after.height)

	gl.ClearColor(0.07, 0.09, 0.12, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
}

resolveAfter :: proc() {
	gl.BindFramebuffer(gl.READ_FRAMEBUFFER, after.multisample_fbo)
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, after.fbo_resolved)
	gl.BlitFramebuffer(
		0, 0, after.width, after.height,
		0, 0, after.width, after.height,
		gl.COLOR_BUFFER_BIT,
		gl.NEAREST,
	)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

BlitToFramebuffer :: proc(target_fbo, source_texture : u32, w, h : i32) {
	gl.BindFramebuffer(gl.FRAMEBUFFER, target_fbo)
	// The viewport follows the target, not the source. Leaving it at another
	// target's size silently scales the image, and no error is raised for it.
	gl.Viewport(0, 0, w, h)

	gl.UseProgram(blit_program)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, source_texture)
	gl.ActiveTexture(gl.TEXTURE1)
	gl.BindTexture(gl.TEXTURE_2D, bloom.a[0].tex)
	gl.ActiveTexture(gl.TEXTURE0)

	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.CULL_FACE)
	gl.BindVertexArray(0)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
	gl.Enable(gl.CULL_FACE)
	gl.Enable(gl.DEPTH_TEST)
}
