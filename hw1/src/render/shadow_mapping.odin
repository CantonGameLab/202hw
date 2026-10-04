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

// Publishes every directional light's shadow map and the matrix that indexes it.
//
// The loop covers all of them rather than picking one. A single shadow-casting light
// is a property of the current scene, not of the pipeline, so choosing one here would
// force the rest of the code to agree with an assumption nothing enforces -- and the
// symptom of disagreement is shadows that quietly belong to the wrong light.
//
// Each light keeps its own slot, which is its index in the direction_lights array, so the shader
// can reach the matching map with the loop counter it is already using. That costs
// texture units: one per shadow-casting light, on top of unit 0 for the material. A
// point light is skipped, because one 2D depth map cannot cover the directions a point
// light emits in; it would need a cube map.
//
// Cost: one light view-projection per directional light, once per frame. Not free --
// LightProjViewMat walks every node to fit its box -- so the count matters as the
// scene grows.
// GPU relationship: each map is bound to its own unit and the shader samples it there.
UniformShadowMapping :: proc() {
	gl.UseProgram(program.program)

	has_shadow : [sam.MAX_LIGHT_COUNT]i32

	for i in u32(0) ..< sam.direction_light_count {
		// Position is the eye of the light's orthographic camera and direction is where
		// it looks. Passing the direction twice would put the eye at the origin and aim
		// the light along its own travel vector, which still yields a self-consistent
		// matrix covering the wrong volume.
		light_view_proj := sam.DirectionLightProjViewMat(
			sam.direction_lights.position[i],
			sam.direction_lights.direction[i],
		)

		slot := int(i)
		gl.UniformMatrix4fv(program.u_light_view_projs[slot], 1, false, &light_view_proj[0, 0])

		unit : i32 = SHADOW_MAP_UNIT_BASE + i32(slot)
		gl.ActiveTexture(gl.TEXTURE0 + u32(unit))
		// A light that has not been through CreateShadowTexture has a zero texture name,
		// and binding zero unbinds the unit. GL defines sampling an unbound unit as
		// returning zeros, and a stored depth of 0.0 makes every comparison read as "in
		// shadow", so the whole surface would go dark for a reason that looks nothing
		// like a missing map. This branch reports the slot as unshadowed instead, so the
		// shader never samples it.
		tex := sam.direction_lights.gl_shadow_map_texture[slot]
		if tex == 0 {
			continue
		}

		gl.BindTexture(gl.TEXTURE_2D, tex)
		gl.Uniform1i(program.u_light_shadow_maps[slot], unit)
		has_shadow[slot] = 1
	}

	gl.Uniform1iv(program.u_light_has_shadow, sam.MAX_LIGHT_COUNT, &has_shadow[0])
}

CreatePointLightShadowTexture :: proc(id : u32) {
	gl.GenTextures(1, &sam.point_lights[id].gl_shadow_map_texture)
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, sam.point_lights[id].gl_shadow_map_texture)
	gl.TexImage2D(gl.TEXTURE_CUBE_MAP_POSITIVE_X, 0, gl.DEPTH_COMPONENT24, shadow_mapping_program.point_light_resolution_width, shadow_mapping_program.point_light_resolution_height, 0, gl.DEPTH_COMPONENT, gl.FLOAT, nil)
	gl.TexImage2D(gl.TEXTURE_CUBE_MAP_NEGATIVE_X, 0, gl.DEPTH_COMPONENT24, shadow_mapping_program.point_light_resolution_width, shadow_mapping_program.point_light_resolution_height, 0, gl.DEPTH_COMPONENT, gl.FLOAT, nil)
	gl.TexImage2D(gl.TEXTURE_CUBE_MAP_POSITIVE_Y, 0, gl.DEPTH_COMPONENT24, shadow_mapping_program.point_light_resolution_width, shadow_mapping_program.point_light_resolution_height, 0, gl.DEPTH_COMPONENT, gl.FLOAT, nil)
	gl.TexImage2D(gl.TEXTURE_CUBE_MAP_NEGATIVE_Y, 0, gl.DEPTH_COMPONENT24, shadow_mapping_program.point_light_resolution_width, shadow_mapping_program.point_light_resolution_height, 0, gl.DEPTH_COMPONENT, gl.FLOAT, nil)
	gl.TexImage2D(gl.TEXTURE_CUBE_MAP_POSITIVE_Z, 0, gl.DEPTH_COMPONENT24, shadow_mapping_program.point_light_resolution_width, shadow_mapping_program.point_light_resolution_height, 0, gl.DEPTH_COMPONENT, gl.FLOAT, nil)
	gl.TexImage2D(gl.TEXTURE_CUBE_MAP_NEGATIVE_Z, 0, gl.DEPTH_COMPONENT24, shadow_mapping_program.point_light_resolution_width, shadow_mapping_program.point_light_resolution_height, 0, gl.DEPTH_COMPONENT, gl.FLOAT, nil)
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
	if gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE do fmt.eprintln("Gen ", id, " point light framebuffer failed")
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

CreateDirectionLightShadowTexture :: proc(id : u32) {
	// The field is indexed before its address is taken, never after. direction_lights.gl_x is a
	// real [MAX_LIGHT_COUNT]u32 array in the #soa layout, so indexing it yields a real
	// element to point at. direction_lights[id] is a logical element assembled from one entry of
	// every field array, and no such object exists in memory, so &direction_lights[id].field has
	// no address to give and will not fit a ^u32.
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

	if gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE {
		fmt.eprintln("[x] shadow framebuffer is not complete for light", id)
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		return
	}
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

RasterizationPointLightShadowMap :: proc(id : u32) {
	FACE_TARGET := [6]u32 {
		gl.TEXTURE_CUBE_MAP_POSITIVE_X,   // 0
		gl.TEXTURE_CUBE_MAP_NEGATIVE_X,   // 1
		gl.TEXTURE_CUBE_MAP_POSITIVE_Y,   // 2
		gl.TEXTURE_CUBE_MAP_NEGATIVE_Y,   // 3
		gl.TEXTURE_CUBE_MAP_POSITIVE_Z,   // 4
		gl.TEXTURE_CUBE_MAP_NEGATIVE_Z,   // 5
	}
	
	gl.BindFramebuffer(gl.FRAMEBUFFER, sam.point_lights[id].gl_shadow_map_fbo)
	gl.Viewport(0, 0, shadow_mapping_program.point_light_resolution_width, shadow_mapping_program.point_light_resolution_height)
	gl.UseProgram(shadow_mapping_program.program)
	
	for face in 0..<6 {
		gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, FACE_TARGET[face], sam.point_lights[id].gl_shadow_map_texture, 0)
		gl.Clear(gl.DEPTH_BUFFER_BIT)
		for node_index in u32(1) ..= sam.nodes.next {
			if !sam.nodes.in_use[node_index] do continue
			node := me.ArrayGet(&sam.nodes, node_index)
			if node == nil do continue
			mesh := me.RefGet(&sam.meshes, node.mesh_id)
			if mesh == nil do continue
			light_proj_view := sam.PointLightProjViewMat(sam.point_lights[id].position, face)
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

	light_proj_view := sam.DirectionLightProjViewMat(
		sam.direction_lights.position[id],
		sam.direction_lights.direction[id],
	)

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
