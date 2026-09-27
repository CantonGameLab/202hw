package scene_and_models

import "vendor:cgltf"
import "core:fmt"
import gl "vendor:OpenGL"
import me "../memory/"


Transform :: struct {
	matrix_ : matrix[4,4]f32
}


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

	gl_vbo_id : u32,
	gl_vao_id : u32,
	gl_ebo_id : u32,
	material_id : u32,
}

Mesh :: struct {
	primitives : []Primitive,
}

Node :: struct {
	mesh_id : u32,
	transform : Transform, //there is no the suck NODE TREE. It is evil for any game developer otherwise you are A masochism
}

MAX_NODE_COUNT :: 2000
MAX_MESH_COUNT :: 10000
MAX_TEXTURE_COUNT :: 10000
MAX_MATERIAL_COUNT :: 10000

meshes : me.RefCounted(MAX_MESH_COUNT, Mesh)
textures : me.RefCounted(MAX_TEXTURE_COUNT, Texture)
materials : me.RefCounted(MAX_MATERIAL_COUNT, Material)


