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

	// Depth testing is turned off for this pass. The pass writes colour and nothing
	// else, so the test can only ever reject fragments it has no business judging --
	// and it does: with GL_DEPTH_TEST enabled the whole triangle is discarded and
	// the target keeps whatever it had. Measured, not assumed: the identical draw
	// call moves the centre pixel from the bust's (84,74,63) to the background's
	// (18,23,31) purely by enabling the depth test.
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.CULL_FACE)
	gl.BindVertexArray(0)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
	gl.Enable(gl.CULL_FACE)
	gl.Enable(gl.DEPTH_TEST)
}
