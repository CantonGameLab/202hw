package scene

import "vendor:cgltf"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import gl "vendor:OpenGL"
import me "../memory/"

MAX_NODE_COUNT :: 2000
MAX_MESH_COUNT :: 10000
MAX_TEXTURE_COUNT :: 10000
MAX_MATERIAL_COUNT :: 10000
Transform :: matrix[4,4]f32

Texture :: struct {
	pixels : []u8,
	gl_texture_id : u32,
	width : u32,
	height : u32,
	mag_filter : gl.GL_Enum,
	min_filter : gl.GL_Enum,
	wrap_s : gl.GL_Enum,
	wrap_t : gl.GL_Enum,
}

// This project's own enum, deliberately not cgltf.alpha_mode.
// Zero value = Opaque = the spec default (schema: "default": "OPAQUE"),
// so Material{} is a safe empty state.
AlphaMode :: enum {
	Opaque,
	Mask,
	Blend,
}

TextureView :: struct {
	texture_id : u32,   // 0 = this slot has no texture (RefLoad hands out ids from 1, so 0 is naturally empty)
	texcoord   : i32,   // which UV set to use (the n in TEXCOORD_n)
	scale      : f32,   // meaningful only for normalTexture(scale) / occlusionTexture(strength); spec default 1.0
}

PBRMaterial :: struct {
	base_color_texture : TextureView,
	metallic_roughness_texture : TextureView,
	base_color_factor : [4]f32,
	metallic_factor : f32,
	roughness_factor : f32,
}

Material :: struct {
	normal_texture : TextureView,
	occlusion_texture : TextureView,
	emissive_texture : TextureView,
	emissive_factor : [3]f32,

	alpha_mode : AlphaMode,
	alpha_cutoff : f32,
	double_sided : b8,

	// glTF's material.pbrMetallicRoughness is *optional*, and when it is omitted
	// every default value applies; baseColorFactor and friends physically live
	// inside it, so "is this PBR?" is not a question that can be asked.
	// => there is no has_pbr flag.
	using pbr : PBRMaterial,
}

Vertex :: struct {
	position : [3]f32,
	normal : [3]f32,
	tangent : [4]f32,
	uv0 : [2]f32,
	uv1 : [2]f32,
}

Primitive :: struct {
	vertexs : []Vertex, //if it needs
	indices : []u32, //if it needs
	indices_count : u32,

	gl_vbo_id : u32,
	gl_vao_id : u32,
	gl_ebo_id : u32,
	material_id : u32,
}

Mesh :: struct {
	primitives : []Primitive,
	aabb : AABB,
}

Node :: struct {
	mesh_id : u32,
	transform : Transform, //Node tree actually suck. It is evil for any game developer otherwise you are A masochism
}

meshes : me.RefCounted(MAX_MESH_COUNT, Mesh)
textures : me.RefCounted(MAX_TEXTURE_COUNT, Texture)
materials : me.RefCounted(MAX_MATERIAL_COUNT, Material)
nodes : me.Array(MAX_NODE_COUNT, Node)

PreComputation :: proc() {
	world := GetSceneAABB(linalg.MATRIX4F32_IDENTITY)

	for i in u32(0) ..< direction_light_count {

		dir := linalg.normalize(direction_lights.direction[i])
		up := abs(dir.y) > 0.99 ? [3]f32{0, 0, 1} : [3]f32{0, 1, 0}
		view := linalg.matrix4_look_at_f32(direction_lights.position[i], direction_lights.position[i] + dir, up)

		s := GetSceneAABB(view)
		half_xy := max(
			max(abs(s.minmax_offset_x[0]), abs(s.minmax_offset_x[1])),
			max(abs(s.minmax_offset_y[0]), abs(s.minmax_offset_y[1])),
		)

		direction_lights[i].half_extent = half_xy
		direction_lights[i].near = s.minmax_offset_z[1]
		direction_lights[i].far = s.minmax_offset_z[0]

		direction_lights[i].fov_y = 0
		direction_lights[i].proj_view = DirectionLightProjViewMat(
			direction_lights[i].position,
			dir,
			half_xy,
			s.minmax_offset_z[1],
			s.minmax_offset_z[0],
		)
	}

	for i in u32(0) ..< point_light_count {
		// One depth range for all six faces, measured from the world box. Measuring it
		// per face would give six ranges, and a stored depth from one face would then
		// be compared against another face's scale.
		z_near, z_far := PointLightDepthRange(point_lights[i].position, world)

		point_lights[i].near = z_near
		point_lights[i].far = z_far
		// 90 degrees square is the cube map's own geometry, not a choice, so it is
		// recorded rather than configured.
		point_lights[i].fov_y = math.PI * 0.5

		for face in 0 ..< 6 {
			point_lights[i].proj_views[face] = PointLightProjViewMat(
				point_lights[i].position,
				face,
				z_near,
				z_far,
			)
		}
	}
}
