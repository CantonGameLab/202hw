package render

import gl "vendor:OpenGL"
import "core:c"

BLOOM_LEVELS :: 3
BLOOM_RADIUS :: 6
BLOOM_STRENGTH :: 1.0

BloomLevel :: struct {
	tex : u32,
	fbo : u32,
	width : i32,
	height : i32,
}

BloomState :: struct {
	a : [BLOOM_LEVELS]BloomLevel,
	b : [BLOOM_LEVELS]BloomLevel,
	prefilter_program : u32,
	blur_program : u32,
	u_prefilter_source : i32,
	u_prefilter_texel : i32,
	u_prefilter_threshold : i32,
	u_blur_source : i32,
	u_blur_texel : i32,
	u_blur_direction : i32,
	u_blur_radius : i32,
	u_blur_stride : i32,
	threshold : f32,
	strength : f32,
}

bloom : BloomState

CreateBloomLevel :: proc(level : ^BloomLevel, w, h : i32) {
	level.width = w
	level.height = h

	gl.GenTextures(1, &level.tex)
	gl.BindTexture(gl.TEXTURE_2D, level.tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA16F, w, h, 0, gl.RGBA, gl.HALF_FLOAT, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)

	gl.GenFramebuffers(1, &level.fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, level.fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, level.tex, 0)
}

initBloom :: proc() {
	bloom.threshold = 1.0
	bloom.strength = BLOOM_STRENGTH

	vs := compileShader(gl.VERTEX_SHADER, "resource/shaders/fullscreen.vert")

	pfs := compileShader(gl.FRAGMENT_SHADER, "resource/shaders/bloom_prefilter.frag")
	bloom.prefilter_program = linkProgram(vs, pfs)
	bloom.u_prefilter_source = gl.GetUniformLocation(bloom.prefilter_program, cstring("u_source"))
	bloom.u_prefilter_texel = gl.GetUniformLocation(bloom.prefilter_program, cstring("u_texel"))
	bloom.u_prefilter_threshold = gl.GetUniformLocation(bloom.prefilter_program, cstring("u_threshold"))
	gl.UseProgram(bloom.prefilter_program)
	gl.Uniform1i(bloom.u_prefilter_source, 0)
	gl.DeleteShader(pfs)

	bfs := compileShader(gl.FRAGMENT_SHADER, "resource/shaders/bloom_blur.frag")
	bloom.blur_program = linkProgram(vs, bfs)
	bloom.u_blur_source = gl.GetUniformLocation(bloom.blur_program, cstring("u_source"))
	bloom.u_blur_texel = gl.GetUniformLocation(bloom.blur_program, cstring("u_texel"))
	bloom.u_blur_direction = gl.GetUniformLocation(bloom.blur_program, cstring("u_direction"))
	bloom.u_blur_radius = gl.GetUniformLocation(bloom.blur_program, cstring("u_radius"))
	bloom.u_blur_stride = gl.GetUniformLocation(bloom.blur_program, cstring("u_stride"))
	gl.UseProgram(bloom.blur_program)
	gl.Uniform1i(bloom.u_blur_source, 0)
	gl.DeleteShader(bfs)

	gl.DeleteShader(vs)

	w := after.width
	h := after.height
	for level in 0 ..< BLOOM_LEVELS {
		w = max(w / 2, 1)
		h = max(h / 2, 1)
		CreateBloomLevel(&bloom.a[level], w, h)
		CreateBloomLevel(&bloom.b[level], w, h)
	}

	gl.UseProgram(blit_program)
	gl.Uniform1i(gl.GetUniformLocation(blit_program, cstring("u_bloom_texture")), 1)
	gl.Uniform1f(gl.GetUniformLocation(blit_program, cstring("u_bloom_strength")), bloom.strength)
}

bloomBlur :: proc(
	target : BloomLevel,
	source : u32,
	source_w, source_h : i32,
	direction : [2]f32,
	radius : int,
	stride : f32,
	additive : bool,
) {
	gl.BindFramebuffer(gl.FRAMEBUFFER, target.fbo)
	gl.Viewport(0, 0, target.width, target.height)
	gl.UseProgram(bloom.blur_program)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, source)
	gl.Uniform2f(bloom.u_blur_texel, 1.0 / f32(source_w), 1.0 / f32(source_h))
	gl.Uniform2f(bloom.u_blur_direction, direction.x, direction.y)
	gl.Uniform1i(bloom.u_blur_radius, i32(radius))
	gl.Uniform1f(bloom.u_blur_stride, stride)
	if additive {
		gl.Enable(gl.BLEND)
		gl.BlendFunc(gl.ONE, gl.ONE)
	} else {
		gl.Disable(gl.BLEND)
	}
	gl.BindVertexArray(0)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
	gl.Disable(gl.BLEND)
}

resolveBloom :: proc() {
	gl.Disable(gl.DEPTH_TEST)
	gl.Disable(gl.CULL_FACE)

	gl.BindFramebuffer(gl.FRAMEBUFFER, bloom.a[0].fbo)
	gl.Viewport(0, 0, bloom.a[0].width, bloom.a[0].height)
	gl.UseProgram(bloom.prefilter_program)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, after.tex_resolved)
	gl.Uniform2f(bloom.u_prefilter_texel, 1.0 / f32(after.width), 1.0 / f32(after.height))
	gl.Uniform1f(bloom.u_prefilter_threshold, bloom.threshold)
	gl.BindVertexArray(0)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)

	bloomBlur(bloom.b[0], bloom.a[0].tex, bloom.a[0].width, bloom.a[0].height, {1, 0}, BLOOM_RADIUS, 1.0, false)
	bloomBlur(bloom.a[0], bloom.b[0].tex, bloom.b[0].width, bloom.b[0].height, {0, 1}, BLOOM_RADIUS, 1.0, false)

	for level in 1 ..< BLOOM_LEVELS {
		source := bloom.a[level - 1]
		bloomBlur(bloom.b[level], source.tex, source.width, source.height, {1, 0}, BLOOM_RADIUS, 2.0, false)
		bloomBlur(bloom.a[level], bloom.b[level].tex, bloom.b[level].width, bloom.b[level].height, {0, 1}, BLOOM_RADIUS, 1.0, false)
	}

	for level := BLOOM_LEVELS - 1; level > 0; level -= 1 {
		source := bloom.a[level]
		bloomBlur(bloom.a[level - 1], source.tex, source.width, source.height, {0, 1}, 0, 1.0, true)
	}

	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	gl.Enable(gl.CULL_FACE)
	gl.Enable(gl.DEPTH_TEST)
}
