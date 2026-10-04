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
	// A directional light has no position, so its incidence direction cannot be derived
	// from one: every surface must be lit from the same direction and with no falloff.
	// This carries that direction for the direction_lights whose kind says so. Without it the
	// shader treats a sun as a point source at its nominal position, which both varies the
	// direction across the scene and divides the radiance by the squared distance to a
	// point that is not emitting.
	u_light_directions : i32,
	u_camera_transform : i32,
	u_shininess : i32,
	u_specular_strength : i32,

	// Shadow state, indexed by light slot to match the array declarations in
	// no_light.frag. Only the directional light's entry is ever filled, because it is
	// the only light this project casts shadows from, but the shape has to match what
	// the shader indexes its light loop with. These describe the light rather than the
	// object being drawn, so UniformShadowMapping sets them once per frame instead of
	// once per node.
	u_light_view_projs : [sam.MAX_LIGHT_COUNT]i32,
	u_light_shadow_maps : [sam.MAX_LIGHT_COUNT]i32,
	// Per light, not a count: slots are light indices, so they are not contiguous and a
	// count cannot say which ones hold a map. Its location is that of element zero; the
	// whole array is written in one call, which is also why the array is not queried
	// element by element the way the two above are.
	u_light_has_shadow : i32,
}

program : PBRProgram

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
	gl.Uniform1i(program.u_light_count, i32(sam.direction_light_count))

	if sam.direction_light_count > 0 {
		n := i32(sam.direction_light_count)
		gl.Uniform3fv(program.u_light_positions,   n, transmute([^]f32)rawptr(&sam.direction_lights.position))
		gl.Uniform3fv(program.u_light_colors,      n, transmute([^]f32)rawptr(&sam.direction_lights.color))
		gl.Uniform1fv(program.u_light_intensities, n, transmute([^]f32)rawptr(&sam.direction_lights.intensity))
		gl.Uniform3fv(program.u_light_directions,  n, transmute([^]f32)rawptr(&sam.direction_lights.direction))
	}

	for &p, index in mesh.primitives {
		mat := me.RefGet(&sam.materials, p.material_id)
		if mat == nil {
			continue
		}

		has_tex : i32 = 0
		if mat.base_color_texture.texture_id != 0 {
			tex := me.RefGet(&sam.textures, mat.base_color_texture.texture_id)
			if tex != nil {
				has_tex = 1
				gl.ActiveTexture(gl.TEXTURE0)
				gl.BindTexture(gl.TEXTURE_2D, tex.gl_texture_id)
				gl.Uniform1i(program.u_base_color_texture, 0)
			}
		}
		gl.Uniform4fv(program.u_base_color_factor, 1, raw_data(&mat.base_color_factor))
		gl.Uniform1i(program.u_has_base_color_texture, has_tex)
		gl.BindVertexArray(p.gl_vao_id)
		gl.DrawElements(gl.TRIANGLES, i32(p.indices_count), gl.UNSIGNED_INT, nil)
	}
}

