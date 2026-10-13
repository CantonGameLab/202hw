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
import "core:slice"


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
	u_emissive_factor : i32,
	u_emissive_strength : i32,

	u_light_count : i32,
	u_light_positions : i32,
	u_light_colors : i32,
	u_light_intensities : i32,
	u_light_directions : i32,
	u_light_has_shadow : i32,
	u_light_view_projs : [sam.MAX_LIGHT_COUNT]i32,
	u_light_shadow_maps : [sam.MAX_LIGHT_COUNT]i32,

	u_point_light_count : i32,
	u_point_light_positions : i32,
	u_point_light_colors : i32,
	u_point_light_intensities : i32,
	u_point_light_has_shadow : i32,
	u_point_light_width : i32,
	u_point_light_taps : i32,
	u_point_light_shadow_maps : [sam.MAX_POINT_LIGHT_COUNT]i32,

	u_camera_transform : i32,
	u_shininess : i32,
	u_specular_strength : i32,

}

DrawIterm :: struct{
	primitive_id : u32,
	node_id : u32,
	distance : f32,
}

program : PBRProgram

solid_draw_list : [dynamic]DrawIterm
transparent_draw_list : [dynamic]DrawIterm

drawPBR :: proc(w, h : u32) {

	defer clear(&solid_draw_list)
	defer clear(&transparent_draw_list)
	//solid pass
	gl.UseProgram(program.program)

	// Upload the proj, view matrix and camera transform
	aspect := f32(w) / f32(h)
	view_matrix := sam.ViewMatrix(&sam.Main_Camera)
	proj_matrix := sam.ProjMatrix(&sam.Main_Camera, aspect)


	gl.UniformMatrix4fv(program.m_view, 1, false, &view_matrix[0,0])
	gl.UniformMatrix4fv(program.m_proj, 1, false, &proj_matrix[0,0])
	gl.UniformMatrix4fv(program.u_camera_transform, 1, false, &sam.Main_Camera.transform[0,0])

	main_camera_position := [3]f32{ 
		sam.Main_Camera.transform[0, 3], 
		sam.Main_Camera.transform[1, 3], 
		sam.Main_Camera.transform[2, 3],
	}

	main_camera_neg_z_vector := [3]f32 {
		-sam.Main_Camera.transform[0, 2],
		-sam.Main_Camera.transform[1, 2],
		-sam.Main_Camera.transform[2, 2],
	}

	for index := u32(1); index <= sam.nodes.next; index += 1 {
		if !sam.nodes.in_use[index] do continue
		node := &sam.nodes.data[index]
		if node == nil do continue
		mesh := me.RefGet(&sam.meshes, node.mesh_id)

		position := [3]f32{ node.transform[0, 3], node.transform[1, 3], node.transform[2, 3] }
		
		distance := linalg.dot(
			position - main_camera_position,
			main_camera_neg_z_vector,
		)

		for &p, p_index in mesh.primitives {
			material := me.RefGet(&sam.materials, p.material_id)
			if material == nil do continue

			the_list : ^[dynamic]DrawIterm
			if material.alpha_mode == .Opaque || material.alpha_mode == .Mask {
				the_list = &solid_draw_list
			} else {
				the_list = &transparent_draw_list
			} 
			append(
				the_list, 
				DrawIterm{
					primitive_id = u32(p_index),
					node_id = index,
					distance = distance,
				},
			)
		}
	}

	compareDrawItermByBiggerDepth :: proc(a, b : DrawIterm) -> bool {
		if(a.distance != b.distance) {
			return a.distance > b.distance
		}
		return a.node_id < b.node_id
	}

	compareDrawItermBySmallerDepth :: proc(a, b : DrawIterm) -> bool {
		if (a.distance != b.distance) {
			return a.distance < b.distance
		}
		return a.node_id < b.node_id
	}
	
	slice.sort_by(solid_draw_list[:], compareDrawItermBySmallerDepth)
	slice.sort_by(transparent_draw_list[:], compareDrawItermByBiggerDepth)

	
	gl.DepthMask(true)
	gl.Disable(gl.BLEND)

	drawPrimitves(solid_draw_list[:])

	gl.DepthMask(false)
	defer gl.DepthMask(true)
	gl.Enable(gl.BLEND)
	defer gl.Disable(gl.BLEND)

	drawPrimitves(transparent_draw_list[:])
}

drawPrimitves :: proc(draw_list : []DrawIterm) {
	for &draw_iterm, index in draw_list {
		
		node := me.ArrayGet(&sam.nodes, draw_iterm.node_id)
		if node == nil do continue
		mesh := me.RefGet(&sam.meshes, node.mesh_id)
		if mesh == nil do continue

		if index == 0 || draw_list[index - 1].node_id != draw_list[index].node_id {
			// When the index switches to a different node, we re-upload all the parameters related to the node
			gl.UniformMatrix4fv(program.m_model, 1, false, &node.transform[0,0])
			m3 := linalg.matrix3_from_matrix4_f32(node.transform)
			normal_matrix := linalg.transpose(linalg.matrix3_inverse_f32(m3))
			gl.UniformMatrix3fv(program.m_normal, 1, false, &normal_matrix[0,0])
		}

		p := &mesh.primitives[draw_iterm.primitive_id]
		
		mat := me.RefGet(&sam.materials, p.material_id)
		if mat == nil do continue

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
		gl.Uniform3fv(program.u_emissive_factor, 1, raw_data(&mat.emissive_factor))
		gl.Uniform1f(program.u_emissive_strength, mat.emissive_strength)
		gl.BindVertexArray(p.gl_vao_id)
		gl.DrawElements(gl.TRIANGLES, i32(p.indices_count), gl.UNSIGNED_INT, nil)
	}
}

initPBR :: proc() {
	program.vs = compileShader(gl.VERTEX_SHADER, "resource/shaders/pbr.vert")
	program.fs = compileShader(gl.FRAGMENT_SHADER, "resource/shaders/pbr.frag")
	program.program = linkProgram(program.vs, program.fs)
	program.m_proj = gl.GetUniformLocation(program.program, cstring("m_proj"))
	program.m_view = gl.GetUniformLocation(program.program, cstring("m_view"))
	program.m_model = gl.GetUniformLocation(program.program, cstring("m_model"))
	program.m_normal = gl.GetUniformLocation(program.program, cstring("m_normal"))
	program.u_base_color_factor = gl.GetUniformLocation(program.program, cstring("u_base_color_factor"))
	program.u_base_color_texture = gl.GetUniformLocation(program.program, cstring("u_base_color_texture"))
	program.u_has_base_color_texture = gl.GetUniformLocation(program.program, cstring("u_has_base_color_texture"))
	program.u_emissive_factor = gl.GetUniformLocation(program.program, cstring("u_emissive_factor"))
	program.u_emissive_strength = gl.GetUniformLocation(program.program, cstring("u_emissive_strength"))
	program.u_camera_transform = gl.GetUniformLocation(program.program, cstring("u_camera_transform"))
	program.u_shininess = gl.GetUniformLocation(program.program, cstring("u_shininess"))
	program.u_specular_strength = gl.GetUniformLocation(program.program, cstring("u_specular_strength"))

	gl.UseProgram(program.program)
	gl.Uniform1i(program.u_base_color_texture, 0)
	gl.Uniform1f(program.u_shininess, 64.0)
	gl.Uniform1f(program.u_specular_strength, 0.35)
}
