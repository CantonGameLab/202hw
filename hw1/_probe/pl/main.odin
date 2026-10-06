package pl

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "core:math"
import "core:math/linalg"
import gl "vendor:OpenGL"
import s3 "vendor:sdl3"

import render "../../src/render"
import scene "../../src/scene"
import entity "../../src/entity"

MAX_LIGHTS :: 20

// Every uniform location the shading pass needs, fetched from the program that actually
// runs the shading. The project fetches most of these from its shadow-mapping program
// instead, which is a different GL program object and therefore answers -1 to every name
// that only the shading program declares.
PBR_Bind :: struct {
	program : u32,
	light_view_projs : [MAX_LIGHTS]i32,
	light_shadow_maps : [MAX_LIGHTS]i32,
	light_has_shadow : i32,
	light_count : i32,
	point_shadow_maps : [MAX_LIGHTS]i32,
	point_nears : [MAX_LIGHTS]i32,
	point_fars : [MAX_LIGHTS]i32,
	point_has_shadow : i32,
	point_count : i32,
}

lookup_all :: proc(p : u32) -> PBR_Bind {
	b : PBR_Bind
	b.program = p
	for i in 0 ..< MAX_LIGHTS {
		b.light_view_projs[i] = gl.GetUniformLocation(p, fmt.ctprintf("u_light_view_projs[%d]", i))
		b.light_shadow_maps[i] = gl.GetUniformLocation(p, fmt.ctprintf("u_light_shadow_maps[%d]", i))
		b.point_shadow_maps[i] = gl.GetUniformLocation(p, fmt.ctprintf("u_point_light_shadow_maps[%d]", i))
		b.point_nears[i] = gl.GetUniformLocation(p, fmt.ctprintf("u_point_light_nears[%d]", i))
		b.point_fars[i] = gl.GetUniformLocation(p, fmt.ctprintf("u_point_light_fars[%d]", i))
	}
	b.light_has_shadow = gl.GetUniformLocation(p, cstring("u_light_has_shadow"))
	b.light_count = gl.GetUniformLocation(p, cstring("u_light_count"))
	b.point_has_shadow = gl.GetUniformLocation(p, cstring("u_point_light_has_shadow"))
	b.point_count = gl.GetUniformLocation(p, cstring("u_point_light_count"))
	return b
}

// The upload the project intends to perform, done against the shading program.
//
// The texture units repeat the project's own numbering: one unit for the material, then
// one per directional light, then one per point light. Units past the driver's
// GL_MAX_TEXTURE_IMAGE_UNITS do not exist, so the count is reported rather than assumed.
upload_pbr_shadow :: proc(b : PBR_Bind, shadow_unit_base : i32, units : Unit_Mode, report : Reporter) {
	gl.UseProgram(b.program)

	n_dir := i32(scene.direction_light_count)
	n_point := i32(scene.point_light_count)

	has_dir : [MAX_LIGHTS]i32
	for i in 0 ..< int(n_dir) {
		vp := scene.direction_lights[i].proj_view
		gl.UniformMatrix4fv(b.light_view_projs[i], 1, false, &vp[0, 0])
		tex := scene.direction_lights.gl_shadow_map_texture[i]
		if tex == 0 do continue
		unit := shadow_unit_base + i32(i)
		gl.ActiveTexture(gl.TEXTURE0 + u32(unit))
		gl.BindTexture(gl.TEXTURE_2D, tex)
		gl.Uniform1i(b.light_shadow_maps[i], unit)
		has_dir[i] = 1
	}
	gl.Uniform1iv(b.light_has_shadow, MAX_LIGHTS, &has_dir[0])
	gl.Uniform1i(b.light_count, n_dir)
	if n_dir > 0 {
		gl.Uniform3fv(
			gl.GetUniformLocation(b.program, cstring("u_light_positions")),
			n_dir, transmute([^]f32)rawptr(&scene.direction_lights.position),
		)
		gl.Uniform3fv(
			gl.GetUniformLocation(b.program, cstring("u_light_colors")),
			n_dir, transmute([^]f32)rawptr(&scene.direction_lights.color),
		)
		gl.Uniform1fv(
			gl.GetUniformLocation(b.program, cstring("u_light_intensities")),
			n_dir, transmute([^]f32)rawptr(&scene.direction_lights.intensity),
		)
		gl.Uniform3fv(
			gl.GetUniformLocation(b.program, cstring("u_light_directions")),
			n_dir, transmute([^]f32)rawptr(&scene.direction_lights.direction),
		)
	}

	has_point : [MAX_LIGHTS]i32
	last_cube_unit : i32 = -1
	for i in 0 ..< int(n_point) {
		gl.Uniform1f(b.point_nears[i], scene.point_lights[i].near)
		gl.Uniform1f(b.point_fars[i], scene.point_lights[i].far)
		tex := scene.point_lights[i].gl_shadow_map_texture
		if tex == 0 do continue
		unit := shadow_unit_base + n_dir + i32(i)
		gl.ActiveTexture(gl.TEXTURE0 + u32(unit))
		gl.BindTexture(gl.TEXTURE_CUBE_MAP, tex)
		gl.Uniform1i(b.point_shadow_maps[i], unit)
		has_point[i] = 1
		last_cube_unit = unit
	}

	// The experiments differ only here. A sampler array element that no upload writes holds
	// the unit number zero, and unit zero is where the material's base colour 2D texture is
	// bound, so a cube sampler left at its default names a unit with no cube on it.
	switch units {
	case .Only_Live:
	// Nothing to do: this is the project's own behaviour.
	case .All_Entries:
		if last_cube_unit >= 0 {
			for k in 0 ..< MAX_LIGHTS {
				gl.Uniform1i(b.point_shadow_maps[k], last_cube_unit)
			}
		}
	case .Rest_To_Last:
		if last_cube_unit >= 0 {
			for k in int(n_point) ..< MAX_LIGHTS {
				gl.Uniform1i(b.point_shadow_maps[k], last_cube_unit)
			}
		}
	}

	gl.Uniform1iv(b.point_has_shadow, MAX_LIGHTS, &has_point[0])
	gl.Uniform1i(b.point_count, n_point)
	if n_point > 0 {
		gl.Uniform3fv(
			gl.GetUniformLocation(b.program, cstring("u_point_light_positions")),
			n_point, transmute([^]f32)rawptr(&scene.point_lights.position),
		)
		gl.Uniform3fv(
			gl.GetUniformLocation(b.program, cstring("u_point_light_colors")),
			n_point, transmute([^]f32)rawptr(&scene.point_lights.color),
		)
		gl.Uniform1fv(
			gl.GetUniformLocation(b.program, cstring("u_point_light_intensities")),
			n_point, transmute([^]f32)rawptr(&scene.point_lights.intensity),
		)
	}

	rep_line(report, "  upload: dir lights", n_dir, " point lights", n_point,
		" units", shadow_unit_base, "..", shadow_unit_base + n_dir + n_point - 1)

	// The source side of the same upload, so a wrong value on screen can be traced to the
	// array it was read from rather than to the call that sent it.
	rep_line(report, "  scene point lights: count", scene.point_light_count,
		" intensities", scene.point_lights.intensity[0], scene.point_lights.intensity[1],
		scene.point_lights.intensity[2], scene.point_lights.intensity[3])
	rep_line(report, "  scene point light 3: pos", scene.point_lights.position[3],
		" colour", scene.point_lights.color[3],
		" near", scene.point_lights.camera[3].near, " far", scene.point_lights.camera[3].far)

	// The same values sent one scalar at a time, at the element locations, and read back.
	// The bulk calls and the element calls describe the same uniforms; if they disagree, the
	// disagreement is in how the bulk call addressed the array and not in the values.
	for k in 0 ..< 4 {
		loc := gl.GetUniformLocation(b.program, fmt.ctprintf("u_point_light_intensities[%d]", k))
		gl.Uniform1f(loc, scene.point_lights.intensity[k])
	}
	f4 : [20]f32
	gl.GetUniformfv(
		b.program,
		gl.GetUniformLocation(b.program, cstring("u_point_light_intensities")),
		&f4[0],
	)
	rep_line(report, "  after scalar upload, the array reads back as", f4[0], f4[1], f4[2], f4[3])

	one : [1]f32
	el := gl.GetUniformLocation(b.program, cstring("u_point_light_intensities[3]"))
	gl.GetUniformfv(b.program, el, &one[0])
	rep_line(report, "  element 3 alone: loc", el, "=", one[0])

	// A sampler uniform, read the same way, is the control: it is written by the same code
	// path with the same kind of call, and it demonstrably has an effect on the picture.
	si : [1]i32
	sl := gl.GetUniformLocation(b.program, cstring("u_point_light_shadow_maps[1]"))
	gl.GetUniformiv(b.program, sl, &si[0])
	rep_line(report, "  sampler for light 1: loc", sl, "=", si[0], " error now", err_name(flush_errors()))
}

// The draw the project performs, with the error sampled around each draw call rather than
// once per frame: a frame-level check cannot say which of the two loops raised it.
draw_all_nodes :: proc(report : Reporter, w, h : u32) -> (first_error : u32) {
	for i := u32(1); i <= scene.nodes.next; i += 1 {
		if !scene.nodes.in_use[i] do continue
		node := &scene.nodes.data[i]
		mesh := &scene.meshes.data[node.mesh_id]
		before := flush_errors()
		_ = before
		render.DrawPBRNode(i, w, h)
		e := flush_errors()
		if e != 0 && first_error == 0 {
			first_error = e
			rep_line(report, "  node", i, "mesh", node.mesh_id, "first GL error:", err_name(e))
		}
	}
	return
}

dump_limits :: proc(report : Reporter) {
	vals : [1]i32
	gl.GetIntegerv(gl.MAX_TEXTURE_IMAGE_UNITS, &vals[0])
	rep_line(report, "GL_MAX_TEXTURE_IMAGE_UNITS       =", vals[0])
	gl.GetIntegerv(gl.MAX_COMBINED_TEXTURE_IMAGE_UNITS, &vals[0])
	rep_line(report, "GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS =", vals[0])
	gl.GetIntegerv(gl.MAX_VERTEX_TEXTURE_IMAGE_UNITS, &vals[0])
	rep_line(report, "GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS =", vals[0])
	rep_line(report, "GL_VERSION  =", string(gl.GetString(gl.VERSION)))
	rep_line(report, "GL_RENDERER =", string(gl.GetString(gl.RENDERER)))
	rep_line(report, "GL_VENDOR   =", string(gl.GetString(gl.VENDOR)))
}

// The source is read from the tree each run and rewritten in memory for the experiments,
// so every variant differs from what is on disk by exactly the edit named next to it and
// nothing is left behind in the shader directory.
Variant :: struct {
	name : string,
	note : string,
	swap : bool,
	units : Unit_Mode,
	// Empty, or a GLSL expression to stand in for the point light's intensity.
	force_intensity : string,
}

// Which texture units the cube samplers are pointed at. The count of units a run binds is
// a variable of the experiment: the project binds one per point light and leaves the rest
// of the array at its default, and "the rest" is what these modes separate.
Unit_Mode :: enum {
	// Only the lights that exist get a unit; the remaining array entries keep the value
	// they were born with.
	Only_Live,
	// Every entry of the array is pointed at a unit holding a complete cube.
	All_Entries,
	// Entries the run does not need are pointed at the last live light's cube.
	Rest_To_Last,
}

VARIANTS := [?]Variant{
	{"00_disk", "the file as committed", false, .Only_Live, ""},
	{"01_live_units", "point block live, only live lights get a unit", true, .Only_Live, ""},
	{"02_all_units", "point block live, every array entry given a complete cube", true, .All_Entries, ""},
	{"03_rest_last", "point block live, spare entries given the last light's cube", true, .Rest_To_Last, ""},
	{"06_forced_intensity", "point block live, intensity forced to 3 in the shader", true, .All_Entries, "3.0"},
}

// Replaces the point light's intensity with a constant, leaving everything else alone.
// A light that contributes nothing can be doing so because its intensity never arrived or
// because the shading path itself is dead, and those two have different fixes.
force_point_intensity :: proc(src : string, value : string) -> (out : string, ok : bool) {
	marker := "u_point_light_intensities[i]"
	at := strings.index(src, marker)
	if at < 0 do return src, false
	replaced := strings.concatenate({value, " /* forced */"})
	return strings.concatenate({src[:at], replaced, src[at + len(marker):]}), true
}

// Swaps the point shadow's two bias constants for the caller's numbers, so the same frame can
// be drawn at several bias magnitudes without a second copy of the shader on disk.
//
// Both replacements happen in one pass, back to front. Splicing the first one first would
// shift every offset the second one is measured against.
force_bias_texels :: proc(src : string, texels : string, slope : string) -> (out : string, ok : bool) {
	a := strings.index(src, "POINT_BIAS_TEXELS = ")
	if a < 0 do return src, false
	b := strings.index(src, "POINT_SLOPE_CLAMP = ")
	if b < 0 do return src, false

	end_a := a + len("POINT_BIAS_TEXELS = ")
	end_b := b + len("POINT_SLOPE_CLAMP = ")
	value_end_a := strings.index(src[end_a:], ";") + end_a
	value_end_b := strings.index(src[end_b:], ";") + end_b
	if value_end_a <= end_a || value_end_b <= end_b do return src, false

	return strings.concatenate({
		src[:end_a], texels, src[value_end_a:end_b], slope, src[value_end_b:],
	}), true
}

// Drawn after the variants: the same frame with the shadow forced off, so the shadow can be
// isolated by subtraction rather than recognised by eye.
//
// It has to carry the same sampler bindings as the frame it is subtracted from. A control
// that only binds the live lights leaves the rest of the array naming unit zero, whose
// texture is the material's 2D base colour; those taps then read an incomplete cube, return
// zero, and the "no shadow" frame comes back fully shadowed -- identical to the frame it was
// meant to be compared against, and therefore silent.
NO_SHADOW :: Variant {
	"05_no_shadow",
	"every light's visibility forced to 1, so nothing is shadowed",
	true,
	.All_Entries,
	"",
}

// Turns the committed fragment shader's commented-out point-shadow block into live code.
//
// Out of the box the block is a comment, so `visibility` keeps its 1.0 and no point light
// can darken anything. Uncommenting is the smallest edit that gives the feature a chance:
// it changes nothing else about the loop.
//
// The `-to_light` argument the commented code passes is negated on the way in. A cube map
// is indexed by the direction from the light towards the fragment, and to_light points the
// other way, so leaving it would sample the face on the far side of the light.
uncomment_point_block :: proc(src : string) -> (out : string, ok : bool) {
	marker := "/*if (u_point_light_has_shadow[i] != 0) {"
	start := strings.index(src, marker)
	if start < 0 do return src, false
	end := strings.index(src[start:], "}*/")
	if end < 0 do return src, false
	end += start + 3

	body := src[start + 2:end - 2]
	replaced, _ := strings.replace_all(body, "-to_light", "to_light")

	return strings.concatenate({src[:start], replaced, src[end:]}), true
}

// Reads the cube map's stored depths and turns them back into a box in world space.
//
// The cube is the only record of what the shadow pass actually rasterized: a depth texel
// plus the direction the cube face maps to gives a point on the caster, so the set of all
// texels gives the caster's extent without asking the loader what it loaded. The distance
// used is the same one the shader compares against, so this measures the quantity under
// test rather than a proxy for it.
scene_from_cube :: proc(report : Reporter, light : int) -> (lo, hi : [3]f32) {
	size := int(render.shadow_mapping_program.point_light_resolution_width)
	zn := scene.point_lights[light].near
	zf := scene.point_lights[light].far
	lp := scene.point_lights[light].position
	tex := scene.point_lights[light].gl_shadow_map_texture

	lo = {max(f32), max(f32), max(f32)}
	hi = {-max(f32), -max(f32), -max(f32)}
	below_zero := 0
	over_one := 0
	counted := 0

	gl.BindTexture(gl.TEXTURE_CUBE_MAP, tex)
	for face in 0 ..< 6 {
		buf := make([]f32, size * size, context.allocator)
		defer delete(buf)
		gl.GetTexImage(scene.POINT_LIGHT_FACE_TEXTURE_TARGETS[face], 0, gl.DEPTH_COMPONENT, gl.FLOAT, raw_data(buf))

		for ty in 0 ..< size {
			for tx in 0 ..< size {
				stored := buf[ty * size + tx]
				if stored >= 0.9999 do continue
				if stored < 0.0 do below_zero += 1
				if stored > 1.0 do over_one += 1
				dist := point_depth_to_distance(stored, zn, zf)
				if dist <= 0 || dist > zf * 4 do continue
				u := (f32(tx) + 0.5) / f32(size) * 2.0 - 1.0
				v := (f32(ty) + 0.5) / f32(size) * 2.0 - 1.0
				dir := face_dir(face, u, v)
				p := [3]f32{lp.x + dir.x * dist, lp.y + dir.y * dist, lp.z + dir.z * dist}
				if p.x < lo.x do lo.x = p.x
				if p.y < lo.y do lo.y = p.y
				if p.z < lo.z do lo.z = p.z
				if p.x > hi.x do hi.x = p.x
				if p.y > hi.y do hi.y = p.y
				if p.z > hi.z do hi.z = p.z
				counted += 1
			}
		}
	}

	rep_line(report, "cube of light", light, "at", lp, " near", zn, " far", zf)
	rep_line(report, "  texels with a caster:", counted, " stored<0:", below_zero, " stored>1:", over_one)
	rep_line(report, "  caster extent x", lo.x, "..", hi.x)
	rep_line(report, "  caster extent y", lo.y, "..", hi.y)
	rep_line(report, "  caster extent z", lo.z, "..", hi.z)
	rep_line(report, "  caster box volume", (hi.x - lo.x) * (hi.y - lo.y) * (hi.z - lo.z))
	return
}

// The direction a cube texel names, in world axes, for the cube's own face convention.
// Mirrors the sampler's own mapping: the face is chosen by the largest component and the
// two others are divided by it.
face_dir :: proc(face : int, u, v : f32) -> [3]f32 {
	switch face {
	case 0: return linalg.normalize([3]f32{ 1.0, -v, -u})
	case 1: return linalg.normalize([3]f32{-1.0, -v,  u})
	case 2: return linalg.normalize([3]f32{   u, 1.0,  v})
	case 3: return linalg.normalize([3]f32{   u,-1.0, -v})
	case 4: return linalg.normalize([3]f32{   u, -v, 1.0})
	case 5: return linalg.normalize([3]f32{  -u, -v,-1.0})
	}
	return {0, 1, 0}
}

point_depth_to_distance :: proc(stored, z_near, z_far : f32) -> f32 {
	return (z_near * z_far) / (z_far - stored * (z_far - z_near))
}

// Writes all six faces of a light's cube to one file, verbatim, with the range they were
// rendered with. Nothing is interpreted here: the analysis that follows needs the stored
// numbers themselves, because the question is whether the caster is in them at all.
dump_cube_raw :: proc(path : string, light : int) {
	size := int(render.shadow_mapping_program.point_light_resolution_width)
	f, err := os.create(path)
	if err != nil {
		fmt.eprintln("[x] cannot create", path)
		return
	}
	defer os.close(f)

	header := fmt.tprintf(
		"PLCB %d %d %f %f %f %f %f\n",
		size, 6,
		scene.point_lights[light].position.x,
		scene.point_lights[light].position.y,
		scene.point_lights[light].position.z,
		scene.point_lights[light].near,
		scene.point_lights[light].far,
	)
	os.write(f, slice.to_bytes(transmute([]u8)header))

	gl.BindTexture(gl.TEXTURE_CUBE_MAP, scene.point_lights[light].gl_shadow_map_texture)
	buf := make([]f32, size * size, context.allocator)
	defer delete(buf)
	total := 0
	for face in 0 ..< 6 {
		gl.GetTexImage(scene.POINT_LIGHT_FACE_TEXTURE_TARGETS[face], 0, gl.DEPTH_COMPONENT, gl.FLOAT, raw_data(buf))
		total += write_all(f, slice.to_bytes(buf))
	}
	fmt.println("[dump_cube_raw] wrote", total, "bytes for 6 faces of", size * size * 4)
}

// Rasterizes one light's cube from a chosen subset of the scene's nodes.
//
// The pass itself draws every node, so "the caster is missing from the cube" and "the pass
// draws nothing" look the same from the outside. Rendering one node at a time says which
// of the two it is, and the subset is the only thing this differs from the project's pass
// in: same program, same matrices, same draw calls.
rasterize_cube_with :: proc(light : int, nodes : []u32) -> (texels_with_caster : int) {
	size := int(render.shadow_mapping_program.point_light_resolution_width)
	gl.BindFramebuffer(gl.FRAMEBUFFER, scene.point_lights[light].gl_shadow_map_fbo)
	gl.Viewport(0, 0, shadow_res(), shadow_res())
	gl.UseProgram(render.shadow_mapping_program.program)

	for face in 0 ..< 6 {
		gl.FramebufferTexture2D(
			gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT,
			scene.POINT_LIGHT_FACE_TEXTURE_TARGETS[face],
			scene.point_lights[light].gl_shadow_map_texture, 0,
		)
		gl.Clear(gl.DEPTH_BUFFER_BIT)
		lpv := scene.point_lights[light].proj_views[face]
		for id in nodes {
			if !scene.nodes.in_use[id] do continue
			node := &scene.nodes.data[id]
			mesh := &scene.meshes.data[node.mesh_id]
			mvp := linalg.mul(lpv, node.transform)
			gl.UniformMatrix4fv(
				render.shadow_mapping_program.u_light_mvp, 1, false, &mvp[0, 0],
			)
			for &p in mesh.primitives {
				gl.BindVertexArray(p.gl_vao_id)
				gl.DrawElements(gl.TRIANGLES, i32(p.indices_count), gl.UNSIGNED_INT, nil)
			}
		}
	}
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

	// Counted by reading the cube back, because the draw call itself reports nothing.
	buf := make([]f32, size * size, context.allocator)
	defer delete(buf)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, scene.point_lights[light].gl_shadow_map_texture)
	for face in 0 ..< 6 {
		gl.GetTexImage(scene.POINT_LIGHT_FACE_TEXTURE_TARGETS[face], 0, gl.DEPTH_COMPONENT, gl.FLOAT, raw_data(buf))
		for t in buf {
			if t < 0.9999 do texels_with_caster += 1
		}
	}
	return
}

shadow_res :: proc() -> i32 {
	return render.shadow_mapping_program.point_light_resolution_width
}

// Reads the cube at directions whose answers are known in advance.
//
// Every direction in a cube lookup is decided by the sampler's own conventions, and the
// shader that consumes the result has to agree with them. Pointing the cube at an axis --
// where the answer is the depth of whatever lies along that axis -- is the shortest way to
// tell agreement from a mismatch: the floor is 0.8 m below the light, so the -Y direction
// must come back holding the depth the floor was rendered with.
probe_cube_directions :: proc(report : Reporter, light : int) -> u32 {
	vs_src, ok := read_owned_source("_probe/pl/shaders/full.vert")
	if !ok do return 0
	defer delete(vs_src)
	fs_src, ok2 := read_owned_source("_probe/pl/shaders/showcube.frag")
	if !ok2 do return 0
	defer delete(fs_src)

	vs := compile_from(gl.VERTEX_SHADER, vs_src, "showcube_vertex")
	fs := compile_from(gl.FRAGMENT_SHADER, fs_src, "showcube_fragment")
	if vs == 0 || fs == 0 do return 0
	p := link_from(vs, fs, "showcube")
	if p == 0 do return 0
	defer gl.DeleteProgram(p)

	// An offscreen 8x8 target: these reads are point samples, so the size of the picture is
	// only there to give ReadPixels somewhere to read from.
	tex, fbo : u32
	make_output_target(&tex, &fbo)
	defer gl.DeleteFramebuffers(1, &fbo)
	defer gl.DeleteTextures(1, &tex)

	unit : i32 = 21
	gl.ActiveTexture(gl.TEXTURE0 + u32(unit))
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, scene.point_lights[light].gl_shadow_map_texture)

	gl.UseProgram(p)
	gl.Uniform1i(gl.GetUniformLocation(p, cstring("u_cube")), unit)

	vao : u32
	gl.GenVertexArrays(1, &vao)
	defer gl.DeleteVertexArrays(1, &vao)

	zn := scene.point_lights[light].near
	zf := scene.point_lights[light].far
	lp := scene.point_lights[light].position

	rep_line(report, "")
	rep_line(report, "cube sampled along axes, light at", lp, " near", zn, " far", zf)
	rep_line(report, "  direction        stored depth   as distance   expected distance   what is there")

	DIRS := [6][3]f32{
		{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1},
	}
	NAMES := [6]string{"+X", "-X", "+Y", "-Y", "+Z", "-Z"}
	for d, i in DIRS {
		gl.BindFramebuffer(gl.FRAMEBUFFER, fbo)
		gl.Viewport(0, 0, 8, 8)
		gl.ClearColor(0, 0, 0, 1)
		gl.Clear(gl.COLOR_BUFFER_BIT)
		gl.UseProgram(p)
		gl.Uniform3f(gl.GetUniformLocation(p, cstring("u_dir")), d.x, d.y, d.z)
		gl.BindVertexArray(vao)
		gl.DrawArrays(gl.TRIANGLES, 0, 3)
		gl.BindFramebuffer(gl.READ_FRAMEBUFFER, fbo)
		px : [4]u8
		gl.ReadPixels(4, 4, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, &px[0])
		stored := f32(px[0]) / 255.0

		// What the direction meets: the floor plane, or nothing.
		expected : f32 = -1
		what := "nothing (far)"
		if d.y < 0 {
			// Straight down from the light, the floor is directly below at the light's height.
			expected = lp.y - 0.0
			what = "floor"
		}
		rep_line(report, "  ", NAMES[i], "          ", stored, "     ",
			point_depth_to_distance(stored, zn, zf), "     ", expected, "     ", what)
	}
	gl.BindFramebuffer(gl.READ_FRAMEBUFFER, 0)
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
	return p
}

// Samples the cube along rays whose geometric answer is exact, and writes both numbers out.
//
// The comparison the shader makes only works if the value it reconstructs from a stored
// depth is the same quantity it measured on the receiver. Rather than infer which quantity
// the cube holds from shaded pixels, this reads the cube directly along rays that are
// easy to solve on paper and puts the two side by side.
sample_cube_rows :: proc(report : Reporter, light : int) {
	size := int(render.shadow_mapping_program.point_light_resolution_width)
	zn := scene.point_lights[light].near
	zf := scene.point_lights[light].far
	lp := scene.point_lights[light].position

	gl.BindTexture(gl.TEXTURE_CUBE_MAP, scene.point_lights[light].gl_shadow_map_texture)
	face_buf := make([]f32, size * size, context.allocator)
	defer delete(face_buf)

	f := os_create("_probe/pl/out/cube_rows.txt")
	if f == nil do return
	defer os.close(f)

	fmt.fprintln(f, "light", lp, " near", zn, " far", zf)
	fmt.fprintln(f, "face  dir_x   dir_y   dir_z   stored_depth  stored_as_dist  " +
		"euclid_to_floor  axis_to_floor  max_axis_comp  euclid_to_bust")

	// A grid over one face, in that face's own uv. Small offsets from the centre keep every
	// ray inside the floor's extent, so the solid the ray meets is known in advance.
	deltas := [7]f32{-0.45, -0.3, -0.15, 0.0, 0.15, 0.3, 0.45}
	FACES := [3]int{3, 5, 1}
	for face in FACES {
		gl.GetTexImage(scene.POINT_LIGHT_FACE_TEXTURE_TARGETS[face], 0, gl.DEPTH_COMPONENT, gl.FLOAT, raw_data(face_buf))
		for dv in deltas {
			for du in deltas {
				dir := face_dir(face, du, dv)
				// The texel this direction lands on, in that face's own grid.
				ua := abs(dir.x)
				ub := abs(dir.y)
				uc := abs(dir.z)
				u, v : f32
				switch face {
				case 0:
					u = -dir.z / ua
					v = -dir.y / ua
				case 1:
					u = dir.z / ua
					v = -dir.y / ua
				case 2:
					u = dir.x / ub
					v = dir.z / ub
				case 3:
					u = dir.x / ub
					v = -dir.z / ub
				case 4:
					u = dir.x / uc
					v = -dir.y / uc
				case 5:
					u = -dir.x / uc
					v = -dir.y / uc
				}
				tx := clamp(int((u * 0.5 + 0.5) * f32(size)), 0, size - 1)
				ty := clamp(int((v * 0.5 + 0.5) * f32(size)), 0, size - 1)
				stored := f64(face_buf[ty * size + tx])

				euclid_floor, axis_floor, euclid_bust := ray_scene(lp, dir)

				fmt.fprintf(
					f, "%d   %7.4f %7.4f %7.4f   %10.6f   %12.6f   %13.6f   %12.6f   %12.6f   %12.6f\n",
					face, dir.x, dir.y, dir.z, stored,
					f64(point_depth_to_distance(f32(stored), zn, zf)),
					euclid_floor, axis_floor,
					f64(max(abs(dir.x), max(abs(dir.y), abs(dir.z)))),
					euclid_bust,
				)
			}
		}
	}
}

// The distance from the light to the first solid a direction meets, measured both ways.
//
// The floor is the plane y = 0 inside its own extent, the caster is the box the loader
// reported. Only the floor is used as a reference because both sides of the shader's
// comparison must describe the same surface: a ray that meets the caster first would have
// its stored depth set by the caster, not the floor.
ray_scene :: proc(origin : [3]f32, dir : [3]f32) -> (euclid_floor, axis_floor, euclid_bust : f64) {
	euclid_floor = -1
	axis_floor = -1
	euclid_bust = -1

	if dir.y < 0 {
		t := f64(origin.y) / f64(-dir.y)
		p := [3]f32{origin.x + dir.x * f32(t), 0, origin.z + dir.z * f32(t)}
		if abs(p.x) <= 1.5 && abs(p.z) <= 1.5 {
			d := f64(dir.x) * t
			e := f64(dir.z) * t
			euclid_floor = math.sqrt(d * d + f64(origin.y) * f64(origin.y) + e * e)
			axis_floor = euclid_floor * f64(max(abs(dir.x), max(abs(dir.y), abs(dir.z))))
		}
	}

	lo := [3]f32{-0.12288019, -0.02825936, -0.14459643}
	hi := [3]f32{0.14886943, 0.48668385, 0.15511724}
	tmin : f64 = -1e30
	tmax : f64 = 1e30
	ok := true
	for axis in 0 ..< 3 {
		o := f64(origin[axis])
		d := f64(dir[axis])
		l := f64(lo[axis])
		h := f64(hi[axis])
		if abs(d) < 1e-12 {
			if o < l || o > h do ok = false
			continue
		}
		t0 := (l - o) / d
		t1 := (h - o) / d
		if t0 > t1 {
			t0, t1 = t1, t0
		}
		tmin = max(tmin, t0)
		tmax = min(tmax, t1)
	}
	if ok && tmax >= max(tmin, 0) {
		euclid_bust = max(tmin, 0)
	}
	return
}

os_create :: proc(path : string) -> ^os.File {
	f, err := os.create(path)
	if err != nil {
		fmt.eprintln("[x] cannot create", path)
		return nil
	}
	return f
}

// Runs one fragment shader over the whole window as a single fullscreen triangle, so a
// diagnostic can lay its own grid out in screen space and have the cells land big enough to
// read back. The project's shading program is untouched.
// The values the floor diagnostic needs, in one place. Odin's procedure literals do not
// close over the enclosing scope, so the diagnostic reads them from here.
Diag_Inputs :: struct {
	light : [3]f32,
	zn : f32,
	zf : f32,
	cube : u32,
	cells : i32,
	show : i32,
	scale : f32,
}

diag_inputs : Diag_Inputs

upload_diag_inputs :: proc(p : u32) {
	gl.ActiveTexture(gl.TEXTURE0 + 21)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, diag_inputs.cube)
	gl.Uniform1i(gl.GetUniformLocation(p, cstring("u_cube")), 21)
	gl.Uniform3f(gl.GetUniformLocation(p, cstring("u_light")),
		diag_inputs.light.x, diag_inputs.light.y, diag_inputs.light.z)
	gl.Uniform1f(gl.GetUniformLocation(p, cstring("u_near")), diag_inputs.zn)
	gl.Uniform1f(gl.GetUniformLocation(p, cstring("u_far")), diag_inputs.zf)
	gl.Uniform1i(gl.GetUniformLocation(p, cstring("u_cells")), diag_inputs.cells)
	gl.Uniform1i(gl.GetUniformLocation(p, cstring("u_show")), diag_inputs.show)
	gl.Uniform1f(gl.GetUniformLocation(p, cstring("u_bias_check")), 0.5)
}

upload_margin_inputs :: proc(p : u32) {
	gl.ActiveTexture(gl.TEXTURE0 + 21)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, diag_inputs.cube)
	gl.Uniform1i(gl.GetUniformLocation(p, cstring("u_cube")), 21)
	gl.Uniform3f(gl.GetUniformLocation(p, cstring("u_light")),
		diag_inputs.light.x, diag_inputs.light.y, diag_inputs.light.z)
	gl.Uniform1f(gl.GetUniformLocation(p, cstring("u_near")), diag_inputs.zn)
	gl.Uniform1f(gl.GetUniformLocation(p, cstring("u_far")), diag_inputs.zf)
	gl.Uniform1i(gl.GetUniformLocation(p, cstring("u_cells")), diag_inputs.cells)
	gl.Uniform1i(gl.GetUniformLocation(p, cstring("u_mode")), diag_inputs.show)
	gl.Uniform1f(gl.GetUniformLocation(p, cstring("u_scale")), diag_inputs.scale)
}

run_fullscreen_diag :: proc(report : Reporter, frag_path, tag : string, uniforms : proc(p : u32)) -> u32 {
	vs_src, ok := read_owned_source("_probe/pl/shaders/full.vert")
	if !ok do return 0
	defer delete(vs_src)
	fs_src, ok2 := read_owned_source(frag_path)
	if !ok2 do return 0
	defer delete(fs_src)

	vs := compile_from(gl.VERTEX_SHADER, vs_src, fmt.tprintf("%s_vertex", tag))
	fs := compile_from(gl.FRAGMENT_SHADER, fs_src, fmt.tprintf("%s_fragment", tag))
	if vs == 0 || fs == 0 do return 0
	p := link_from(vs, fs, tag)
	if p == 0 do return 0

	w, h := render.GetWindowSize()
	render.MSAABind()
	gl.UseProgram(p)
	uniforms(p)

	vao : u32
	gl.BindVertexArray(vao)
	gl.Disable(gl.CULL_FACE)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
	gl.Enable(gl.CULL_FACE)
	e := flush_errors()
	render.MSAAResolve()
	render.BlitToFramebuffer(0, render.msaa.tex_resolved, i32(w), i32(h))
	path := fmt.tprintf("_probe/pl/out/%s.ppm", tag)
	write_ppm(path, int(w), int(h))
	rep_line(report, "  diag", tag, "->", path, " error:", err_name(e))

	gl.DeleteProgram(p)
	gl.DeleteShader(vs)
	gl.DeleteShader(fs)
	return p
}

// Turns every shadow off, leaving everything else identical: same lights, same upload, same
// cube. The difference between a frame drawn with this and a frame drawn without it is the
// shadow and nothing else, which is the only way to see its shape without also looking at
// the material, the falloff and the ambient term.
force_no_shadow :: proc(src : string) -> (out : string, ok : bool) {
	marker := "float visibility = 1.0;"
	at := strings.index(src, marker)
	if at < 0 do return src, false
	// The point loop's own declaration, not the directional loop's: the directional one
	// comes first in the file and holds the same text.
	second := strings.index(src[at + 1:], marker)
	if second < 0 do return src, false
	second += at + 1
	replaced := fmt.tprintf("%s\n\t\tvisibility = 1.0; // forced", marker)
	return strings.concatenate({src[:second], replaced, src[second + len(marker):]}), true
}

// Writes every primitive's vertices and indices to one file.
//
// A box around a mesh is not the mesh: rays that cross the box may miss everything inside
// it, and a checker built on the box calls those hits. The shadow a model casts can only be
// answered by the model's own triangles, so they are exported rather than approximated.
dump_scene_geometry :: proc(path : string) {
	f := os_create(path)
	if f == nil do return
	defer os.close(f)

	header := "PLGEO 1\n"
	write_all(f, slice.to_bytes(transmute([]u8)header))

	for i := u32(1); i <= scene.nodes.next; i += 1 {
		if !scene.nodes.in_use[i] do continue
		node := &scene.nodes.data[i]
		mesh := &scene.meshes.data[node.mesh_id]
		line := fmt.tprintf("node %d mesh %d prims %d\n", i, node.mesh_id, len(mesh.primitives))
		write_all(f, slice.to_bytes(transmute([]u8)line))
		for &p in mesh.primitives {
			vh := fmt.tprintf("prim verts %d indices %d\n", len(p.vertexs), len(p.indices))
			write_all(f, slice.to_bytes(transmute([]u8)vh))
			write_all(f, slice.to_bytes(p.vertexs))
			write_all(f, slice.to_bytes(p.indices))
		}
	}
	fmt.println("[dump_scene_geometry] wrote", path)
}

// Reads each primitive's vertex buffer back off the GPU and writes the positions to a file.
//
// The loader frees the CPU-side copy once the buffer is up, so the only surviving record of
// the mesh is the buffer itself. The vertex count comes from the buffer's own byte size and
// the size of the Vertex type, which is how the loader sized it in the first place.
dump_gpu_positions :: proc(path : string) {
	f := os_create(path)
	if f == nil do return
	defer os.close(f)

	header := fmt.tprintf("PLPOS 1 %d\n", size_of(scene.Vertex))
	write_all(f, slice.to_bytes(transmute([]u8)header))

	for i := u32(1); i <= scene.nodes.next; i += 1 {
		if !scene.nodes.in_use[i] do continue
		node := &scene.nodes.data[i]
		mesh := &scene.meshes.data[node.mesh_id]
		for &p in mesh.primitives {
			byte_size : i32
			gl.BindBuffer(gl.ARRAY_BUFFER, p.gl_vbo_id)
			gl.GetBufferParameteriv(gl.ARRAY_BUFFER, gl.BUFFER_SIZE, &byte_size)
			vertex_count := int(byte_size) / size_of(scene.Vertex)
			line := fmt.tprintf("node %d mesh %d vbo %d bytes %d verts %d\n",
				i, node.mesh_id, p.gl_vbo_id, byte_size, vertex_count)
			write_all(f, slice.to_bytes(transmute([]u8)line))

			verts := make([]scene.Vertex, vertex_count, context.allocator)
			defer delete(verts)
			gl.GetBufferSubData(gl.ARRAY_BUFFER, 0, int(byte_size), raw_data(verts))
			write_all(f, slice.to_bytes(verts))
		}
	}
	gl.BindBuffer(gl.ARRAY_BUFFER, 0)
	fmt.println("[dump_gpu_positions] wrote", path)
}

// Reads back what the program actually holds for a uniform, from the driver rather than
// from the code that set it. A uniform the compiler dropped and a uniform that was never
// written both look like "no effect" in the picture; this tells them apart.
read_back_uniforms :: proc(report : Reporter, p : u32, tag : string) {
	gl.UseProgram(p)
	f60 : [60]f32
	f20 : [20]f32
	iv : [20]i32

	loc := gl.GetUniformLocation(p, cstring("u_point_light_positions"))
	gl.GetUniformfv(p, loc, &f60[0])
	rep_line(report, "  ", tag, "positions loc", loc, "=",
		f60[0], f60[1], f60[2], "|", f60[3], f60[4], f60[5])

	loc = gl.GetUniformLocation(p, cstring("u_point_light_intensities"))
	gl.GetUniformfv(p, loc, &f20[0])
	rep_line(report, "  ", tag, "intensities loc", loc, "=", f20[0], f20[1], f20[2], f20[3])

	loc = gl.GetUniformLocation(p, cstring("u_point_light_count"))
	gl.GetUniformiv(p, loc, &iv[0])
	rep_line(report, "  ", tag, "point_light_count loc", loc, "=", iv[0])

	loc = gl.GetUniformLocation(p, cstring("u_point_light_shadow_maps[0]"))
	gl.GetUniformiv(p, loc, &iv[0])
	rep_line(report, "  ", tag, "shadow_maps[0] loc", loc, "=", iv[0])

	loc = gl.GetUniformLocation(p, cstring("u_point_light_has_shadow"))
	gl.GetUniformiv(p, loc, &iv[0])
	rep_line(report, "  ", tag, "has_shadow loc", loc, "=", iv[0], iv[1], iv[2], iv[3])

	loc = gl.GetUniformLocation(p, cstring("u_light_count"))
	gl.GetUniformiv(p, loc, &iv[0])
	rep_line(report, "  ", tag, "light_count loc", loc, "=", iv[0])

	loc = gl.GetUniformLocation(p, cstring("u_camera_transform"))
	gl.GetUniformfv(p, loc, &f60[0])
	rep_line(report, "  ", tag, "camera_transform loc", loc, "=", f60[0], f60[1], f60[2])

	loc = gl.GetUniformLocation(p, cstring("u_shininess"))
	gl.GetUniformfv(p, loc, &f20[0])
	rep_line(report, "  ", tag, "shininess loc", loc, "=", f20[0])
}

// Forces the point light's visibility to a fixed value, in the same place the shadow block
// assigns it. Zero means every point-light contribution is switched off; one means every
// point-light contribution arrives undimmed. Those two frames bracket what the term can do,
// so if they are identical the term is not reaching the pixel at all -- whatever the shadow
// code computes.
force_visibility :: proc(src : string, value : string) -> (out : string, ok : bool) {
	marker := "float visibility = 1.0;"
	first := strings.index(src, marker)
	if first < 0 do return src, false
	second := strings.index(src[first + 1:], marker)
	if second < 0 do return src, false
	second += first + 1
	replaced := strings.concatenate({"float visibility = ", value, " /* forced */;"})
	return strings.concatenate({src[:second], replaced, src[second + len(marker):]}), true
}

// Replaces the point light's visibility with a literal in the radiance line.
//
// The line is written out in full rather than matched by a fragment, because a fragment that
// silently fails to match is indistinguishable from a measurement that came back negative.
probe_visibility_scale :: proc(src : string, value : string) -> (out : string, ok : bool) {
	marker := "vec3 radiance = u_point_light_colors[i] * u_point_light_intensities[i] * attenuation * visibility;"
	at := strings.index(src, marker)
	if at < 0 do return src, false
	replaced := fmt.tprintf(
		"vec3 radiance = u_point_light_colors[i] * u_point_light_intensities[i] * attenuation * (%s);",
		value,
	)
	return strings.concatenate({src[:at], replaced, src[at + len(marker):]}), true
}

// Swaps the lighting program the renderer holds for one compiled from another file.
//
// The renderer loads its fragment shader from one fixed path, so a variant has to be installed
// after the fact: compile it, point the record at it, and look the uniform locations up again,
// because a location belongs to a program object and the record was filled from the old one.
install_lighting_program :: proc(frag_path : string) -> bool {
	src, ok := read_owned_source(frag_path)
	if !ok do return false
	defer delete(src)
	vs_src, vs_ok := read_owned_source("resource/shaders/no_light.vert")
	if !vs_ok do return false
	defer delete(vs_src)

	vs := compile_from(gl.VERTEX_SHADER, vs_src, "fixed_vertex")
	fs := compile_from(gl.FRAGMENT_SHADER, src, "fixed_fragment")
	if vs == 0 || fs == 0 do return false
	p := link_from(vs, fs, "fixed")
	if p == 0 do return false

	render.program.program = p
	render.initShadowMapping()
	return true
}

// The project's own render path, end to end, with nothing overridden: its programs, its
// uploads, its draws. The only thing added is a read-back of the window before the swap.
//
// This is the check that matters for the repair: everything the probe repaired by hand is now
// supposed to happen inside render.UniformShadowMapping, so a frame drawn by render.Render
// has to show the shadows on its own.
// Moves the point lights and the camera, then draws with the project's own path.
//
// Used to answer "where did the shadow go" without editing the scene: the same renderer, the
// same shaders, only the light's position changed, so anything that appears or disappears is
// the change and not the harness.
relit_main :: proc(report : Reporter, light_pos : [3]f32, intensity : f32, camera_eye, camera_target : [3]f32, out_name : string) {
	for i in 0 ..< int(scene.point_light_count) {
		scene.point_lights.position[i] = light_pos
		scene.point_lights.intensity[i] = intensity
	}
	scene.Main_Camera.transform = linalg.matrix4_inverse(
		linalg.matrix4_look_at_f32(camera_eye, camera_target, [3]f32{0, 1, 0}),
	)

	for frame in 0 ..< 4 {
		_ = frame
		scene.PreComputation()
		render.Render()
		time.sleep(250 * time.Millisecond)
	}

	w, h := render.GetWindowSize()
	gl.BindFramebuffer(gl.READ_FRAMEBUFFER, render.msaa.fbo_resolved)
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
	gl.BlitFramebuffer(
		0, 0, render.msaa.width, render.msaa.height,
		0, 0, i32(w), i32(h), gl.COLOR_BUFFER_BIT, gl.NEAREST,
	)
	gl.BindFramebuffer(gl.READ_FRAMEBUFFER, 0)
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
	write_ppm(out_name, int(w), int(h))

	// What the scene says the light's range is now, so the picture can be read against it.
	near := scene.point_lights.camera[i32(0)].near
	far := scene.point_lights.camera[i32(0)].far
	rep_line(report, "wrote", out_name, " light", light_pos, " near", near, " far", far)
}

fixed_main :: proc(report : Reporter, out_name, lighting_path : string) {
	for frame in 0 ..< 4 {
		_ = frame
		scene.PreComputation()
		render.Render()
		time.sleep(250 * time.Millisecond)
	}

	// Render draws into the MSAA target and blits into the window, so the resolved texture is
	// what was just presented. It is blitted again into framebuffer 0 and read from there.
	w, h := render.GetWindowSize()
	gl.BindFramebuffer(gl.READ_FRAMEBUFFER, render.msaa.fbo_resolved)
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
	gl.BlitFramebuffer(
		0, 0, render.msaa.width, render.msaa.height,
		0, 0, i32(w), i32(h), gl.COLOR_BUFFER_BIT, gl.NEAREST,
	)
	gl.BindFramebuffer(gl.READ_FRAMEBUFFER, 0)
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
	write_ppm(out_name, int(w), int(h))
	rep_line(report, "wrote", out_name, "from the project's own Render() with", lighting_path)
}

probe_main :: proc(report : Reporter) {
	dump_limits(report)

	// The scene's own boxes, so a geometric check downstream measures the real meshes
	// rather than a guess at them. Both nodes carry the identity transform here.
	for i := u32(1); i <= scene.nodes.next; i += 1 {
		if !scene.nodes.in_use[i] do continue
		node := &scene.nodes.data[i]
		mesh := &scene.meshes.data[node.mesh_id]
		rep_line(report, "node", i, "mesh", node.mesh_id, "prims", len(mesh.primitives))
		rep_line(report, "   loader aabb x", mesh.aabb.minmax_offset_x,
			" y", mesh.aabb.minmax_offset_y, " z", mesh.aabb.minmax_offset_z)
	}

	// The cube, dumped before anything else touches GL state, so the file's size and
	// contents cannot depend on which pass ran last.
	{
		first_lit := -1
		for i in 0 ..< int(scene.point_light_count) {
			if scene.point_lights[i].intensity > 0 do first_lit = i
		}
		if first_lit >= 0 {
			render.RasterizeShadowMap()
			dump_cube_raw("_probe/pl/out/cube_raw.bin", first_lit)
			rep_line(report, "dumped the cube of light", first_lit, "to cube_raw.bin")
		}
		dump_scene_geometry("_probe/pl/out/geometry.bin")
		dump_gpu_positions("_probe/pl/out/positions.bin")
	}

	// Which node reaches the cube.
	{
		lit := -1
		for i in 0 ..< int(scene.point_light_count) {
			if scene.point_lights[i].intensity > 0 do lit = i
		}
		if lit >= 0 {
			all_ids := make([]u32, scene.nodes.next, context.allocator)
			defer delete(all_ids)
			for i in 1 ..= scene.nodes.next do all_ids[i - 1] = i

			rep_line(report, "")
			rep_line(report, "cube contents by node subset:")
			rep_line(report, "  every node      :", rasterize_cube_with(lit, all_ids), "texels with a caster")
			for id in all_ids {
				if !scene.nodes.in_use[id] do continue
				mesh := &scene.meshes.data[scene.nodes.data[id].mesh_id]
				one := []u32{id}
				rep_line(report, "  node", id, "alone  :", rasterize_cube_with(lit, one),
					"texels with a caster   (aabb y", mesh.aabb.minmax_offset_y, ")")
			}
			render.RasterizeShadowMap()
		}
	}

	pbr_p : u32 = render.program.program
	rep_line(report, "")
	rep_line(report, "the shading program object is", pbr_p)
	rep_line(report, "the record the project fills with locations:", "program.program =", pbr_p)
	rep_line(report, "shadow_mapping_program.program =", render.shadow_mapping_program.program,
		"(the shadow pass's own program, which declares none of these uniforms)")
	rep_line(report, "")
	rep_line(report, "locations as the project leaves them (fetched from shadow_mapping_program.program):")
	rep_line(report, "  u_light_view_projs[0]        =", render.program.u_light_view_projs[0])
	rep_line(report, "  u_light_shadow_maps[0]       =", render.program.u_light_shadow_maps[0])
	rep_line(report, "  u_point_light_shadow_maps[0] =", render.program.u_point_light_shadow_maps[0])
	rep_line(report, "  u_point_light_nears[0]       =", render.program.u_point_light_nears[0])
	rep_line(report, "  u_point_light_count          =", render.program.u_point_light_count)

	// What the real frame leaves behind, before anything is re-uploaded.
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	gl.ClearColor(0.07, 0.09, 0.12, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
	flush_errors()
	{
		w, h := render.GetWindowSize()
		render.RasterizeShadowMap()
		render.UniformShadowMapping()
		render.MSAABind()
		e := draw_all_nodes(report, w, h)
		render.MSAAResolve()
		render.BlitToFramebuffer(0, render.msaa.tex_resolved, i32(w), i32(h))
		rep_line(report, "")
		rep_line(report, "as the project stands, the shading draw returns:", err_name(e))
		write_ppm("_probe/pl/out/00_disk.ppm", int(w), int(h))
		s3.GL_SwapWindow(render.window)
	}

	// The state the project never uploads. u_point_light_has_shadow is written
	// unconditionally for the whole array, so a probe that forgets it would be testing
	// "no light casts a shadow" and reporting it as a shader fault.
	{
		e := flush_errors()
		_ = e
		render.RasterizeShadowMap()
		render.UniformShadowMapping()
		b := lookup_all(render.program.program)
		upload_pbr_shadow(b, render.SHADOW_MAP_UNIT_BASE, .Only_Live, report)
		w, h := render.GetWindowSize()
		render.MSAABind()
		e2 := draw_all_nodes(report, w, h)
		render.MSAAResolve()
		render.BlitToFramebuffer(0, render.msaa.tex_resolved, i32(w), i32(h))
		rep_line(report, "with the uniforms re-uploaded to the shading program, the draw returns:", err_name(e2))
		read_back_uniforms(report, render.program.program, "as-uploaded")
		write_ppm("_probe/pl/out/10_uploaded.ppm", int(w), int(h))
		s3.GL_SwapWindow(render.window)
	}

	// Sources on disk, recompiled here. The project's own programs are left alone: the
	// shadow pass keeps using its own, and only the shading draw below is switched.
	ALL_VARIANTS := [len(VARIANTS) + 1]Variant {
		VARIANTS[0], VARIANTS[1], VARIANTS[2], VARIANTS[3], VARIANTS[4], NO_SHADOW,
	}
	for v in ALL_VARIANTS {
		owned, ok := read_owned_source("resource/shaders/no_light.frag")
		if !ok do continue
		// The text is kept alive for the whole iteration: GLSL is compiled from a pointer
		// this loop hands to the driver.
		defer delete(owned)

		vs_src, vs_ok := read_owned_source("resource/shaders/no_light.vert")
		if !vs_ok do continue
		defer delete(vs_src)

		body := owned
		if v.swap {
			body, ok = uncomment_point_block(owned)
			if !ok {
				rep_line(report, "variant", v.name, "- MARKER NOT FOUND, skipped")
				continue
			}
		}
		if v.name == NO_SHADOW.name {
			body, ok = force_no_shadow(body)
			if !ok {
				rep_line(report, "variant", v.name, "- SHADOW MARKER NOT FOUND, skipped")
				continue
			}
		}
		if len(v.force_intensity) > 0 {
			body, ok = force_point_intensity(body, v.force_intensity)
			if !ok {
				rep_line(report, "variant", v.name, "- INTENSITY MARKER NOT FOUND, skipped")
				continue
			}
		}

		vs := compile_from(gl.VERTEX_SHADER, vs_src, fmt.tprintf("%s_vertex", v.name))
		fs := compile_from(gl.FRAGMENT_SHADER, body, fmt.tprintf("%s_fragment", v.name))
		if vs == 0 || fs == 0 do continue
		p := link_from(vs, fs, v.name)
		if p == 0 do continue

		rep_line(report, "")
		rep_line(report, "variant", v.name, "-", v.note)

		render.RasterizeShadowMap()
		render.UniformShadowMapping()
		b := lookup_all(p)
		upload_pbr_shadow(b, render.SHADOW_MAP_UNIT_BASE, v.units, report)

		w, h := render.GetWindowSize()
		render.MSAABind()
		gl.UseProgram(p)

		// One node at a time so the error can be attributed, then the whole frame drawn
		// the way the project draws it.
		draw_errors : [8]string
		n_err := 0
		for i := u32(1); i <= scene.nodes.next; i += 1 {
			if !scene.nodes.in_use[i] do continue
			flush_errors()
			draw_one_node(p, i, w, h)
			e := flush_errors()
			if e != 0 && n_err < len(draw_errors) {
				draw_errors[n_err] = fmt.tprintf("node %d -> %s", i, err_name(e))
				n_err += 1
			}
		}
		if n_err == 0 {
			rep_line(report, "  every node drew without a GL error")
		} else {
			for k in 0 ..< n_err do rep_line(report, "  draw error:", draw_errors[k])
		}

		render.MSAAResolve()
		render.BlitToFramebuffer(0, render.msaa.tex_resolved, i32(w), i32(h))
		path := fmt.tprintf("_probe/pl/out/%s.ppm", v.name)
		write_ppm(path, int(w), int(h))
		rep_line(report, "  wrote", path)
		s3.GL_SwapWindow(render.window)
		gl.DeleteProgram(p)
		gl.DeleteShader(vs)
		gl.DeleteShader(fs)
	}

	// The point light's shadow, switched by a uniform: 1 draws it as the shader computes it,
	// 0 removes the point light's contribution entirely, and 2 amplifies it so the term is
	// unmistakable. Three frames from one shader, differing in one float.
	SCALES := [3]f32{1.0, 0.0, 2.0}
	for s in SCALES {
		real_onto_current_target(report, "resource/shaders/no_light.frag", s)
	}

	// The cube's own contents, read back and turned into world space.
	lit := -1
	for i in 0 ..< int(scene.point_light_count) {
		if scene.point_lights[i].intensity > 0 do lit = i
	}
	if lit < 0 {
		rep_line(report, "")
		rep_line(report, "no point light has an intensity, so there is nothing to probe")
		return
	}
	rep_line(report, "")
	scene_from_cube(report, lit)
	probe_cube_directions(report, lit)
	sample_cube_rows(report, lit)

	// What the two sides of the shader's comparison actually are, cell by cell.
	//
	// u_show 0 draws the ratio of the cube's stored distance to the fragment's own axis
	// distance: half grey means the cube holds exactly this point. 1, 2 and 3 draw the
	// stored distance, the fragment's axis distance and the fragment's straight-line
	// distance, all on the same 0..4 m scale, so the three can be read against each other.
	// The margin the comparison actually has, drawn on a grid.
	//
	// The shaded colour cannot say whether a lit floor is lit with a hair to spare or by a
	// wide margin, and that difference is the whole question for a self-shadowing surface.
	// Mode 0 draws stored minus receiver in depth units, mode 1 the same in metres; half grey
	// is an exact tie and darker is occluded.
	for mode in 0 ..< 3 {
		diag_inputs = {
			light = scene.point_lights[lit].position,
			zn = scene.point_lights[lit].near,
			zf = scene.point_lights[lit].far,
			cube = scene.point_lights[lit].gl_shadow_map_texture,
			cells = 40,
			show = i32(mode),
			scale = mode == 0 ? 2000.0 : 200.0,
		}
		run_fullscreen_diag(
			report, "_probe/pl/shaders/diag_margin.frag",
			fmt.tprintf("margin_%s", mode == 0 ? "depth" : (mode == 1 ? "metres" : "coords")),
			upload_margin_inputs,
		)
	}

	DIAG_MODES := [5]int{0, 1, 2, 3, 4}
	DIAG_NAMES := [5]string{"ratio", "stored", "axis", "euclid", "uniform"}
	for mode in DIAG_MODES {
		diag_inputs = {
			light = scene.point_lights[lit].position,
			zn = scene.point_lights[lit].near,
			zf = scene.point_lights[lit].far,
			cube = scene.point_lights[lit].gl_shadow_map_texture,
			cells = 20,
			show = i32(mode),
			scale = 1.0,
		}
		run_fullscreen_diag(
			report, "_probe/pl/shaders/diag_floor.frag",
			fmt.tprintf("diag_%s", DIAG_NAMES[mode]),
			upload_diag_inputs,
		)
	}
	dump_cube_raw("_probe/pl/out/cube_raw.bin", lit)
	rep_line(report, "wrote _probe/pl/out/cube_raw.bin")

	// The same cube, rasterized with culling turned off.
	//
	// The shadow pass inherits glEnable(GL_CULL_FACE) and glCullFace(GL_BACK) from startup,
	// and a cube face's winding is not the camera's: three of the six faces are seen from
	// behind relative to the viewer's convention, so half the cube can drop the caster
	// outright. Turning culling off for this one pass and re-reading the cube says whether
	// the caster was ever in it.
	gl.Disable(gl.CULL_FACE)
	render.RasterizeShadowMap()
	gl.Enable(gl.CULL_FACE)
	rep_line(report, "")
	rep_line(report, "the same cube with CULL_FACE off:")
	scene_from_cube(report, lit)

	// The visibility the cube filter itself returns, drawn instead of the shaded colour.
	// This is the quantity the whole feature turns on, and it can be compared against
	// geometry directly, where a shaded pixel cannot: lighting multiplies the term by a
	// material colour, so a wrong visibility and a dark tile look the same.
	vs_src, vs_ok := read_owned_source("resource/shaders/no_light.vert")
	if !vs_ok do return
	defer delete(vs_src)
	vis_src, vis_ok := read_owned_source("_probe/pl/shaders/show_visibility.frag")
	if !vis_ok do return
	defer delete(vis_src)

	vs := compile_from(gl.VERTEX_SHADER, vs_src, "visibility_vertex")
	fs := compile_from(gl.FRAGMENT_SHADER, vis_src, "visibility_fragment")
	if vs == 0 || fs == 0 do return
	vp := link_from(vs, fs, "visibility")
	if vp == 0 do return
	defer gl.DeleteProgram(vp)
	defer gl.DeleteShader(vs)
	defer gl.DeleteShader(fs)

	render.RasterizeShadowMap()
	render.UniformShadowMapping()
	vb := lookup_all(vp)
	upload_pbr_shadow(vb, render.SHADOW_MAP_UNIT_BASE, .All_Entries, report)
	gl.UseProgram(vp)
	gl.Uniform1i(gl.GetUniformLocation(vp, cstring("u_probe_light")), i32(lit))

	w, h := render.GetWindowSize()
	render.MSAABind()

	// The bias is swept rather than assumed. It is compared in metres -- the stored depth
	// is turned back into a distance before the two sides meet -- so the size of the
	// constant decides how far behind the blocker a point may sit and still be called lit,
	// and that distance is what a shadow's contact point relies on.
	BIASES := [7]f32{0.0, 0.00001, 0.0001, 0.0002, 0.0005, 0.0015, 1.0}
	for bias in BIASES {
		for axis in 0 ..< 2 {
			render.MSAABind()
			upload_pbr_shadow(vb, render.SHADOW_MAP_UNIT_BASE, .All_Entries, report)
			gl.UseProgram(vp)
			gl.Uniform1i(gl.GetUniformLocation(vp, cstring("u_probe_light")), i32(lit))
			gl.Uniform1f(gl.GetUniformLocation(vp, cstring("u_probe_bias")), bias)
			gl.Uniform1i(gl.GetUniformLocation(vp, cstring("u_probe_axis")), i32(axis))
			for i := u32(1); i <= scene.nodes.next; i += 1 {
				if !scene.nodes.in_use[i] do continue
				draw_one_node(vp, i, w, h)
			}
			e := flush_errors()
			render.MSAAResolve()
			render.BlitToFramebuffer(0, render.msaa.tex_resolved, i32(w), i32(h))
			path := fmt.tprintf("_probe/pl/out/vis_%s_bias_%g.ppm", axis == 0 ? "euclid" : "axis", bias)
			write_ppm(path, int(w), int(h))
			rep_line(report, "  visibility", axis == 0 ? "euclidean" : "axis     ",
				" bias", bias, "->", path, " error:", err_name(e))
		}
	}
	s3.GL_SwapWindow(render.window)
}

// DrawPBRNode with the program argument, so a variant compiled by this harness can be
// used without touching the project's global one.
draw_one_node :: proc(p : u32, id : u32, w, h : u32) {
	node := &scene.nodes.data[id]
	mesh := &scene.meshes.data[node.mesh_id]

	aspect := f32(w) / f32(h)
	view_matrix := scene.ViewMatrix(&scene.Main_Camera)
	proj_matrix := scene.ProjMatrix(&scene.Main_Camera, aspect)
	gl.UseProgram(p)
	gl.UniformMatrix4fv(gl.GetUniformLocation(p, cstring("m_view")), 1, false, &view_matrix[0, 0])
	gl.UniformMatrix4fv(gl.GetUniformLocation(p, cstring("m_proj")), 1, false, &proj_matrix[0, 0])
	gl.UniformMatrix4fv(gl.GetUniformLocation(p, cstring("m_model")), 1, false, &node.transform[0, 0])

	m3 := linalg.matrix3_from_matrix4_f32(node.transform)
	normal_matrix := linalg.transpose(linalg.matrix3_inverse_f32(m3))
	gl.UniformMatrix3fv(gl.GetUniformLocation(p, cstring("m_normal")), 1, false, &normal_matrix[0, 0])
	gl.UniformMatrix4fv(
		gl.GetUniformLocation(p, cstring("u_camera_transform")),
		1, false, &scene.Main_Camera.transform[0, 0],
	)
	gl.Uniform1f(gl.GetUniformLocation(p, cstring("u_shininess")), 64.0)
	gl.Uniform1f(gl.GetUniformLocation(p, cstring("u_specular_strength")), 0.35)

	for &prim in mesh.primitives {
		mat := &scene.materials.data[prim.material_id]
		has_tex : i32 = 0
		if mat.base_color_texture.texture_id != 0 {
			tex := &scene.textures.data[mat.base_color_texture.texture_id]
			has_tex = 1
			gl.ActiveTexture(gl.TEXTURE0)
			gl.BindTexture(gl.TEXTURE_2D, tex.gl_texture_id)
			gl.Uniform1i(gl.GetUniformLocation(p, cstring("u_base_color_texture")), 0)
		}
		gl.Uniform4fv(gl.GetUniformLocation(p, cstring("u_base_color_factor")), 1, raw_data(&mat.base_color_factor))
		gl.Uniform1i(gl.GetUniformLocation(p, cstring("u_has_base_color_texture")), has_tex)
		gl.BindVertexArray(prim.gl_vao_id)
		gl.DrawElements(gl.TRIANGLES, i32(prim.indices_count), gl.UNSIGNED_INT, nil)
	}
}

// The frame the project draws, with the two renderer-side faults repaired in front of it.
//
// The shading program is replaced by one compiled from a shader file the caller names, and
// the shadow uploads are redirected to the program that actually declares those uniforms
// with every array entry given a live texture unit. Nothing else changes: same shadow pass,
// same lights, same materials, same draws. This is the shape of the intended repair, run
// against the real scene so the picture is the renderer's own.
//
// The point light's visibility is scaled by a uniform, so one compiled shader can be drawn
// with the shadow on, off, or amplified without recompiling anything. Text surgery was tried
// first and abandoned: a marker that matches the file on disk but not the variant built from
// it fails silently, and a silent skip reads exactly like a result.
real_onto_current_target :: proc(report : Reporter, shader_path : string, visibility_scale : f32) {
	pbr_src, ok := read_owned_source(shader_path)
	if !ok do return
	defer delete(pbr_src)
	probe_src, pok := probe_visibility_scale(pbr_src, fmt.tprintf("%g", visibility_scale))
	if !pok {
		fmt.eprintln("[x] visibility marker not found in", shader_path)
		return
	}
	vs_src, vs_ok := read_owned_source("resource/shaders/no_light.vert")
	if !vs_ok do return
	defer delete(vs_src)

	vs := compile_from(gl.VERTEX_SHADER, vs_src, "real_vertex")
	fs := compile_from(gl.FRAGMENT_SHADER, probe_src, "real_fragment")
	if vs == 0 || fs == 0 do return
	p := link_from(vs, fs, "real")
	if p == 0 do return
	defer gl.DeleteProgram(p)
	defer gl.DeleteShader(vs)
	defer gl.DeleteShader(fs)

	w, h := render.GetWindowSize()
	scene.PreComputation()
	render.RasterizeShadowMap()

	b := lookup_all(p)
	upload_pbr_shadow(b, render.SHADOW_MAP_UNIT_BASE, .All_Entries, report)

	render.MSAABind()
	nerr := 0
	for i := u32(1); i <= scene.nodes.next; i += 1 {
		if !scene.nodes.in_use[i] do continue
		flush_errors()
		draw_one_node(p, i, w, h)
		if flush_errors() != 0 do nerr += 1
	}
	render.MSAAResolve()
	render.BlitToFramebuffer(0, render.msaa.tex_resolved, i32(w), i32(h))

	name := fmt.tprintf("_probe/pl/out/real_vis_%g.ppm", visibility_scale)
	write_ppm(name, int(w), int(h))
	rep_line(report, "  drew visibility scale", visibility_scale, "->", name,
		" nodes with a GL error:", nerr)
	s3.GL_SwapWindow(render.window)
}

real_main :: proc(shader_path : string, visibility_scale : f32) {
	for frame in 0 ..< 5 {
		_ = frame
		real_onto_current_target(report_sink, shader_path, visibility_scale)
		time.sleep(300 * time.Millisecond)
	}
}

// The upload's running commentary goes nowhere in this mode; the picture is the output.
report_sink : Reporter

main :: proc() {
	mode := "real"
	if len(os.args) > 1 do mode = os.args[1]

	if !render.Init() {
		fmt.eprintln("[x] renderer init failed")
		os.exit(1)
	}
	render.InitShader()
	entity.InitScene()

	if mode == "sweep" {
		report := rep_open("_probe/pl/out/sweep_report.txt")
		defer rep_close(report)
		CANDIDATES := [8][4]f32{
			{0.8, 1.2, -0.8, 1.0},
			{0.8, 1.2, -0.8, 1.6},
			{0.9, 1.4, -0.9, 2.4},
			{1.0, 2.6, -1.0, 9.0},
			{1.2, 3.0, -1.2, 13.0},
			{1.4, 3.2, -1.4, 16.0},
			{1.0, 2.2, -1.0, 6.0},
			{1.1, 2.4, -1.1, 8.0},
		}
		for c, k in CANDIDATES {
			name := fmt.tprintf("_probe/pl/out/sweep_%d.ppm", k)
			relit_main(report, {c.x, c.y, c.z}, c.w, [3]f32{0.0, 0.34, 1.05}, [3]f32{0.0, 0.23, 0.0}, name)
		}
		rep_line(report, "done")
		s3.Quit()
		return
	}
	if mode == "relit" {
		report := rep_open("_probe/pl/out/relit_report.txt")
		defer rep_close(report)
		relit_main(
			report,
			[3]f32{1.2, 1.8, -1.2},
			3.0,
			[3]f32{0.0, 0.34, 1.05},
			[3]f32{0.0, 0.23, 0.0},
			"_probe/pl/out/relit.ppm",
		)
		rep_line(report, "done")
		s3.Quit()
		return
	}
	if mode == "hsweep" {
		report := rep_open("_probe/pl/out/hsweep_report.txt")
		defer rep_close(report)
		HEIGHTS := [10]f32{0.50, 0.60, 0.70, 0.75, 0.80, 0.90, 1.00, 1.20, 1.50, 2.00}
		for h in HEIGHTS {
			for i in 0 ..< int(scene.point_light_count) {
				scene.point_lights.position[i] = {0.55, h, -0.55}
				scene.point_lights.intensity[i] = 2.4
			}
			scene.direction_lights.intensity[0] = 0.0
			name := fmt.tprintf("_probe/pl/out/h_%g.ppm", h)
			fixed_main(report, name, "resource/shaders/no_light.frag")
		}
		AXIS_MODES := [5]int{0, 1, 2, 3, 4}
		AXIS_NAMES := [5]string{"stored", "euclid", "axis", "over_axis", "over_euclid"}
		for m in AXIS_MODES {
			diag_inputs = {
				light = scene.point_lights.position[3],
				zn = scene.point_lights.camera[3].near,
				zf = scene.point_lights.camera[3].far,
				cube = scene.point_lights.gl_shadow_map_texture[3],
				cells = 20,
				show = i32(m),
				scale = 1.0,
			}
			run_fullscreen_diag(
				report, "_probe/pl/shaders/diag_axis.frag",
				fmt.tprintf("axis_%s", AXIS_NAMES[m]),
				upload_diag_inputs,
			)
		}
		rep_line(report, "done")
		s3.Quit()
		return
	}
		if mode == "hvis" {
		report := rep_open("_probe/pl/out/hvis_report.txt")
		defer rep_close(report)
		HEIGHTS := [8]f32{0.50, 0.58, 0.60, 0.65, 0.70, 0.80, 0.90, 1.20}
		for h in HEIGHTS {
			for i in 0 ..< int(scene.point_light_count) {
				scene.point_lights.position[i] = {0.0, h, 0.0}
				scene.point_lights.intensity[i] = 2.4
			}
			scene.PreComputation()
			render.RasterizeShadowMap()
			diag_inputs = {
				light = scene.point_lights.position[0],
				zn = scene.point_lights.camera[0].near,
				zf = scene.point_lights.camera[0].far,
				cube = scene.point_lights.gl_shadow_map_texture[0],
				cells = 20,
				show = 0,
				scale = 1.0,
			}
			run_fullscreen_diag(
				report, "_probe/pl/shaders/diag_vis.frag",
				fmt.tprintf("hv_%g", h),
				upload_diag_inputs,
			)
		}
		rep_line(report, "done")
		s3.Quit()
		return
	}
	if mode == "faces" {
		report := rep_open("_probe/pl/out/faces_report.txt")
		defer rep_close(report)
		HEIGHTS := [6]f32{0.45, 0.50, 0.55, 0.58, 0.65, 0.90}
		FACES := [3]string{"-Y", "+Y", "+Z"}
		for h in HEIGHTS {
			for i in 0 ..< int(scene.point_light_count) {
				scene.point_lights.position[i] = {0.0, h, 0.0}
				scene.point_lights.intensity[i] = 2.4
			}
			scene.PreComputation()
			render.RasterizeShadowMap()
			rep_line(report, "h =", h, " near =", scene.point_lights.camera[0].near,
				" far =", scene.point_lights.camera[0].far)
			rep_line(report, "   cube =", scene.point_lights.gl_shadow_map_texture[0],
				" fbo =", scene.point_lights.gl_shadow_map_fbo[0])
			for f in 0 ..< 3 {
				diag_inputs = {
					light = scene.point_lights.position[0],
					zn = scene.point_lights.camera[0].near,
					zf = scene.point_lights.camera[0].far,
					cube = scene.point_lights.gl_shadow_map_texture[0],
					cells = 20,
					show = i32(f),
					scale = 1.0,
				}
				run_fullscreen_diag(
					report, "_probe/pl/shaders/diag_face.frag",
					fmt.tprintf("face_%g_%s", h, FACES[f]),
					upload_diag_inputs,
				)
			}
		}
		rep_line(report, "done")
		s3.Quit()
		return
	}
	if mode == "appframe" {
		report := rep_open("_probe/pl/out/appframe_report.txt")
		defer rep_close(report)
		// The project's own loop, verbatim: entity.Update then scene.PreComputation then
		// render.Render. Nothing here re-implements the upload, so whatever this writes is
		// what the application draws.
		SHOTS := [8]int{0, 4, 8, 12, 16, 20, 24, 28}
		SHOT_SET := [32]bool{
			true, false, false, false, true, false, false, false,
			true, false, false, false, true, false, false, false,
			true, false, false, false, true, false, false, false,
			true, false, false, false, true, false, false, false,
		}
		_ = SHOTS
		for frame in 0 ..< 32 {
			entity.Update(1.0 / 60.0)
			scene.PreComputation()
			render.Render()
			if frame == 0 {
				rep_line(report, "global_time =", entity.global_time,
					" point_light_entity.position =", entity.point_light_entity.position)
				for i in 0 ..< 4 {
					rep_line(report, "   position[", i, "] =", scene.point_lights.position[i],
						" as raw f32:", scene.point_lights.position[i].x,
						scene.point_lights.position[i].y, scene.point_lights.position[i].z)
				}
			}
			if SHOT_SET[frame] {
				w, h := render.GetWindowSize()
				gl.BindFramebuffer(gl.READ_FRAMEBUFFER, render.msaa.fbo_resolved)
				gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
				gl.BlitFramebuffer(
					0, 0, render.msaa.width, render.msaa.height,
					0, 0, i32(w), i32(h), gl.COLOR_BUFFER_BIT, gl.NEAREST,
				)
				gl.BindFramebuffer(gl.READ_FRAMEBUFFER, 0)
				gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
				name := fmt.tprintf("_probe/pl/out/app_%02d.ppm", frame)
				write_ppm(name, int(w), int(h))
				rep_line(report, "frame", frame,
					" light", scene.point_lights.position[0],
					" near", scene.point_lights.camera[0].near,
					" far", scene.point_lights.camera[0].far,
					" ->", name)
			}
			time.sleep(30 * time.Millisecond)
		}
		rep_line(report, "done")
		s3.Quit()
		return
	}
	if mode == "osweep" {
		report := rep_open("_probe/pl/out/osweep_report.txt")
		defer rep_close(report)
		// The application's own pipeline with the light parked at one orbit height, at the
		// orbit radius the entity uses. No material, camera or upload is substituted.
		HEIGHTS := [12]f32{0.35, 0.45, 0.50, 0.55, 0.58, 0.60, 0.65, 0.70, 0.75, 0.85, 1.00, 1.30}
		for h in HEIGHTS {
			entity.Update(1.0 / 60.0)
			light_xz : f32 = math.sqrt(f32(2)) * 0.55
			scene.point_lights.position[0] = {light_xz, h, 0.0}
			scene.PreComputation()
			render.Render()
			w, wh := render.GetWindowSize()
			gl.BindFramebuffer(gl.READ_FRAMEBUFFER, render.msaa.fbo_resolved)
			gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
			gl.BlitFramebuffer(
				0, 0, render.msaa.width, render.msaa.height,
				0, 0, i32(w), i32(wh), gl.COLOR_BUFFER_BIT, gl.NEAREST,
			)
			gl.BindFramebuffer(gl.READ_FRAMEBUFFER, 0)
			gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
			name := fmt.tprintf("_probe/pl/out/os_%g.ppm", h)
			write_ppm(name, int(w), int(wh))
			rep_line(report, "h", h, " near", scene.point_lights.camera[0].near,
				" far", scene.point_lights.camera[0].far, " ->", name)
		}
		rep_line(report, "done")
		s3.Quit()
		return
	}
	if mode == "obias" {
		report := rep_open("_probe/pl/out/obias_report.txt")
		defer rep_close(report)
		// The application's own pipeline, with only the bias magnitude changed. The shadow
		// source is the file on disk, recompiled with a different constant each time.
		owned, ok := read_owned_source("resource/shaders/no_light.frag")
		if !ok do return
		defer delete(owned)
		vs_src, vs_ok := read_owned_source("resource/shaders/no_light.vert")
		if !vs_ok do return
		defer delete(vs_src)

		MAGS := [4]string{"0.5", "1.0", "2.0", "4.0"}
		for m in MAGS {
			body, pok := force_bias_texels(owned, m, "4.0")
			if !pok {
				rep_line(report, "[x] bias marker not found")
				break
			}
			defer delete(body)
			vs := compile_from(gl.VERTEX_SHADER, vs_src, fmt.tprintf("obias_%s_vertex", m))
			fs := compile_from(gl.FRAGMENT_SHADER, body, fmt.tprintf("obias_%s_fragment", m))
			if vs == 0 || fs == 0 do continue
			p := link_from(vs, fs, fmt.tprintf("obias_%s", m))
			if p == 0 do continue

			BIAS_HEIGHTS := [3]f32{0.60, 0.70, 1.00}
			for h in BIAS_HEIGHTS {
				entity.Update(1.0 / 60.0)
				light_xz : f32 = math.sqrt(f32(2)) * 0.55
				scene.point_lights.position[0] = {light_xz, h, 0.0}
				scene.PreComputation()
				render.RasterizeShadowMap()
				b := lookup_all(p)
				upload_pbr_shadow(b, render.SHADOW_MAP_UNIT_BASE, .All_Entries, report)
				w, wh := render.GetWindowSize()
				render.MSAABind()
				for i := u32(1); i <= scene.nodes.next; i += 1 {
					if !scene.nodes.in_use[i] do continue
					draw_one_node(p, i, w, wh)
				}
				render.MSAAResolve()
				gl.BindFramebuffer(gl.READ_FRAMEBUFFER, render.msaa.fbo_resolved)
				gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
				gl.BlitFramebuffer(
					0, 0, render.msaa.width, render.msaa.height,
					0, 0, i32(w), i32(wh), gl.COLOR_BUFFER_BIT, gl.NEAREST,
				)
				gl.BindFramebuffer(gl.READ_FRAMEBUFFER, 0)
				gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
				name := fmt.tprintf("_probe/pl/out/ob_%s_h%g.ppm", m, h)
				write_ppm(name, int(w), int(wh))
				rep_line(report, "bias_texels", m, " slope_clamp 4.0  h", h, " ->", name)
			}
			gl.DeleteProgram(p)
			gl.DeleteShader(vs)
			gl.DeleteShader(fs)
		}
		rep_line(report, "done")
		s3.Quit()
		return
	}
	if mode == "cmp" {
		report := rep_open("_probe/pl/out/cmp_report.txt")
		defer rep_close(report)
		compare_paths(report, "resource/shaders/no_light.frag", "plain", 0.9, 0.0)
		compare_paths(report, "_probe/pl/shaders/vis_only.frag", "visonly", 0.9, 0.0)
		compare_paths(report, "_probe/pl/shaders/vis_margin.frag", "margin", 0.9, 0.0)
		rep_line(report, "done")
		s3.Quit()
		return
	}
	if mode == "bigr" {
		report := rep_open("_probe/pl/out/bigr_report.txt")
		defer rep_close(report)
		// The reported setup: one point light orbiting a 3.0 radius ring. The phase is varied
		// so the banding can be tied to where the light is, not just to the height.
		PHASES := [4]f32{0.0, 0.25, 0.5, 0.75}
		for p in PHASES {
			entity.Update(1.0 / 60.0)
			a := p * 2.0 * math.PI
			scene.point_lights.position[0] = {3.0 * math.cos(a), 0.9, 3.0 * math.sin(a)}
			scene.point_lights.intensity[0] = 2.4
			scene.direction_lights.intensity[0] = 0.0
			scene.PreComputation()
			render.Render()
			w, wh := render.GetWindowSize()
			gl.BindFramebuffer(gl.READ_FRAMEBUFFER, render.msaa.fbo_resolved)
			gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
			gl.BlitFramebuffer(
				0, 0, render.msaa.width, render.msaa.height,
				0, 0, i32(w), i32(wh), gl.COLOR_BUFFER_BIT, gl.NEAREST,
			)
			gl.BindFramebuffer(gl.READ_FRAMEBUFFER, 0)
			gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
			name := fmt.tprintf("_probe/pl/out/bigr_%g.ppm", p)
			write_ppm(name, int(w), int(wh))
			rep_line(report, "phase", p, " light", scene.point_lights.position[0],
				" near", scene.point_lights.camera[0].near,
				" far", scene.point_lights.camera[0].far, " ->", name)
		}
		rep_line(report, "done")
		s3.Quit()
		return
	}
	if mode == "bigrvis" {
		report := rep_open("_probe/pl/out/bigrvis_report.txt")
		defer rep_close(report)
		// The reported setup again, but each frame is drawn with a program whose only output
		// is one number from the shadow test. A band in vis_only came from the comparison
		// itself; a band in vis_depth came from the depth the receiver was converted into.
		PHASE_LIST := [2]f32{0.0, 0.25}
		LAYERS := [7]string{"vis_only", "vis_depth", "vis_axis", "vis_bias", "vis_stored", "vis_margin", "vis_shadowmap"}
		for p in PHASE_LIST {
			entity.Update(1.0 / 60.0)
			a := p * 2.0 * math.PI
			scene.point_lights.position[0] = {3.0 * math.cos(a), 0.9, 3.0 * math.sin(a)}
			scene.point_lights.intensity[0] = 2.4
			scene.direction_lights.intensity[0] = 0.0
			scene.PreComputation()
			render.RasterizeShadowMap()

			for layer in LAYERS {
				path := fmt.tprintf("_probe/pl/shaders/%s.frag", layer)
				fs_src, ok := read_owned_source(path)
				if !ok do continue
				defer delete(fs_src)
				vs_src, vs_ok := read_owned_source("resource/shaders/no_light.vert")
				if !vs_ok do continue
				defer delete(vs_src)
				vs := compile_from(gl.VERTEX_SHADER, vs_src, fmt.tprintf("bigr_%s_vertex", layer))
				fs := compile_from(gl.FRAGMENT_SHADER, fs_src, fmt.tprintf("bigr_%s_fragment", layer))
				if vs == 0 || fs == 0 do continue
				prog := link_from(vs, fs, fmt.tprintf("bigr_%s", layer))
				if prog == 0 do continue

				b := lookup_all(prog)
				upload_pbr_shadow(b, render.SHADOW_MAP_UNIT_BASE, .All_Entries, report)
				w, wh := render.GetWindowSize()
				render.MSAABind()
				for i := u32(1); i <= scene.nodes.next; i += 1 {
					if !scene.nodes.in_use[i] do continue
					draw_one_node(prog, i, w, wh)
				}
				e := flush_errors()
				render.MSAAResolve()
				gl.BindFramebuffer(gl.READ_FRAMEBUFFER, render.msaa.fbo_resolved)
				gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
				gl.BlitFramebuffer(
					0, 0, render.msaa.width, render.msaa.height,
					0, 0, i32(w), i32(wh), gl.COLOR_BUFFER_BIT, gl.NEAREST,
				)
				gl.BindFramebuffer(gl.READ_FRAMEBUFFER, 0)
				gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, 0)
				name := fmt.tprintf("_probe/pl/out/bv_%s_p%g.ppm", layer, p)
				write_ppm(name, int(w), int(wh))
				rep_line(report, "phase", p, " layer", layer, " ->", name,
					" error:", err_name(e))
				gl.DeleteProgram(prog)
				gl.DeleteShader(vs)
				gl.DeleteShader(fs)
			}
		}
		rep_line(report, "done")
		s3.Quit()
		return
	}
	if mode == "nodir" {
		report := rep_open("_probe/pl/out/nodir_report.txt")
		defer rep_close(report)
		if install_lighting_program("resource/shaders/no_light_nodir.frag") {
			fixed_main(report, "_probe/pl/out/nodir.ppm", "no_light_nodir.frag")
		}
		rep_line(report, "done")
		s3.Quit()
		return
	}
	if mode == "fixed" {
		report := rep_open("_probe/pl/out/fixed_report.txt")
		defer rep_close(report)
		fixed_main(report, "_probe/pl/out/fixed.ppm", "resource/shaders/no_light.frag")
		rep_line(report, "done")
		s3.Quit()
		return
	}
	if mode == "nopoint" {
		report := rep_open("_probe/pl/out/nopoint_report.txt")
		defer rep_close(report)
		if !install_lighting_program("resource/shaders/no_light_nopoint.frag") {
			rep_line(report, "[x] could not install the no-point-lighting program")
		} else {
			fixed_main(report, "_probe/pl/out/nopoint.ppm", "resource/shaders/no_light_nopoint.frag")
		}
		rep_line(report, "done")
		s3.Quit()
		return
	}
	if mode == "real" {
		real_main("resource/shaders/no_light.frag", 1.0)
		s3.Quit()
		return
	}
	if mode == "vis0" {
		real_main("resource/shaders/no_light.frag", 0.0)
		s3.Quit()
		return
	}
	if mode == "vis2" {
		real_main("resource/shaders/no_light.frag", 2.0)
		s3.Quit()
		return
	}

	report := rep_open("_probe/pl/out/report.txt")
	defer rep_close(report)
	entity.Update(0.0)
	scene.PreComputation()
	probe_main(report)
	rep_line(report, "")
	rep_line(report, "done")
	s3.Quit()
}
