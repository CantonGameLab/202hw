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
	u_camera_transform : i32,
	u_shininess : i32,
	u_specular_strength : i32,
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
	gl.Uniform1i(program.u_light_count, sam.lights_count)
	
	if sam.lights_count > 0 {
		n := sam.lights_count
		gl.Uniform3fv(program.u_light_positions,   n, transmute([^]f32)rawptr(&sam.lights.position))
		gl.Uniform3fv(program.u_light_colors,      n, transmute([^]f32)rawptr(&sam.lights.color))
		gl.Uniform1fv(program.u_light_intensities, n, transmute([^]f32)rawptr(&sam.lights.intensity))
	}

	for &p, index in mesh.primitives {
		mat := me.RefGet(&sam.materials, p.material_id)
		if mat == nil {
			continue
		}

		if mat.base_color_texture.texture_id != 0 {
			tex := me.RefGet(&sam.textures, mat.base_color_texture.texture_id)
			if tex != nil {
				//has_tex = 1
				gl.ActiveTexture(gl.TEXTURE0)
				gl.BindTexture(gl.TEXTURE_2D, tex.gl_texture_id)
			}
		}
		gl.Uniform4fv(program.u_base_color_factor, 1, raw_data(&mat.base_color_factor))
		gl.Uniform1i(program.u_has_base_color_texture, 1)

		// The VAO remembers the element buffer binding, so no BindBuffer here.
		gl.BindVertexArray(p.gl_vao_id)
		gl.DrawElements(gl.TRIANGLES, i32(p.indices_count), gl.UNSIGNED_INT, nil)
	}
}
