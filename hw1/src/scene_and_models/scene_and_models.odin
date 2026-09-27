package scene_and_models

import "vendor:cgltf"
import "core:fmt"
import gl "vendor:OpenGL"
import me "../memory/"


TextureTransform :: struct {
	offset : [2]f32,
	rotation : f32,
	scale : [2]f32,
	has_texcoord : b8,
	texcoord : i32,
}

Transform :: struct {
	matrix_ : matrix[4,4]f16
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

TextureView :: struct {

	texture_id : u32,
	texcoord : i32,
	scale : f32,
	has_texture_transform : b8,
	texture_transform : TextureTransform,
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

	has_pbr : b8,
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
	transform : Transform,
	father_id : u32,
	son_ids : [dynamic]u32,
}

MAX_NODE_COUNT :: 2000
MAX_MESH_COUNT :: 10000
MAX_TEXTURE_COUNT :: 10000
MAX_MATERIAL_COUNT :: 10000

nodes : me.RefCounted(MAX_NODE_COUNT, Node)

meshes : me.RefCounted(MAX_MESH_COUNT, Mesh)

textures : me.RefCounted(MAX_TEXTURE_COUNT, Texture)

materials : me.RefCounted(MAX_MATERIAL_COUNT, Material)

