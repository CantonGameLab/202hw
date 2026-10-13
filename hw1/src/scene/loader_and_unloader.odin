package scene

import "vendor:cgltf"
import "core:fmt"
import gl "vendor:OpenGL"
import "core:strings"
import "core:slice"
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


// Loads a whole glTF scene into the pools and hands the caller one Node per
// drawable glTF node. Reads the .gltf and its .bin, decodes every image the scene
// actually uses, and copies all geometry to the GPU. Once per file, not per frame.
//
// One glTF mesh == one Mesh record, no matter how many nodes reference it: the
// geometry is unpacked and uploaded once and the record is shared, because a Mesh
// record already counts its references. A mesh no reachable node names is never
// built at all, so its geometry never reaches the GPU.
//
// Nodes arrive as an array of Nodes, one per node that carries a mesh. The node
// tree is NOT preserved: each node's transform is the baked global transform
// (parent to child), and a node that carries no mesh contributes nothing but its
// transform to its descendants. Nodes are appended in depth-first order, so a
// child follows its parent. The array indexes do not line up with the file's own
// `nodes` array.
//
// Nothing here retains: the array is a passing value and the ids in it are
// unheld handles, so whoever installs a node into the pools retains it once
// itself. The caller owns the array and deletes it.
//
// GPU: one texture object plus a full mip chain per used image, and one
// VAO/VBO/EBO triple per primitive. The handles land in
// Texture.gl_texture_id and Primitive.gl_vao_id / gl_vbo_id / gl_ebo_id, and the
// loader frees the CPU-side copies as soon as they are uploaded.
//
// A failure reports itself and returns; the pools are left holding whatever the
// load had already put there.
LoadglTFScene :: proc(path : string, out : ^[]Node) -> (ret : LoadResult) {
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

	// The default scene, which is the one the file says to show. `data.scene` stays
	// nil when the file does not name one -- cgltf does not fall back to the first
	// entry -- so the fallback is here.
	if len(data.scenes) == 0 {
		fmt.eprintln("[x] glTF has no scene, so nothing is reachable:", path)
		ret = .ItJustFailed
		return
	}

	scene_ := data.scene
	if scene_ == nil {
		scene_ = &data.scenes[0]
	}

	if len(scene_.nodes) == 0 {
		fmt.eprintln("[x] glTF scene has no root node, so nothing is reachable:", path)
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
			emissive_strength = m.has_emissive_strength ? m.emissive_strength.emissive_strength : 1.0,
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

	// Mesh pass. One Mesh record per glTF mesh the scene can reach, and one
	// Primitive per primitive of that mesh. Flat over data.meshes, not over the
	// node walk, because the same mesh is one record however many nodes name it.

	mesh_is_used := make([]b8, len(data.meshes))
	mesh_ids_from_gltf_file_to_the_real_array := make([]u32, len(data.meshes))

	defer delete(mesh_is_used)
	defer delete(mesh_ids_from_gltf_file_to_the_real_array)

	for index in 0..<len(data.meshes) {
		if meshIsUsedByTheScene(data, &data.meshes[index]) {
			mesh_is_used[index] = true
		}
	}

	for index in 0..<len(data.meshes) {
		if !mesh_is_used[index] {
			continue
		}
		if !buildMesh(data, &data.meshes[index], mesh_ids_from_gltf_file_to_the_real_array, material_ids_from_gltf_file_to_the_real_array) {
			ret = .ItJustFailed
			return
		}
	}

	// Node walk. Parent transform into child, so each Node carries the global
	// transform and the tree itself never leaves this proc.
	loaded_nodes : [dynamic]Node
	for root in scene_.nodes {
		appendSceneNodes(data, root, &loaded_nodes, mesh_ids_from_gltf_file_to_the_real_array)
	}

	if len(loaded_nodes) == 0 {
		fmt.eprintln("[x] the glTF scene produced no renderable node:", path)
		delete(loaded_nodes)
		ret = .ItJustFailed
		return
	}

	// The caller owns the array now. Handed over whole -- length equal to capacity
	// -- because a sliced-forever array has lost the size the allocator frees it by.
	out^ = loaded_nodes[:]

	// Releases anything this file loaded that nothing ended up holding. The meshes
	// the returned nodes name are still at zero references at this instant, and
	// that is correct: the caller retains each one as it installs it.
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

	return

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
	// Every mesh the scene can reach is scanned, because a material is reachable
	// through any of them.
	//
	// Compares material pointers rather than using cgltf.material_index: a missing
	// "material" key means material == nil, and that index function asserts on nil
	// (cgltf.h:2489), which with asserts off becomes a garbage index. A pre-scan
	// visits every entry of data.materials, so it is the one place that can meet a
	// nil.
	materialIsUsedByTheScene :: proc(data : ^cgltf.data, target : ^cgltf.material) -> bool {
		for &gm in data.meshes {
			for &gp in gm.primitives {
				if gp.material == target {
					return true
				}
			}
		}

		return false
	}

	// Is this mesh named by a node the scene can reach? A mesh nothing names is
	// never built, so its geometry never reaches the GPU.
	meshIsUsedByTheScene :: proc(data : ^cgltf.data, target : ^cgltf.mesh) -> bool {
		stack := make([dynamic]^cgltf.node)
		defer delete(stack)

		for root in data.scenes[0].nodes {
			append(&stack, root)
		}

		for len(stack) > 0 {
			n := pop(&stack)
			if n.mesh == target {
				return true
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
	// The primitive's local bounding box, with no transform applied: it is relative
	// to the node's own space, which is where the vertex positions live.
	//
	// The accessor's min/max is used when the file carries it, because that is the
	// exporter's own answer and costs nothing to read. The spec requires POSITION to
	// declare both, but has_min/has_max are separate flags from the arrays -- which
	// are [16]f32 shared by scalar through vec4 -- so an asset that omits them is
	// possible and would otherwise hand back an all-zero box that looks like a real
	// answer. A zero box culls everything it belongs to, silently, so the missing
	// case recomputes from the staged vertices instead of trusting the arrays.
	//
	// local_min/local_max is the box before the node's transform. Turning it into a
	// world box needs all eight corners transformed, not just these two points:
	// after a rotation the old extremes are no longer the extremes.
	//
	// Cost: zero for the accessor path. The fallback walks every staged vertex once,
	// which for marble_bust is 9746 iterations against a load that already decoded
	// 448 MB of textures.
	flattenAccessorToAABB :: proc(
		acc : ^cgltf.accessor,
		vtx : []Vertex,
		local_min, local_max : ^[3]f32,
	) -> bool {
		if acc == nil || len(vtx) == 0 {
			return false
		}

		if acc.has_min && acc.has_max {
			local_min^ = {acc.min[0], acc.min[1], acc.min[2]}
			local_max^ = {acc.max[0], acc.max[1], acc.max[2]}
			return true
		}

		lo := [3]f32{max(f32), max(f32), max(f32)}
		hi := [3]f32{-max(f32), -max(f32), -max(f32)}
		for v in vtx {
			lo = {min(lo.x, v.position.x), min(lo.y, v.position.y), min(lo.z, v.position.z)}
			hi = {max(hi.x, v.position.x), max(hi.y, v.position.y), max(hi.z, v.position.z)}
		}
		local_min^ = lo
		local_max^ = hi
		return true
	}

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
	appendSceneNodes :: proc(
		data : ^cgltf.data,
		root : ^cgltf.node,
		out : ^[dynamic]Node,
		mesh_ids : []u32,
	) {
		stack := make([dynamic]^cgltf.node)
		defer delete(stack)

		append(&stack, root)

		for len(stack) > 0 {
			n := pop(&stack)

			if n.mesh != nil {
				mesh_index := cgltf.mesh_index(data, n.mesh)
				mesh_id := mesh_ids[mesh_index]

				// A mesh-carrying node always has a mesh_id: the mesh pass above
				// refused to continue otherwise. Checked anyway, because a zero here
				// would put an unretainable handle into the array the caller installs
				// from.
				if mesh_id == 0 {
					fmt.eprintln("[x] node names a mesh that was never loaded:", string(n.name))
					continue
				}

				// The global transform, so a child node arrives in the same space the
				// render path already draws (it uses node.transform as m_model directly).
				world : Transform
				cgltf.node_transform_world(n, &world[0, 0])

				// A value, not a pool slot. The node pool belongs to whoever installs
				// these, and taking a slot here would spend one twice per node: once
				// for this passing record and once for the real one the installer
				// creates, leaving an unreachable node drawing the same mesh.
				append(out, Node {
					mesh_id = mesh_id,
					transform = world,
				})
			}

			for child in n.children {
				append(&stack, child)
			}
		}
	}

	// Builds one Primitive: attributes staged, indices widened, VAO/VBO/EBO created
	// and the CPU copies released. Returns false on anything it cannot build, having
	// already reported why.
	buildMeshPrimitive :: proc(
		data : ^cgltf.data,
		name : string,
		gp : ^cgltf.primitive,
		material_ids : []u32,
		p : ^Primitive,
		mesh_aabb : ^AABB,
	) -> bool {

		// The spec allows primitive.material to be absent and falls back to a
		// Default Material (3.9.6). Deliberately not implemented: a missing
		// material is a defect in the data, and it has to blow up here rather
		// than reach a shipped build.
		if gp.material == nil {
			fmt.eprintln("[x] primitive has no material (spec Default Material is deliberately not implemented here):", name)
			return false
		}

		// Only triangle lists: the draw call hardcodes GL_TRIANGLES, so a strip or
		// fan would be drawn wrong with nothing reported.
		if gp.type != .triangles {
			fmt.eprintln("[x] unsupported primitive topology (triangles only):", gp.type, name)
			return false
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
			fmt.eprintln("[x] primitive has no POSITION:", name)
			return false
		}

		vertex_count := position_accessor.count

		if vertex_count == 0 {
			fmt.eprintln("[x] primitive has 0 vertices:", name)
			return false
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
					fmt.eprintln("[x] attribute flatten failed POSITION:", name)
					delete(vtx)
					return false
				}
				// Read or derive this primitive's local box here, while the staged
				// positions are still alive, and fold it into the mesh's. Every
				// failure exit that deletes vtx sits below this point, so reaching it
				// means the positions are known good.
				prim_min, prim_max : [3]f32
				if !flattenAccessorToAABB(a.data, vtx, &prim_min, &prim_max) {
					fmt.eprintln("[x] could not determine the bounding box:", name)
					delete(vtx)
					return false
				}
				mesh_aabb.minmax_offset_x = {
					min(mesh_aabb.minmax_offset_x[0], prim_min.x),
					max(mesh_aabb.minmax_offset_x[1], prim_max.x),
				}
				mesh_aabb.minmax_offset_y = {
					min(mesh_aabb.minmax_offset_y[0], prim_min.y),
					max(mesh_aabb.minmax_offset_y[1], prim_max.y),
				}
				mesh_aabb.minmax_offset_z = {
					min(mesh_aabb.minmax_offset_z[0], prim_min.z),
					max(mesh_aabb.minmax_offset_z[1], prim_max.z),
				}
			case .normal:
				if !flattenAccessorToVertexAttribute(&vtx[0].normal[0], a.data, vertex_count, 3) {
					fmt.eprintln("[x] attribute flatten failed NORMAL:", name)
					delete(vtx)
					return false
				}
			case .tangent:
				if !flattenAccessorToVertexAttribute(&vtx[0].tangent[0], a.data, vertex_count, 4) {
					fmt.eprintln("[x] attribute flatten failed TANGENT:", name)
					delete(vtx)
					return false
				}
			case .texcoord:
				// Vertex holds two UV sets. TEXCOORD_2 and up are refused rather
				// than dropped, because dropping means the shader samples all-zero
				// UVs and the surface comes out flat coloured.
				if a.index == 0 {
					if !flattenAccessorToVertexAttribute(&vtx[0].uv0[0], a.data, vertex_count, 2) {
						fmt.eprintln("[x] attribute flatten failed TEXCOORD_0:", name)
						delete(vtx)
						return false
					}
				} else if a.index == 1 {
					if !flattenAccessorToVertexAttribute(&vtx[0].uv1[0], a.data, vertex_count, 2) {
						fmt.eprintln("[x] attribute flatten failed TEXCOORD_1:", name)
						delete(vtx)
						return false
					}
				} else {
					fmt.eprintln("[x] TEXCOORD_", a.index, " out of range (Vertex holds only two UV sets):", name)
					delete(vtx)
					return false
				}
			}
		}


		if gp.indices == nil {
			fmt.eprintln("[x] primitive has no indices (only indexed draw is supported here):", name)
			delete(vtx)
			return false
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
			fmt.eprintln("[x] accessor_unpack_indices query failed:", name)
			delete(vtx)
			return false
		}

		index_count := gp.indices.count

		if index_count == 0 || index_count % 3 != 0 {
			fmt.eprintln("[x] index count is not a multiple of 3 (triangle list):", index_count, name)
			delete(vtx)
			return false
		}

		idx = make([]u32, index_count)

		if cgltf.accessor_unpack_indices(gp.indices, rawptr(&idx[0]), 4, index_count) != index_count {
			fmt.eprintln("[x] accessor_unpack_indices failed (sparse or over-wide component):", name)
			delete(vtx)
			delete(idx)
			return false
		}

		material_id := material_ids[cgltf.material_index(data, gp.material)]

		if material_id == 0 {
			fmt.eprintln("[x] primitive points at a material that was never loaded:", name)
			delete(vtx)
			delete(idx)
			return false
		}

		p.indices_count = u32(index_count)
		p.material_id = material_id

		// One retain per primitive: each primitive is its own edge to its material,
		// which is what makes releasing per primitive the exact inverse.
		if !me.RefRetain(&materials, material_id) {
			fmt.eprintln("[x] failed to retain material while building a primitive, material pool id:", material_id)
			delete(vtx)
			delete(idx)
			return false
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

		return true
	}

	// Builds one Mesh record from one glTF mesh: every primitive of that mesh, in
	// order, and no node transform anywhere -- a Mesh record holds geometry in the
	// mesh's own space and each node supplies its own transform.
	//
	// The box is deliberately the mesh-local box: turning it into a world box is
	// GetSceneAABB's job, which transforms all eight corners by the node's own
	// transform. Folding a node transform in here would apply it twice.
	buildMesh :: proc(
		data : ^cgltf.data,
		gm : ^cgltf.mesh,
		mesh_ids : []u32,
		material_ids : []u32,
	) -> bool {
		if len(gm.primitives) == 0 {
			fmt.eprintln("[x] glTF mesh has no primitive at all:", string(gm.name))
			return false
		}

		// Seeded to the inverted extremes so the first primitive expands it into a
		// real box with no special case.
		mesh_aabb : AABB
		mesh_aabb.minmax_offset_x = {max(f32), -max(f32)}
		mesh_aabb.minmax_offset_y = {max(f32), -max(f32)}
		mesh_aabb.minmax_offset_z = {max(f32), -max(f32)}

		prims := make([dynamic]Primitive)
		defer delete(prims)

		for &gp in gm.primitives {
			p : Primitive
			if !buildMeshPrimitive(data, string(gm.name), &gp, material_ids, &p, &mesh_aabb) {
				return false
			}
			append(&prims, p)
		}

		// The dynamic array's own storage becomes the record's storage, so it must
		// NOT be freed on the way out: a slice is a pointer, and the pool entry
		// outlives this proc. Only a failed RefLoad frees it, below.
		mesh := Mesh {
			primitives = prims[:],
			aabb = mesh_aabb,
		}

		mesh_id := me.RefLoad(&meshes, mesh)
		if mesh_id == 0 {
			fmt.eprintln("[x] meshes pool is full, cannot register:", string(gm.name))
			delete(mesh.primitives)
			return false
		}

		mesh_ids[cgltf.mesh_index(data, gm)] = mesh_id

		// Ownership of the primitive array went into the pool entry, so the deferred
		// delete above must not take it back.
		prims = nil

		return true
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
