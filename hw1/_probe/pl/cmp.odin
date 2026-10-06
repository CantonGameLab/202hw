package pl

import "core:fmt"
import "core:math"
import gl "vendor:OpenGL"

import render "../../src/render"
import scene "../../src/scene"
import entity "../../src/entity"

// Both paths over the identical scene state: the project's own Render() and this harness's
// own upload plus the same fragment source with one number forced out of it. Whichever
// differs is where the picture comes from.
//
// RasterizeShadowMap runs again before the harness draw on purpose, so both paths start from
// a cube built at the same light position and the only variable left is the upload.
compare_paths :: proc(report : Reporter, frag_path, tag : string, h : f32, phase : f32) -> bool {
	entity.Update(1.0 / 60.0)
	a := phase * 2.0 * math.PI
	scene.point_lights.position[0] = {3.0 * math.cos(a), h, 3.0 * math.sin(a)}
	scene.point_lights.intensity[0] = 2.4
	scene.direction_lights.intensity[0] = 0.0
	scene.PreComputation()

	w, wh := render.GetWindowSize()

	render.Render()
	blit_resolved_to_window()
	proj := fmt.tprintf("_probe/pl/out/cmp_%s_proj.ppm", tag)
	write_ppm(proj, int(w), int(wh))

	fs_src, ok := read_owned_source(frag_path)
	if !ok do return false
	defer delete(fs_src)
	vs_src, vs_ok := read_owned_source("resource/shaders/no_light.vert")
	if !vs_ok do return false
	defer delete(vs_src)
	vs := compile_from(gl.VERTEX_SHADER, vs_src, fmt.tprintf("cmp_%s_v", tag))
	fs := compile_from(gl.FRAGMENT_SHADER, fs_src, fmt.tprintf("cmp_%s_f", tag))
	if vs == 0 || fs == 0 do return false
	prog := link_from(vs, fs, fmt.tprintf("cmp_%s", tag))
	if prog == 0 do return false

	render.RasterizeShadowMap()
	b := lookup_all(prog)
	upload_pbr_shadow(b, render.SHADOW_MAP_UNIT_BASE, .All_Entries, report)
	render.MSAABind()
	for i := u32(1); i <= scene.nodes.next; i += 1 {
		if !scene.nodes.in_use[i] do continue
		draw_one_node(prog, i, w, wh)
	}
	render.MSAAResolve()
	blit_resolved_to_window()
	harness := fmt.tprintf("_probe/pl/out/cmp_%s_harness.ppm", tag)
	write_ppm(harness, int(w), int(wh))

	rep_line(report, tag, " h", h, " phase", phase, " light", scene.point_lights.position[0],
		" near", scene.point_lights.camera[0].near, " far", scene.point_lights.camera[0].far)
	rep_line(report, "   project's Render ->", proj)
	rep_line(report, "   harness          ->", harness)
	gl.DeleteProgram(prog)
	gl.DeleteShader(vs)
	gl.DeleteShader(fs)
	return true
}

// The window is the only thing that can be read back here, so the resolved MSAA texture is
// blitted into framebuffer zero and read from there.
blit_resolved_to_window :: proc() {
	w, h := render.GetWindowSize()
	gl.BindFramebuffer(gl.READ_FRAMEBUFFER, render.msaa.fbo_resolved)
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
	gl.BlitFramebuffer(
		0, 0, render.msaa.width, render.msaa.height,
		0, 0, i32(w), i32(h), gl.COLOR_BUFFER_BIT, gl.NEAREST,
	)
	gl.BindFramebuffer(gl.READ_FRAMEBUFFER, 0)
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
}
