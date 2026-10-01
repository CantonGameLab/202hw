package scene

import "vendor:cgltf"
import "core:fmt"
import gl "vendor:OpenGL"
import "core:strings"
import "vendor:stb/image"
import "core:c"
import "core:os"
import "core:math/linalg"
import me "../memory/"

LoadResult :: enum {
	Success,
	ItJustFailed,
	ItIsAWrongGLTFFile,
	ReadImageErr,
	NotFound,
	NoImageSource,
}


// Loads a glTF into the pools and returns the pool id of the one Mesh it built.
// Reads the .gltf and its .bin, decodes every image the scene actually uses, and
// copies all geometry to the GPU. Once per file, not per frame.
//
// One glTF file == one Mesh. A file with two or more glTF meshes is rejected, not
// merged: each mesh carries its own node transforms and a Mesh record has nowhere
// to put them.
//
// The returned id is NOT retained -- nothing inside the load owns the result, so
// the caller retains it once itself.
//
// GPU: one texture object plus a full mip chain per used image, and one
// VAO/VBO/EBO triple per renderable node. The handles land in
// Texture.gl_texture_id and Primitive.gl_vao_id / gl_vbo_id / gl_ebo_id, and the
// loader frees the CPU-side copies as soon as they are uploaded.
LoadAGLTFToAMesh :: proc(path : string) -> (mesh_id : u32, ret : LoadResult) {
	cpath := strings.clone_to_cstring(path)
	defer delete(cpath)
	data, result := cgltf.parse_file(cgltf.options{},cpath)

	if result != .success {
		#partial switch result {
		
		case .data_too_short:
		case .invalid_json:
		case .invalid_options:
		case .invalid_gltf:
		case .unknown_format:
			ret = .ItIsAWrongGLTFFile
			fmt.eprintln("So we just can't load the file:", path, " So it is a wrong file.")
		case .file_not_found:
			ret = .NotFound
			fmt.eprintln("We don't even find the file from the path:", path)
		case .io_error:
		case .out_of_memory:
		case .legacy_gltf:
			ret = .ItJustFailed
			fmt.eprintln("It just failed to load a gltf:", path, "Go play other games like the Counter-Strike 2, Valve just upgraded it")

		}
		return
	}

	defer cgltf.free(data)

	buffer_result := cgltf.load_buffers(cgltf.options{}, data, cpath)
	if buffer_result != .success {
		fmt.eprintln("[x] load_buffers failed:", path, " ", buffer_result)
		ret = .ItJustFailed
		return
	}

	if len(data.meshes) != 1 {
		fmt.eprintln("[x] glTF does not have exactly one mesh (this loader is one-glTF-one-Mesh):",
			len(data.meshes), "meshes in", path)
		ret = .ItJustFailed
		return
	}

	texture_ids_from_gltf_file_to_the_real_array := make([]u32, len(data.textures))
	material_ids_from_gltf_file_to_the_real_array := make([]u32, len(data.materials))

	texture_is_referenced := make([]b8, len(data.textures))
	material_is_used := make([]b8, len(data.materials))

	defer delete(texture_ids_from_gltf_file_to_the_real_array)
	defer delete(material_ids_from_gltf_file_to_the_real_array)
	defer delete(texture_is_referenced)
	defer delete(material_is_used)

	for index in 0..<len(data.materials) {
		if materialIsUsedByTheScene(data, &data.materials[index]) {
			material_is_used[index] = true
		}
	}

	for index in 0..<len(data.materials) {
		if !material_is_used[index] {
			continue
		}
		for tv in materialTextureViews(&data.materials[index]) {
			if tv.texture != nil {
				texture_is_referenced[cgltf.texture_index(data, tv.texture)] = true
			}
		}
	}

	for index in 0..<len(data.textures) {

		if !texture_is_referenced[index] {
			continue
		}

		texture := &data.textures[index]

		if texture.image_ == nil {
			fmt.eprintln("[x] texture has no source image (source):", index)
			ret = .NoImageSource
			return
		}
		
		uri := string(texture.image_.uri)

		// External files must sit next to the .gltf, and uri must be a bare
		// filename. No basename fallback: a fallback silently picks the wrong file
		// when two directories both contain it.
		if hasSeparator(uri) {
			fmt.eprintln("[x] uri contains a directory separator, violating the same-directory convention:", uri)
			ret = .NotFound
			return
		}

		filename := basename(uri)
		full := strings.concatenate({gltfDir(path), filename})

		pixels, w, h, ok := readImageFromPath(full, 4)

		if !ok {
			fmt.eprintln("fail to load the image from the path:", full)
			delete(full)
			ret = .ReadImageErr
			return
		}

		delete(full)

		mag, min, ws, wt := gl.GL_Enum(gl.LINEAR), gl.GL_Enum(gl.LINEAR), gl.GL_Enum(gl.REPEAT), gl.GL_Enum(gl.REPEAT)

		if texture.sampler != nil {
			mag = gltfFilterMapToGL(texture.sampler.mag_filter)
			min = gltfFilterMapToGL(texture.sampler.min_filter)
			ws = gltfWarpmodeMapToGL(texture.sampler.wrap_s)
			wt = gltfWarpmodeMapToGL(texture.sampler.wrap_t)
		} 
		
		texture_id : u32
		gl.GenTextures(1, &texture_id)
		gl.BindTexture(gl.TEXTURE_2D, texture_id)
		gl.PixelStorei(gl.UNPACK_ALIGNMENT, 4)
		gl.TexImage2D(gl.TEXTURE_2D, 0, i32(gl.RGBA8), i32(w), i32(h), 0, gl.RGBA, gl.UNSIGNED_BYTE, rawptr(pixels))
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, i32(u32(mag)))
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, i32(u32(min)))
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, i32(u32(ws)))
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, i32(u32(wt)))

		if needAMipmap(min) {
			gl.GenerateMipmap(gl.TEXTURE_2D)
		}

		// GL copied the pixels into VRAM during TexImage2D, so the stbi allocation
		// ends here.
		image.image_free(rawptr(pixels))

		t := Texture {
			pixels = nil,
			gl_texture_id = texture_id,
			width = w,
			height = h,
			mag_filter = mag,
			min_filter = min,
			wrap_s = ws,
			wrap_t = wt,
		}
		
		// Table entry: glTF texture index -> pool id. Never index + 1 -- RefLoad
		// does not restart numbering between files, so arithmetic would silently
		// point a second file at the first file's textures.
		pool_id := me.RefLoad(&textures, t)

		if pool_id == 0 {
			fmt.eprintln("[x] textures pool is full, cannot register:", index)
			ret = .ItJustFailed
			return
		}

		texture_ids_from_gltf_file_to_the_real_array[index] = pool_id

	}

	//Load the materials

	for index in 0..<len(data.materials) {
		if !material_is_used[index] {
			continue
		}

		m := &data.materials[index]

		normal_default := defaultTextureView()
		no_scale_default := TextureView{}
		no_scale_default.scale = 0

		mat := Material {
			normal_texture = readTextureView(&m.normal_texture, texture_ids_from_gltf_file_to_the_real_array, data, normal_default),
			occlusion_texture = readTextureView(&m.occlusion_texture, texture_ids_from_gltf_file_to_the_real_array, data, normal_default),
			emissive_texture = readTextureView(&m.emissive_texture, texture_ids_from_gltf_file_to_the_real_array, data, no_scale_default),

			base_color_texture = readTextureView(&m.pbr_metallic_roughness.base_color_texture, texture_ids_from_gltf_file_to_the_real_array, data, no_scale_default),
			metallic_roughness_texture = readTextureView(&m.pbr_metallic_roughness.metallic_roughness_texture, texture_ids_from_gltf_file_to_the_real_array, data, no_scale_default),

			// cgltf seeds these to the spec defaults before it reads the JSON, so
			// copying them straight across is correct -- including alpha_cutoff 0.5.
			base_color_factor = m.pbr_metallic_roughness.base_color_factor,
			metallic_factor = m.pbr_metallic_roughness.metallic_factor,
			roughness_factor = m.pbr_metallic_roughness.roughness_factor,
			emissive_factor = m.emissive_factor,
			alpha_cutoff = m.alpha_cutoff,
			alpha_mode = gltfAlphaModeToMine(m.alpha_mode),
			double_sided = b8(m.double_sided),
		}

		pool_id := me.RefLoad(&materials, mat)
		if pool_id == 0 {
			fmt.eprintln("[x] materials pool is full, cannot register:", index)
			ret = .ItJustFailed
			return
		}

		material_ids_from_gltf_file_to_the_real_array[index] = pool_id
	}

	// Mesh pass. Primitive generation and the node walk are one pass: a Primitive
	// comes from a node, and since they all end up in a single Mesh record, a
	// Walks from the scene roots, not flat over data.nodes, so a node no scene
	// references cannot take a slot.

	if len(data.scenes) == 0 {
		fmt.eprintln("[x] glTF has no scene, so nothing is reachable:", path)
		ret = .ItJustFailed
		return
	}
	if len(data.scenes[0].nodes) == 0 {
		fmt.eprintln("[x] glTF scene has no root node, so nothing is reachable:", path)
		ret = .ItJustFailed
		return
	}

	prims := make([dynamic]Primitive)

	for root in data.scenes[0].nodes {
		loadNodeRecursive(data, root, &prims, material_ids_from_gltf_file_to_the_real_array)
	}

	// Counts what a renderable scene had to produce, so a node that quietly
	// appended nothing becomes a load failure instead of a half-built model.
	expected_prims := 0
	{
		stack := make([dynamic]^cgltf.node)
		defer delete(stack)

		for r in data.scenes[0].nodes {
			append(&stack, r)
		}

		for len(stack) > 0 {
			n := pop(&stack)
			if n.mesh != nil {
				expected_prims += 1
			}
			for c in n.children {
				append(&stack, c)
			}
		}
	}

	if len(prims) != expected_prims {
		fmt.eprintln("[x] primitive count mismatch: expected", expected_prims, "got", len(prims), ":", path)
		delete(prims)
		ret = .ItJustFailed
		return
	}

	if len(prims) == 0 {
		fmt.eprintln("[x] the glTF scene produced no renderable primitive:", path)
		delete(prims)
		ret = .ItJustFailed
		return
	}

	mesh := Mesh {
		primitives = prims[:],
	}

	mesh_id = me.RefLoad(&meshes, mesh)
	if mesh_id == 0 {
		fmt.eprintln("[x] meshes pool is full, cannot register:", path)
		// Pool-full happens *before* ownership transfer, so this path has to release
		// the backing array itself.
		delete(mesh.primitives)
		ret = .ItJustFailed
		return
	}

	// Releases anything this file loaded that nothing ended up holding. Meshes are
	// exempt: the returned id is legitimately unretained at this instant.
	for index in 0..<len(data.textures) {
		id := texture_ids_from_gltf_file_to_the_real_array[index]
		if id == 0 || me.Ref(&textures, id) != 0 {
			continue
		}
		if !UnloadTexture(id) {
			fmt.eprintln("[x] sweep could not unload an unreferenced texture, pool id:", id)
			continue
		}
		texture_ids_from_gltf_file_to_the_real_array[index] = 0
	}

	for index in 0..<len(data.materials) {
		id := material_ids_from_gltf_file_to_the_real_array[index]
		if id == 0 || me.Ref(&materials, id) != 0 {
			continue
		}
		if !UnloadMaterial(id) {
			fmt.eprintln("[x] sweep could not unload an unreferenced material, pool id:", id)
			continue
		}
		material_ids_from_gltf_file_to_the_real_array[index] = 0
	}

	return //So this proc is end but other may dont

	readImageFromPath :: proc(path : string, preferred_channel : i32) -> (pixels : [^]byte, w, h : u32, ok : b8) {
		encoded, err := os.read_entire_file_from_path(path, context.allocator)
		if err != nil {
			fmt.eprintln("[x] fail to read the image file:", path, " ",  os.error_string(err))
			return
		}
		defer delete(encoded)
		cw, ch, channel : c.int
		pixels = image.load_from_memory(raw_data(encoded), c.int(len(encoded)), &cw, &ch, &channel, c.int(preferred_channel))

		if pixels == nil {
			fmt.println("Load a pixels err:", path)
			return
		}

		w = u32(cw)
		h = u32(ch)
		ok = true
		return
	}

	gltfDir :: proc(gltf_path : string) -> string {
		for i := len(gltf_path) - 1; i >= 0; i -= 1 {
			if gltf_path[i] == '/' || gltf_path[i] == '\\' {
				return gltf_path[:i + 1]
			}
		}
		return ""
	}

	// The five texture slots a material can carry.
	materialTextureViews :: proc(m : ^cgltf.material) -> [5]^cgltf.texture_view {
		return {
			&m.normal_texture,
			&m.occlusion_texture,
			&m.emissive_texture,
			&m.pbr_metallic_roughness.base_color_texture,
			&m.pbr_metallic_roughness.metallic_roughness_texture,
		}
	}

	// Does a primitive this loader will actually build reference this material?
	// Walks from the scene roots, the same set the mesh pass walks.
	//
	// Compares material pointers rather than using cgltf.material_index: a missing
	// "material" key means material == nil, and that index function asserts on nil
	// (cgltf.h:2491), which with asserts off becomes a garbage index. A pre-scan
	// visits every entry of data.materials, so it is the one place that can meet a
	// nil.
	materialIsUsedByTheScene :: proc(data : ^cgltf.data, target : ^cgltf.material) -> bool {
		stack := make([dynamic]^cgltf.node)
		defer delete(stack)

		for root in data.scenes[0].nodes {
			append(&stack, root)
		}

		for len(stack) > 0 {
			n := pop(&stack)
			if n.mesh != nil {
				for &gp in n.mesh.primitives {
					if gp.material == target {
						return true
					}
				}
			}
			for c in n.children {
				append(&stack, c)
			}
		}

		return false
	}
	
	basename :: proc(p : string) -> string {
		for i := len(p) - 1; i >= 0; i -= 1 {
			if p[i] == '/' || p[i] == '\\' {
				return p[i + 1:]
			}
		}
		return p

	}

	hasSeparator :: proc(p : string) -> bool {
		for i in 0 ..< len(p) {
			if p[i] == '/' || p[i] == '\\' {
				return true
			}
		}
		return false
	}

	gltfFilterMapToGL :: proc(f : cgltf.filter_type) -> gl.GL_Enum{
		#partial switch f {
		case .nearest:
			return gl.GL_Enum(gl.NEAREST)
		case .linear:
			return gl.GL_Enum(gl.LINEAR)
		case .nearest_mipmap_nearest:
			return gl.GL_Enum(gl.NEAREST_MIPMAP_NEAREST)
		case .linear_mipmap_linear:
			return gl.GL_Enum(gl.LINEAR_MIPMAP_LINEAR)
		case .nearest_mipmap_linear:
			return gl.GL_Enum(gl.NEAREST_MIPMAP_LINEAR)
		case .linear_mipmap_nearest:
			return gl.GL_Enum(gl.LINEAR_MIPMAP_NEAREST)
		}
		return gl.GL_Enum(gl.LINEAR)
	}

	gltfWarpmodeMapToGL :: proc(w : cgltf.wrap_mode) -> gl.GL_Enum {
		#partial switch w {
		case .clamp_to_edge:
			return gl.GL_Enum(gl.CLAMP_TO_EDGE)
		case .mirrored_repeat:
			return gl.GL_Enum(gl.MIRRORED_REPEAT)
		case .repeat:
			return gl.GL_Enum(gl.REPEAT)
		}

		return gl.GL_Enum(gl.REPEAT)
	}

	needAMipmap :: proc(f : gl.GL_Enum) -> b8 {
		#partial switch f {
		case gl.GL_Enum(gl.NEAREST_MIPMAP_LINEAR),
			 gl.GL_Enum(gl.LINEAR_MIPMAP_LINEAR),
			 gl.GL_Enum(gl.NEAREST_MIPMAP_NEAREST),
			 gl.GL_Enum(gl.LINEAR_MIPMAP_NEAREST):
			return true
		}

		return false
	}

	// cgltf's alpha_mode zero value is opaque, which is the spec default and maps
	// one-to-one onto this project's AlphaMode.
	gltfAlphaModeToMine :: proc(m : cgltf.alpha_mode) -> AlphaMode {
		#partial switch m {
		case .mask:
			return .Mask
		case .blend:
			return .Blend
		}
		return .Opaque
	}

	// scale 1.0 is the spec default for normal/occlusion, and cgltf does not seed
	// it, so leaving it 0.0 gives flat normals and inert occlusion with nothing
	// reported. baseColor / metallicRoughness / emissive have no such field and the
	// caller overrides those with {scale = 0}.
	defaultTextureView :: proc() -> TextureView {
		return TextureView {
			texture_id = 0,
			texcoord = 0,
			scale = 1.0,
		}
	}

	// Resolves one material slot to a texture pool id and retains it -- one retain
	// per edge, so a texture used by two slots ends up at refs == 2. No GPU work
	// here; the texture object already exists by the time a material is built.
	//
	// tv.scale is not copied: cgltf does not seed it, so an absent scale reads 0.0
	// instead of 1.0, and the caller's default_view carries the right value.
	readTextureView :: proc(
		tv : ^cgltf.texture_view,
		tex_map : []u32,
		data : ^cgltf.data,
		default_view : TextureView,
	) -> TextureView {
		if tv.texture == nil {
			return default_view
		}

		v := default_view
		v.texture_id = tex_map[cgltf.texture_index(data, tv.texture)]
		v.texcoord = i32(tv.texcoord)

		// Hold the id, so retain the id. One retain per edge.
		if v.texture_id != 0 {
			if !me.RefRetain(&textures, v.texture_id) {
				fmt.eprintln("[x] failed to retain texture while building a material, texture pool id:", v.texture_id)
			}
		}

		return v
	}

	// Describes one vertex attribute to the currently bound VAO. The offsets must
	// come from offset_of: a hand-written skew still compiles and GL still reports
	// nothing, the model just comes out silently skewed.
	vertexAttribOffset :: proc(location : u32, component_count : i32, offset_bytes : uintptr) {
		gl.EnableVertexAttribArray(location)
		gl.VertexAttribPointer(
			location,
			component_count,
			gl.FLOAT,
			false,
			i32(size_of(Vertex)),
			offset_bytes,
		)
	}

	// Copies one accessor into one column of the interleaved vertex array. No GPU
	// work here -- this writes the CPU staging buffer that a later BufferData
	// uploads.
	//
	// accessor_unpack_floats parses a WHOLE accessor in one call: its third
	// argument is the total float count, and every call restarts at element 0.
	// Passing the component count once per element therefore writes element 0 to
	// every destination, which was measured as 9746 identical vertices, a
	// zero-area AABB, and a mesh that rasterises nothing. So it is called exactly
	// once and the packed result is then scattered into the interleaved rows.
	//
	// The staging buffer is one accessor's worth of floats -- 39 KB for
	// marble_bust, about 8.7 MB for coast_line's POSITION -- and is freed on every
	// exit. One allocation per attribute, not one per element.
	//
	// component_count comes from the attribute type (POSITION is always 3, TANGENT
	// always 4), not from accessor.type, so a source accessor written too wide
	// cannot overrun the target field.
	flattenAccessorToVertexAttribute :: proc(
		first_column : ^f32,
		acc : ^cgltf.accessor,
		vertex_count : uint,
		component_count : uint,
	) -> bool {
		if acc == nil {
			return false
		}

		// Only non-normalized float32. A normalized integer attribute (a legal glTF
		// r_8u normal, say) would be normalized by cgltf into [-1,1] but copied
		// byte-wise here as 0..255 garbage, so it is refused instead.
		if acc.component_type != .r_32f || acc.normalized {
			return false
		}

		if acc.count != vertex_count {
			return false
		}

		total := vertex_count * component_count
		packed := make([]f32, total)
		defer delete(packed)

		// Parse first, scatter second: a failure here leaves the target untouched
		// instead of partially written.
		if cgltf.accessor_unpack_floats(acc, raw_data(packed), total) != total {
			return false
		}

		row_stride := int(size_of(Vertex))
		for i in 0 ..< int(vertex_count) {
			dst := transmute([^]f32)rawptr(
				uintptr(rawptr(first_column)) + uintptr(i * row_stride))
			for c in 0 ..< int(component_count) {
				dst[c] = packed[i * int(component_count) + c]
			}
		}

		return true
	}

	// Walks one node and its children, appending one Primitive per mesh-carrying
	// node. Vertices are copied out exactly as the file stores them: no node
	// transform is applied anywhere.
	//
	// material_ids arrives as a parameter because an Odin nested proc cannot read
	// an outer proc's locals (measured: "Undeclared name"). The table is a local of
	// the loader regardless.
	loadNodeRecursive :: proc(
		data : ^cgltf.data,
		node : ^cgltf.node,
		prims : ^[dynamic]Primitive,
		material_ids : []u32,
	) {

		if node.mesh != nil {
			gm := node.mesh

			if len(gm.primitives) == 0 {
				fmt.eprintln("[x] node's mesh has no primitive at all:", string(node.name))
				return
			}

			// One glTF mesh does not imply one primitive. More than one would need
			// per-primitive world transforms, which a flat Mesh record cannot hold.
			if len(gm.primitives) != 1 {
				fmt.eprintln("[x] glTF mesh has", len(gm.primitives),
					"primitives; exactly 1 is supported (one glTF == one Mesh == one Primitive per node)")
				return
			}

			gp := &gm.primitives[0]

			// The spec allows primitive.material to be absent and falls back to a
			// Default Material (3.9.6). Deliberately not implemented: a missing
			// material is a defect in the data, and it has to blow up here rather
			// than reach a shipped build.
			if gp.material == nil {
				fmt.eprintln("[x] primitive has no material (spec Default Material is deliberately not implemented here):", string(node.name))
				return
			}

			// Only triangle lists: the draw call hardcodes GL_TRIANGLES, so a strip or
			// fan would be drawn wrong with nothing reported.
			if gp.type != .triangles {
				fmt.eprintln("[x] unsupported primitive topology (triangles only):", gp.type, string(node.name))
				return
			}

			// Vertex count comes from POSITION.count: the spec requires every
			// attribute of a primitive to agree on it, so a mismatch is broken data,
			// not a case to accommodate.
			position_accessor : ^cgltf.accessor
			for a in gp.attributes {
				if a.type == .position {
					position_accessor = a.data
				}
			}

			if position_accessor == nil {
				fmt.eprintln("[x] primitive has no POSITION:", string(node.name))
				return
			}

			vertex_count := position_accessor.count

			if vertex_count == 0 {
				fmt.eprintln("[x] primitive has 0 vertices:", string(node.name))
				return
			}

			vtx : []Vertex = make([]Vertex, vertex_count)
			idx : []u32

			for i in 0..<vertex_count {
				vtx[i] = Vertex{}
			}

			for a in gp.attributes {
				#partial switch a.type {
				case .position:
					if !flattenAccessorToVertexAttribute(&vtx[0].position[0], a.data, vertex_count, 3) {
						fmt.eprintln("[x] attribute flatten failed POSITION:", string(node.name))
						delete(vtx)
						return
					}
				case .normal:
					if !flattenAccessorToVertexAttribute(&vtx[0].normal[0], a.data, vertex_count, 3) {
						fmt.eprintln("[x] attribute flatten failed NORMAL:", string(node.name))
						delete(vtx)
						return
					}
				case .tangent:
					if !flattenAccessorToVertexAttribute(&vtx[0].tangent[0], a.data, vertex_count, 4) {
						fmt.eprintln("[x] attribute flatten failed TANGENT:", string(node.name))
						delete(vtx)
						return
					}
				case .texcoord:
					// Vertex holds two UV sets. TEXCOORD_2 and up are refused rather
					// than dropped, because dropping means the shader samples all-zero
					// UVs and the surface comes out flat coloured.
					if a.index == 0 {
						if !flattenAccessorToVertexAttribute(&vtx[0].uv0[0], a.data, vertex_count, 2) {
							fmt.eprintln("[x] attribute flatten failed TEXCOORD_0:", string(node.name))
							delete(vtx)
							return
						}
					} else if a.index == 1 {
						if !flattenAccessorToVertexAttribute(&vtx[0].uv1[0], a.data, vertex_count, 2) {
							fmt.eprintln("[x] attribute flatten failed TEXCOORD_1:", string(node.name))
							delete(vtx)
							return
						}
					} else {
						fmt.eprintln("[x] TEXCOORD_", a.index, " out of range (Vertex holds only two UV sets):", string(node.name))
						delete(vtx)
						return
					}
				}
			}


			if gp.indices == nil {
				fmt.eprintln("[x] primitive has no indices (only indexed draw is supported here):", string(node.name))
				delete(vtx)
				return
			}

			// Widen to 4-byte indices, so one UNSIGNED_INT draw path covers every
			// asset with no branching on the source component type.
			//
			// Both calls are checked: the first is cgltf's "query mode" (out == nil),
			// which returns the accessor count without validating anything, and the
			// second is the real conversion, which returns 0 on a sparse accessor or
			// an over-wide component. An unchecked conversion draws an all-zero index
			// buffer -- every triangle being vertex #0 -- with no error.
			if cgltf.accessor_unpack_indices(gp.indices, nil, 4, 0) != gp.indices.count {
				fmt.eprintln("[x] accessor_unpack_indices query failed:", string(node.name))
				delete(vtx)
				return
			}

			index_count := gp.indices.count

			if index_count == 0 || index_count % 3 != 0 {
				fmt.eprintln("[x] index count is not a multiple of 3 (triangle list):", index_count, string(node.name))
				delete(vtx)
				return
			}

			idx = make([]u32, index_count)

			if cgltf.accessor_unpack_indices(gp.indices, rawptr(&idx[0]), 4, index_count) != index_count {
				fmt.eprintln("[x] accessor_unpack_indices failed (sparse or over-wide component):", string(node.name))
				delete(vtx)
				delete(idx)
				return
			}

			material_id := material_ids[cgltf.material_index(data, gp.material)]

			if material_id == 0 {
				fmt.eprintln("[x] primitive points at a material that was never loaded:", string(node.name))
				delete(vtx)
				delete(idx)
				return
			}

			p := Primitive {
				indices_count = u32(index_count),
				material_id = material_id,
			}

			// One retain per primitive: each primitive is its own edge to its material,
			// which is what makes releasing per primitive the exact inverse.
			if !me.RefRetain(&materials, material_id) {
				fmt.eprintln("[x] failed to retain material while building a primitive, material pool id:", material_id)
				delete(vtx)
				delete(idx)
				return
			}

			gl.GenVertexArrays(1, &p.gl_vao_id)
			gl.GenBuffers(1, &p.gl_vbo_id)
			gl.GenBuffers(1, &p.gl_ebo_id)

			gl.BindVertexArray(p.gl_vao_id)

			gl.BindBuffer(gl.ARRAY_BUFFER, p.gl_vbo_id)
			gl.BufferData(gl.ARRAY_BUFFER, len(vtx) * size_of(Vertex), raw_data(vtx), gl.STATIC_DRAW)

			gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, p.gl_ebo_id)
			gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, len(idx) * size_of(u32), raw_data(idx), gl.STATIC_DRAW)

			// Offsets come from Vertex's field offsets; never hand-written.
			vertexAttribOffset(0, 3, offset_of(Vertex, position))
			vertexAttribOffset(1, 3, offset_of(Vertex, normal))
			vertexAttribOffset(2, 4, offset_of(Vertex, tangent))
			vertexAttribOffset(3, 2, offset_of(Vertex, uv0))
			vertexAttribOffset(4, 2, offset_of(Vertex, uv1))

			gl.BindVertexArray(0)

			// A static VBO is never re-uploaded, so the CPU copies have no consumer
			// once the upload above returns. The record keeps only the three GL names.
			delete(vtx)
			delete(idx)

			p.vertexs = nil
			p.indices = nil

			append(prims, p)
		}

		if len(node.children) == 0 {
			return
		}

		for child in node.children {
			loadNodeRecursive(data, child, prims, material_ids)
		}
	}
}

// Takes ownership of a mesh id the loader produced (the loader returns it
// unretained). Retain, then release through the normal path so it lands on exactly
// one owner without a second ownership rule.
RetainMesh :: proc(id : u32) -> (ret : b8) {
	mesh := me.RefGet(&meshes, id)
	if mesh == nil {
		return false
	}
	if !me.RefRetain(&meshes, id) {
		return false
	}
	return true
}

UnretainMesh :: proc(id : u32) -> (ret : b8) {
	mesh := me.RefGet(&meshes, id)
	if mesh == nil {
		return false
	}
	me.RefUnretain(&meshes, id)
	if me.Ref(&meshes, id) <= 0 {
		if !UnloadMesh(id) {
			fmt.eprintln("UnloadMesh fail!:", id)
		}
	}
	return true
}

UnloadMesh :: proc(id : u32) -> (ret : b8) {
	mesh := me.RefGet(&meshes, id)
	if mesh == nil {
		return false
	}
	for &p in mesh.primitives {
		delete(p.vertexs)
		delete(p.indices)
		gl.DeleteVertexArrays(1, &p.gl_vao_id)
		gl.DeleteBuffers(1, &p.gl_vbo_id)
		gl.DeleteBuffers(1, &p.gl_ebo_id)
		UnretainMaterial(p.material_id)
	}
	
	delete(mesh.primitives)
	me.RefUnload(&meshes, id)
	return true
}

UnretainTexture :: proc(id : u32) -> (ret : b8) {
	texture := me.RefGet(&textures, id)
	if texture == nil {
		return false
	}
	me.RefUnretain(&textures, id)
	if me.Ref(&textures, id) <= 0 {
		if !UnloadTexture(id) {
			fmt.eprintln("UnloadTexture fail!:", id)
		}
	}
	return true
}


UnloadTexture :: proc(id : u32) -> (ret : b8) {
	texture := me.RefGet(&textures, id)
	if texture == nil {
		return false
	}
	gl.DeleteTextures(1, &texture.gl_texture_id)
	me.RefUnload(&textures, id)
	return true
}

UnretainMaterial :: proc(id : u32) -> (ret : b8) {
	material := me.RefGet(&materials, id)
	if material == nil {
		return false
	}
	me.RefUnretain(&materials, id)
	if me.Ref(&materials, id) <= 0 {
		if !UnloadMaterial(id) {
			fmt.eprintln("UnloadMaterial fail!:", id)
		}
	}
	return true
}

UnloadMaterial :: proc(id : u32) -> (ret : b8) {
	material := me.RefGet(&materials, id)
	if material == nil {
		return false
	}
	UnretainTexture(material.normal_texture.texture_id)
	UnretainTexture(material.occlusion_texture.texture_id)
	UnretainTexture(material.emissive_texture.texture_id)
	UnretainTexture(material.base_color_texture.texture_id)
	UnretainTexture(material.metallic_roughness_texture.texture_id)
	me.RefUnload(&materials, id)
	return true
}
