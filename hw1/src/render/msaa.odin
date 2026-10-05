package render
import gl "vendor:OpenGL"
import s3 "vendor:sdl3"
import "core:c"
import "core:fmt"
import "core:os"

MSAA_SAMPLES :: 4

// One offscreen pass worth of attachments. The multisampled pair receives the
// geometry; the single-sample texture receives the resolve.
//
// Samples of a multisampled attachment are only reachable through
// glBlitFramebuffer: multisample storage has no sampler type, so the resolve is
// the only way to read it.
MSAA_Pass :: struct {
	// Multisampled: everything is drawn in here.
	multisample_fbo : u32,
	rbo_color : u32,
	rbo_depth : u32,
	// Single-sample: the resolved image, and the texture the shading pass samples.
	fbo_resolved : u32,
	tex_resolved : u32,
	width : i32,
	height : i32,
}

msaa : MSAA_Pass
blit_program : u32

initMSAA :: proc() {

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
}

// Makes the multisampled framebuffer the current draw target.
//
// Cost: one state change plus a clear of 4x the window's pixels.
// GPU relationship: setting the viewport is not optional. The viewport is
// independent of the framebuffer, so leaving it at the window size while drawing
// into a differently sized target silently scales the image.
MSAABind :: proc() {
	gl.BindFramebuffer(gl.FRAMEBUFFER, msaa.multisample_fbo)
	gl.Viewport(0, 0, msaa.width, msaa.height)
	gl.ClearColor(0.07, 0.09, 0.12, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
}

// Flattens the multisampled framebuffer into tex_resolved.
//
// Cost: one full-screen read, average and write -- at 1920x1080 this reads 4
// samples per pixel and writes one, so roughly 33 MB of traffic per frame.
// GPU relationship: glBlitFramebuffer is the only operation that can read
// multisampled storage. NEAREST is mandatory when the source is multisampled and
// the sample counts differ, which is exactly this case.
MSAAResolve :: proc() {
	gl.BindFramebuffer(gl.READ_FRAMEBUFFER, msaa.multisample_fbo)
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, msaa.fbo_resolved)
	gl.BlitFramebuffer(
		0, 0, msaa.width, msaa.height,
		0, 0, msaa.width, msaa.height,
		gl.COLOR_BUFFER_BIT,
		gl.NEAREST,
	)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

// Releases the offscreen target.
//
// Cost: two framebuffer deletes, three renderbuffer deletes and one texture
// delete, plus whatever the driver has to drain first.
// GPU relationship: deleting a bound framebuffer unbinds it, which is why
// framebuffer 0 is bound explicitly at the end.
MSAADeinit :: proc() {
	if msaa.rbo_color != 0 do gl.DeleteRenderbuffers(1, &msaa.rbo_color)
	if msaa.rbo_depth != 0 do gl.DeleteRenderbuffers(1, &msaa.rbo_depth)
	if msaa.tex_resolved != 0 do gl.DeleteTextures(1, &msaa.tex_resolved)
	if msaa.multisample_fbo != 0 do gl.DeleteFramebuffers(1, &msaa.multisample_fbo)
	if msaa.fbo_resolved != 0 do gl.DeleteFramebuffers(1, &msaa.fbo_resolved)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	msaa = {}
}

// Draws a whole offscreen image into a framebuffer, as one fullscreen triangle.
//
// Both ends of the pass are arguments rather than ambient state. Which framebuffer
// a draw call lands in is exactly the kind of thing that is invisible at the call
// site and expensive to debug when it is wrong, so neither the source texture nor
// the destination is inferred from whatever happened to be bound beforehand. A
// target of 0 means the window.
//
// Cost: one draw call covering the whole target, so 2.07 M fragment shader
// invocations at 1920x1080, plus one texture bind and a viewport change.
// GPU relationship: this is the last consumer of the pipeline in a frame. Its only
// input is a texture some earlier pass produced; its output goes to the target's
// colour attachment, which for the window is the back buffer that SwapWindow then
// presents.
BlitToFramebuffer :: proc(target_fbo, source_texture : u32, w, h : i32) {
	gl.BindFramebuffer(gl.FRAMEBUFFER, target_fbo)
	// The viewport follows the target, not the source. Leaving it at another
	// target's size silently scales the image, and no error is raised for it.
	gl.Viewport(0, 0, w, h)

	gl.UseProgram(blit_program)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, source_texture)

	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.CULL_FACE)
	gl.BindVertexArray(0)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
	gl.Enable(gl.CULL_FACE)
	gl.Enable(gl.DEPTH_TEST)
}
