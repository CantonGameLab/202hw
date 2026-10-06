package render

import gl "vendor:OpenGL"
import "core:fmt"
import sam "../scene"
import me "../memory"
import "core:math/linalg"

ShadowMappingProgram :: struct {
	program : u32,
	u_light_mvp : i32,
	
	//something parameter
	direction_light_resolution_width : i32,
	direction_light_resolution_height : i32,

	point_light_resolution_width : i32,
	point_light_resolution_height : i32,
}

shadow_mapping_program : ShadowMappingProgram

// The texture units the shadow maps occupy. Unit 0 is taken by the material's base
// colour texture, so the maps start one past it and each light gets its own unit,
// because a sampler uniform holds a unit number and a unit holds one target at a time.
SHADOW_MAP_UNIT_BASE :: 1

lighting_program :: proc() -> u32 {
	return program.program
}

empty_cube_texture : u32

CreateEmptyCubeTexture :: proc() {
	gl.GenTextures(1, &empty_cube_texture)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, empty_cube_texture)
	for face in 0 ..< 6 {
		gl.TexImage2D(
			gl.TEXTURE_CUBE_MAP_POSITIVE_X + u32(face), 0,
			gl.DEPTH_COMPONENT24, 1, 1, 0, gl.DEPTH_COMPONENT, gl.FLOAT, nil,
		)
	}
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_R, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAX_LEVEL, 0)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, 0)
}

initShadowMapping :: proc() {
	vs := compileShader(gl.VERTEX_SHADER, "resource/shaders/shadow_mapping.vert")
	fs := compileShader(gl.FRAGMENT_SHADER, "resource/shaders/shadow_mapping.frag")
	shadow_mapping_program.program = linkProgram(vs, fs)
	shadow_mapping_program.u_light_mvp = gl.GetUniformLocation(shadow_mapping_program.program, cstring("u_light_mvp"))


	shadow_mapping_program.direction_light_resolution_width = 1024
	shadow_mapping_program.direction_light_resolution_height = 1024
	shadow_mapping_program.point_light_resolution_width = 1024
	shadow_mapping_program.point_light_resolution_height = 1024

	CreateEmptyCubeTexture()

	lighting := lighting_program()

	for i in 0 ..< sam.MAX_LIGHT_COUNT {
		program.u_light_view_projs[i] = gl.GetUniformLocation(lighting, fmt.ctprintf("u_light_view_projs[%d]", i))
		program.u_light_shadow_maps[i] = gl.GetUniformLocation(lighting, fmt.ctprintf("u_light_shadow_maps[%d]", i))
	}

	for i in 0 ..< sam.MAX_POINT_LIGHT_COUNT {
		program.u_point_light_shadow_maps[i] = gl.GetUniformLocation(lighting, fmt.ctprintf("u_point_light_shadow_maps[%d]", i))
		program.u_point_light_nears[i] = gl.GetUniformLocation(lighting, fmt.ctprintf("u_point_light_nears[%d]", i))
		program.u_point_light_fars[i] = gl.GetUniformLocation(lighting, fmt.ctprintf("u_point_light_fars[%d]", i))
		
	}
	program.u_light_count = gl.GetUniformLocation(lighting, cstring("u_light_count"))
	program.u_light_positions = gl.GetUniformLocation(lighting, cstring("u_light_positions"))
	program.u_light_colors = gl.GetUniformLocation(lighting, cstring("u_light_colors"))
	program.u_light_intensities = gl.GetUniformLocation(lighting, cstring("u_light_intensities"))
	program.u_light_directions = gl.GetUniformLocation(lighting, cstring("u_light_directions"))
	program.u_light_has_shadow = gl.GetUniformLocation(lighting, cstring("u_light_has_shadow"))
	
	program.u_point_light_count = gl.GetUniformLocation(lighting, cstring("u_point_light_count"))
	program.u_point_light_positions = gl.GetUniformLocation(lighting, cstring("u_point_light_positions"))
	program.u_point_light_colors = gl.GetUniformLocation(lighting, cstring("u_point_light_colors"))
	program.u_point_light_intensities = gl.GetUniformLocation(lighting, cstring("u_point_light_intensities"))
	program.u_point_light_has_shadow = gl.GetUniformLocation(lighting, cstring("u_point_light_has_shadow"))}

RasterizeShadowMap :: proc() {
	for i in u32(0) ..< sam.direction_light_count {
		if sam.direction_lights[i].gl_shadow_map_fbo == 0 || sam.direction_lights[i].gl_shadow_map_texture == 0 do CreateDirectionLightShadowTexture(i)
		RasterizationDirectionLightShadowMap(i)
	}

	for i in u32(0) ..< sam.point_light_count {
		if sam.point_lights[i].gl_shadow_map_fbo == 0 || sam.point_lights[i].gl_shadow_map_texture == 0 do CreatePointLightShadowTexture(i)
		RasterizationPointLightShadowMap(i)
	}
}

UniformShadowMapping :: proc() {	
	gl.UseProgram(program.program)

	empty_unit : i32 = SHADOW_MAP_UNIT_BASE + sam.MAX_LIGHT_COUNT + sam.MAX_POINT_LIGHT_COUNT
	gl.ActiveTexture(gl.TEXTURE0 + u32(empty_unit))
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, empty_cube_texture)

	has_direction_light_shadow : [sam.MAX_LIGHT_COUNT]i32

	for i in u32(0) ..< sam.direction_light_count {
		light_view_proj := sam.direction_lights[i].proj_view
		gl.UniformMatrix4fv(program.u_light_view_projs[i], 1, false, &light_view_proj[0, 0])

		unit : i32 = SHADOW_MAP_UNIT_BASE + i32(i)
		gl.ActiveTexture(gl.TEXTURE0 + u32(unit))
		tex := sam.direction_lights.gl_shadow_map_texture[i]
		if tex == 0 do continue

		gl.BindTexture(gl.TEXTURE_2D, tex)
		gl.Uniform1i(program.u_light_shadow_maps[i], unit)
		has_direction_light_shadow[i] = 1
	}
	
	for i in int(sam.direction_light_count) ..< sam.MAX_LIGHT_COUNT {
		has_direction_light_shadow[i] = 0
	}

	gl.Uniform1iv(program.u_light_has_shadow, sam.MAX_LIGHT_COUNT, &has_direction_light_shadow[0])
	gl.Uniform1i(program.u_light_count, i32(sam.direction_light_count))

	if sam.direction_light_count > 0 {
		gl.Uniform3fv(program.u_light_positions,   i32(sam.direction_light_count), transmute([^]f32)rawptr(&sam.direction_lights.position))
		gl.Uniform3fv(program.u_light_colors,      i32(sam.direction_light_count), transmute([^]f32)rawptr(&sam.direction_lights.color))
		gl.Uniform1fv(program.u_light_intensities, i32(sam.direction_light_count), transmute([^]f32)rawptr(&sam.direction_lights.intensity))
		gl.Uniform3fv(program.u_light_directions,  i32(sam.direction_light_count), transmute([^]f32)rawptr(&sam.direction_lights.direction))
	}
	
	//the point light

	has_point_light_shadow : [sam.MAX_POINT_LIGHT_COUNT]i32

	for i in u32(0) ..< sam.point_light_count {
		gl.Uniform1f(program.u_point_light_nears[i], sam.point_lights[i].near)
		gl.Uniform1f(program.u_point_light_fars[i], sam.point_lights[i].far)

		unit : i32 = SHADOW_MAP_UNIT_BASE + i32(sam.direction_light_count) + i32(i)
		gl.ActiveTexture(gl.TEXTURE0 + u32(unit))
		tex := sam.point_lights[i].gl_shadow_map_texture
		if tex == 0 do continue

		gl.BindTexture(gl.TEXTURE_CUBE_MAP, tex)
		gl.Uniform1i(program.u_point_light_shadow_maps[i], unit)
		has_point_light_shadow[i] = 1
	}

	for i in int(sam.point_light_count) ..< sam.MAX_POINT_LIGHT_COUNT {
		has_point_light_shadow[i] = 0
		gl.Uniform1i(program.u_point_light_shadow_maps[i], empty_unit)
	}
	
	gl.Uniform1iv(program.u_point_light_has_shadow, sam.MAX_POINT_LIGHT_COUNT, &has_point_light_shadow[0])
	gl.Uniform1i(program.u_point_light_count, i32(sam.point_light_count))

	if sam.point_light_count > 0 {
		gl.Uniform3fv(program.u_point_light_positions,   i32(sam.point_light_count), transmute([^]f32)rawptr(&sam.point_lights.position))
		gl.Uniform3fv(program.u_point_light_colors,      i32(sam.point_light_count), transmute([^]f32)rawptr(&sam.point_lights.color))
		gl.Uniform1fv(program.u_point_light_intensities, i32(sam.point_light_count), transmute([^]f32)rawptr(&sam.point_lights.intensity))
	}
}

CreatePointLightShadowTexture :: proc(id : u32) {
	gl.GenTextures(1, &sam.point_lights[id].gl_shadow_map_texture)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, sam.point_lights[id].gl_shadow_map_texture)
	gl.TexImage2D(
		gl.TEXTURE_CUBE_MAP_POSITIVE_X, 
		0, 
		gl.DEPTH_COMPONENT24, 
		shadow_mapping_program.point_light_resolution_width, 
		shadow_mapping_program.point_light_resolution_height, 
		0, 
		gl.DEPTH_COMPONENT, 
		gl.FLOAT, 
		nil
	)
	gl.TexImage2D(
		gl.TEXTURE_CUBE_MAP_NEGATIVE_X, 
		0, 
		gl.DEPTH_COMPONENT24, 
		shadow_mapping_program.point_light_resolution_width, 
		shadow_mapping_program.point_light_resolution_height, 
		0, 
		gl.DEPTH_COMPONENT, 
		gl.FLOAT, 
		nil
	)
	gl.TexImage2D(
		gl.TEXTURE_CUBE_MAP_POSITIVE_Y, 
		0, 
		gl.DEPTH_COMPONENT24, 
		shadow_mapping_program.point_light_resolution_width, 
		shadow_mapping_program.point_light_resolution_height, 
		0, 
		gl.DEPTH_COMPONENT, 
		gl.FLOAT, 
		nil
	)
	gl.TexImage2D(
		gl.TEXTURE_CUBE_MAP_NEGATIVE_Y, 
		0, 
		gl.DEPTH_COMPONENT24, 
		shadow_mapping_program.point_light_resolution_width, 
		shadow_mapping_program.point_light_resolution_height, 
		0, 
		gl.DEPTH_COMPONENT, 
		gl.FLOAT, 
		nil
	)
	gl.TexImage2D(
		gl.TEXTURE_CUBE_MAP_POSITIVE_Z, 
		0, 
		gl.DEPTH_COMPONENT24, 
		shadow_mapping_program.point_light_resolution_width, 
		shadow_mapping_program.point_light_resolution_height, 
		0, 
		gl.DEPTH_COMPONENT, 
		gl.FLOAT, 
		nil
	)
	gl.TexImage2D(
		gl.TEXTURE_CUBE_MAP_NEGATIVE_Z, 
		0, 
		gl.DEPTH_COMPONENT24, 
		shadow_mapping_program.point_light_resolution_width, 
		shadow_mapping_program.point_light_resolution_height, 
		0, 
		gl.DEPTH_COMPONENT, 
		gl.FLOAT, 
		nil
	)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MIN_FILTER,  gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAG_FILTER,  gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_S,      gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_T,      gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_WRAP_R,      gl.CLAMP_TO_EDGE)   // ← 0x8072
	gl.TexParameteri(gl.TEXTURE_CUBE_MAP, gl.TEXTURE_MAX_LEVEL,   0)

	gl.GenFramebuffers(1, &sam.point_lights[id].gl_shadow_map_fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, sam.point_lights[id].gl_shadow_map_fbo) 
	gl.DrawBuffer(gl.NONE)         // 每个 FBO 都要设
	gl.ReadBuffer(gl.NONE)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

CreateDirectionLightShadowTexture :: proc(id : u32) {
	gl.GenTextures(1, &sam.direction_lights.gl_shadow_map_texture[id])
	gl.BindTexture(gl.TEXTURE_2D, sam.direction_lights.gl_shadow_map_texture[id])
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.DEPTH_COMPONENT24, shadow_mapping_program.direction_light_resolution_width, shadow_mapping_program.direction_light_resolution_height, 0, gl.DEPTH_COMPONENT, gl.FLOAT, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAX_LEVEL, 0)

	gl.GenFramebuffers(1, &sam.direction_lights.gl_shadow_map_fbo[id])
	gl.BindFramebuffer(gl.FRAMEBUFFER, sam.direction_lights.gl_shadow_map_fbo[id])
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D, sam.direction_lights.gl_shadow_map_texture[id], 0)
	gl.DrawBuffer(gl.NONE)
	gl.ReadBuffer(gl.NONE)

	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

RasterizationPointLightShadowMap :: proc(id : u32) {
	gl.BindFramebuffer(gl.FRAMEBUFFER, sam.point_lights[id].gl_shadow_map_fbo)
	gl.Viewport(0, 0, shadow_mapping_program.point_light_resolution_width, shadow_mapping_program.point_light_resolution_height)
	gl.UseProgram(shadow_mapping_program.program)
	
	for face in 0..<6 {
		gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, sam.POINT_LIGHT_FACE_TEXTURE_TARGETS[face], sam.point_lights[id].gl_shadow_map_texture, 0)
		// One face at a time, and this clears exactly the face just attached: a clear
		// reaches only the attachment currently on the framebuffer, so re-attaching
		// before clearing is what keeps the other five faces from being wiped along
		// with it. Measured: attaching +X and clearing leaves -X..-Z untouched.
		gl.Clear(gl.DEPTH_BUFFER_BIT)
		// The matrices were built once in PreComputation. Rebuilding them here would
		// re-measure the scene per node per face, and the whole point of filling the
		// light cameras up front is that this pass only reads.
		light_proj_view := sam.point_lights[id].proj_views[face]
		for node_index in u32(1) ..= sam.nodes.next {
			if !sam.nodes.in_use[node_index] do continue
			node := me.ArrayGet(&sam.nodes, node_index)
			if node == nil do continue
			mesh := me.RefGet(&sam.meshes, node.mesh_id)
			if mesh == nil do continue
			light_mvp := linalg.mul(light_proj_view, node.transform)
			gl.UniformMatrix4fv(shadow_mapping_program.u_light_mvp, 1, false, &light_mvp[0, 0])
			for &p in mesh.primitives {
				gl.BindVertexArray(p.gl_vao_id)
				gl.DrawElements(gl.TRIANGLES, i32(p.indices_count), gl.UNSIGNED_INT, nil)
			}
		}
	}
	
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

RasterizationDirectionLightShadowMap :: proc(id : u32) {
	gl.BindFramebuffer(gl.FRAMEBUFFER, sam.direction_lights.gl_shadow_map_fbo[id])
	gl.Viewport(0, 0, shadow_mapping_program.direction_light_resolution_width, shadow_mapping_program.direction_light_resolution_height)
	gl.Clear(gl.DEPTH_BUFFER_BIT)
	gl.UseProgram(shadow_mapping_program.program)

	light_proj_view := sam.direction_lights[id].proj_view

	for i in u32(1) ..= sam.nodes.next {
		if !sam.nodes.in_use[i] do continue
		node := me.ArrayGet(&sam.nodes, i)
		if node == nil do continue
		mesh := me.RefGet(&sam.meshes, node.mesh_id)
		if mesh == nil do continue
		light_mvp := linalg.mul(light_proj_view, node.transform)
		gl.UniformMatrix4fv(shadow_mapping_program.u_light_mvp, 1, false, &light_mvp[0, 0])
		for &p in mesh.primitives {
			gl.BindVertexArray(p.gl_vao_id)
			gl.DrawElements(gl.TRIANGLES, i32(p.indices_count), gl.UNSIGNED_INT, nil)
		}
	}

	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}
