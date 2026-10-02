package render

import gl "vendor:OpenGL"
import "core:fmt"
import sam "../scene"
import me "../memory"
import "core:math/linalg"

ShadowMappingProgram :: struct {
	program : u32,
	resolution_width : i32,
	resolution_height : i32,
	u_light_mvp : i32,
}

shadow_mapping_program : ShadowMappingProgram

CreateShadowTexture :: proc(light : ^sam.Light) {
	gl.GenTextures(1, &light.gl_shadow_map_texture)
	gl.BindTexture(gl.TEXTURE_2D, light.gl_shadow_map_texture)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.DEPTH_COMPONENT24, shadow_mapping_program.resolution_width, shadow_mapping_program.resolution_height, 0, gl.DEPTH_COMPONENT, gl.FLOAT, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAX_LEVEL, 0)

	gl.GenFramebuffers(1, &light.gl_shadow_map_fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, light.gl_shadow_map_fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D, light.gl_shadow_map_texture, 0)
	gl.DrawBuffer(gl.NONE)
	gl.ReadBuffer(gl.NONE)

	if gl.CheckFramebufferStatus(gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE {
		fmt.eprintln("gen gl shadow mapping frame buffer error!")
		return
	}
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

RasterizationShadowMap :: proc(light : ^sam.Light) {
	gl.BindFramebuffer(gl.FRAMEBUFFER, light.gl_shadow_map_fbo)
	gl.Viewport(0, 0, shadow_mapping_program.resolution_width, shadow_mapping_program.resolution_height)
	gl.Clear(gl.DEPTH_BUFFER_BIT)
	gl.UseProgram(shadow_mapping_program.program)
	
	light_proj_view := sam.LightProjViewMat(light.direction, light.direction)
	
	for i := u32(1); i <= sam.nodes.next; i += 1 {
		if !sam.nodes.in_use[i] do continue
		node := me.ArrayGet(&sam.nodes, i)
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
