package scene_and_models

import "vendor:cgltf"
import "core:fmt"
import gl "vendor:OpenGL"
import "core:strings"
import "vendor:stb/image"
import "core:c"
import "core:os"
import me "../memory/"

LoadResult :: enum {
	Success,
	ItJustFailed,
	ItIsAWrongGLTFFile,
	ReadImageErr,
	NotFound,
	NoImageSource,
}

LoadaGLTF :: proc(path : string) -> (ret : LoadResult) {
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

	// The .bin has to be mapped in before reading any accessor, otherwise
	// buffer_view_data returns nil (cgltf.h:2601-2605 / :2339-2343 both bail out
	// with return 0 when they cannot get it, silently dropping data).
	// The third argument is the path of the .gltf itself (cgltf.odin:687-690), so
	// this call has to live here -- cpath is only released at the end of this proc.
	buffer_result := cgltf.load_buffers(cgltf.options{}, data, cpath)
	if buffer_result != .success {
		fmt.eprintln("[x] load_buffers failed:", path, " ", buffer_result)
		ret = .ItJustFailed
		return
	}

	//Load the textures

	texture_ids_from_gltf_file_to_the_real_array : []u32 = make([]u32, len(data.textures))
	defer delete(texture_ids_from_gltf_file_to_the_real_array)

	
	for index in 0..<len(data.textures) {
		texture := &data.textures[index]

		if texture.image_ == nil {
			// The spec allows texture.source to be absent, but this project's
			// contract requires every texture to have a source image.
			// Same principle as the Default Material case: a data defect blows up
			// at load time, it does not get dragged into the shipped build.
			fmt.eprintln("[x] texture has no source image (source):", index)
			ret = .NoImageSource
			return
		}
		
		uri := string(texture.image_.uri)

		// Convention: every external file of a glTF sits next to it, and uri must
		// be a bare filename. A separator means the convention is violated (or this
		// glTF wrote its own uri wrong) -- blow up right here, no basename fallback.
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

		// sampler
		mag, min, ws, wt := gl.GL_Enum(gl.LINEAR), gl.GL_Enum(gl.LINEAR), gl.GL_Enum(gl.REPEAT), gl.GL_Enum(gl.REPEAT)

		if texture.sampler != nil {
			mag = gltfFilterMapToGL(texture.sampler.mag_filter)
			min = gltfFilterMapToGL(texture.sampler.min_filter)
			ws = gltfWarpmodeMapToGL(texture.sampler.wrap_s)
			wt = gltfWarpmodeMapToGL(texture.sampler.wrap_t)
		} 
		
		//upload to the GPU
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

		// GL already copied these pixels into VRAM during the TexImage2D above,
		// so this is where the stbi malloc ends.
		// Deliberately here only (not inside readImageFromPath, not deferred): that
		// path has an early return on pixels == nil, and stbi.image_free is just
		// free(), which is meaningless to call on nil.
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
		
		// Map table: glTF texture index -> pool id. Stores what RefLoad returned,
		// not the GL name (the single source of truth for a GPU handle is
		// gl_texture_id inside the textures pool record).
		// WARNING: index+1 must never stand in for this lookup -- textures is a
		// global pool, and on the second LoadaGLTF call RefLoad's next does not
		// restart at 1.
		pool_id := me.RefLoad(&textures, t)

		// RefLoad returns 0 when the pool is full (memory.odin:33).
		// Not checking it silently loses a texture.
		if pool_id == 0 {
			fmt.eprintln("[x] textures pool is full, cannot register:", index)
			ret = .ItJustFailed
			return
		}

		texture_ids_from_gltf_file_to_the_real_array[index] = pool_id

	}

	//Load the materials

	material_ids_from_gltf_file_to_the_real_array : []u32 = make([]u32, len(data.materials))
	defer delete(material_ids_from_gltf_file_to_the_real_array)

	for index in 0..<len(data.materials) {
		m := &data.materials[index]

		// scale is meaningful only on normalTexture / occlusionTexture, spec
		// default 1.0. baseColor / metallicRoughness / emissive have no such
		// concept, so they get overridden with {scale = 0}.
		normal_default := defaultTextureView()
		no_scale_default := TextureView{}
		no_scale_default.scale = 0

		mat := Material {
			normal_texture = readTextureView(&m.normal_texture, texture_ids_from_gltf_file_to_the_real_array, data, normal_default),
			occlusion_texture = readTextureView(&m.occlusion_texture, texture_ids_from_gltf_file_to_the_real_array, data, normal_default),
			emissive_texture = readTextureView(&m.emissive_texture, texture_ids_from_gltf_file_to_the_real_array, data, no_scale_default),

			base_color_texture = readTextureView(&m.pbr_metallic_roughness.base_color_texture, texture_ids_from_gltf_file_to_the_real_array, data, no_scale_default),
			metallic_roughness_texture = readTextureView(&m.pbr_metallic_roughness.metallic_roughness_texture, texture_ids_from_gltf_file_to_the_real_array, data, no_scale_default),

			// cgltf seeds these unconditionally *before* entering the JSON key
			// loop: base_color_factor = 1,1,1,1 (:4570), metallic_factor = 1.0
			// (:4571), roughness_factor = 1.0 (:4572), alpha_cutoff = 0.5 (:4581).
			// So copying them straight across *is* the spec default -- there is
			// nothing to patch up, including the 0.5.
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

	//Load the meshes (and the primitives that strictly belong to them)

	for index in 0..<len(data.meshes) {
		gm := &data.meshes[index]

		prims := make([]Primitive, len(gm.primitives))
		// WARNING: no `defer delete(prims)` here. A defer would also fire at the end
		// of every outer iteration, including the successful one, but on success
		// ownership has already moved to the mesh record => double free.
		// The success path's delete belongs to the mesh's lifetime; each failure
		// path deletes explicitly.

		for pi in 0..<len(gm.primitives) {
			gp := &gm.primitives[pi]

			// The spec allows primitive.material to be absent (default material,
			// 3.9.6); this is a deliberate tightening: a missing material is a
			// defect in the data-production stage and has to blow up at load time,
			// not be dragged into the shipped build.
			if gp.material == nil {
				fmt.eprintln("[x] primitive has no material (spec Default Material is deliberately not implemented here): mesh", index, " prim", pi)
				delete(prims)
				ret = .ItJustFailed
				return
			}

			// Only triangle lists are accepted: DrawElements hardcodes GL_TRIANGLES,
			// so letting a triangle_strip/fan slip through would draw the wrong
			// thing without reporting anything.
			if gp.type != .triangles {
				fmt.eprintln("[x] unsupported primitive topology (triangles only):", gp.type, " mesh", index, " prim", pi)
				delete(prims)
				ret = .ItJustFailed
				return
			}

			// Vertex count comes from POSITION.count. The spec requires every
			// attribute inside one primitive to have the same count, so there is no
			// need to walk the attributes taking a minimum -- a mismatch means the
			// data is broken, it is not a case to be accommodated.
			position_accessor : ^cgltf.accessor
			for a in gp.attributes {
				if a.type == .position {
					position_accessor = a.data
				}
			}

			if position_accessor == nil {
				fmt.eprintln("[x] primitive has no POSITION: mesh", index, " prim", pi)
				delete(prims)
				ret = .ItJustFailed
				return
			}

			vertex_count := position_accessor.count

			// Zero vertices has to be blocked here: every attribute write below
			// takes &vtx[0], and indexing [0] on a zero-length slice panics outright
			// while Odin's default bounds checking is on.
			if vertex_count == 0 {
				fmt.eprintln("[x] primitive has 0 vertices: mesh", index, " prim", pi)
				delete(prims)
				ret = .ItJustFailed
				return
			}

			// The two places that get set to nil after upload are explained below,
			// right after gl.BufferData. Declaring them outside the inner loop body
			// is what lets the early-return paths reach their delete too.
			vtx : []Vertex = make([]Vertex, vertex_count)
			idx : []u32

			// Zero the structs first: POSITION / NORMAL / TANGENT each only own
			// [0..n) of their slot, so the leftover components are never overwritten
			// by writing a full 4 floats (e.g. a vec3 normal only writes xyz).
			// make does not guarantee zeroing, so this step cannot be skipped.
			for i in 0..<vertex_count {
				vtx[i] = Vertex{}
			}

			for a in gp.attributes {
				// The third argument is the component count *mandated by the
				// attribute type*, not accessor.type: POSITION is always 3, NORMAL
				// always 3, TANGENT always 4, TEXCOORD_n always 2.
				#partial switch a.type {
				case .position:
					if !flattenAccessorToVertexAttribute(&vtx[0].position[0], a.data, vertex_count, 3) {
						fmt.eprintln("[x] attribute flatten failed POSITION: mesh", index, " prim", pi)
						delete(vtx)
						delete(prims)
						ret = .ItJustFailed
						return
					}
				case .normal:
					if !flattenAccessorToVertexAttribute(&vtx[0].normal[0], a.data, vertex_count, 3) {
						fmt.eprintln("[x] attribute flatten failed NORMAL: mesh", index, " prim", pi)
						delete(vtx)
						delete(prims)
						ret = .ItJustFailed
						return
					}
				case .tangent:
					if !flattenAccessorToVertexAttribute(&vtx[0].tangent[0], a.data, vertex_count, 4) {
						fmt.eprintln("[x] attribute flatten failed TANGENT: mesh", index, " prim", pi)
						delete(vtx)
						delete(prims)
						ret = .ItJustFailed
						return
					}
				case .texcoord:
					// Vertex carries only two UV sets, so TEXCOORD_2 and above have
					// nowhere to go. Not dropped silently: dropping them means the
					// shader reads all-zero UVs and the surface comes out flat coloured.
					if a.index == 0 {
						if !flattenAccessorToVertexAttribute(&vtx[0].uv0[0], a.data, vertex_count, 2) {
							fmt.eprintln("[x] attribute flatten failed TEXCOORD_0: mesh", index, " prim", pi)
							delete(vtx)
							delete(prims)
							ret = .ItJustFailed
							return
						}
					} else if a.index == 1 {
						if !flattenAccessorToVertexAttribute(&vtx[0].uv1[0], a.data, vertex_count, 2) {
							fmt.eprintln("[x] attribute flatten failed TEXCOORD_1: mesh", index, " prim", pi)
							delete(vtx)
							delete(prims)
							ret = .ItJustFailed
							return
						}
					} else {
						fmt.eprintln("[x] TEXCOORD_", a.index, " out of range (Vertex holds only two UV sets): mesh", index, " prim", pi)
						delete(vtx)
						delete(prims)
						ret = .ItJustFailed
						return
					}
				}
			}
			// COLOR_0 / JOINTS_0 / WEIGHTS_0 fall into the switch's empty branch
			// and are skipped silently.

			if gp.indices == nil {
				fmt.eprintln("[x] primitive has no indices (only indexed draw is supported here): mesh", index, " prim", pi)
				delete(vtx)
				delete(prims)
				ret = .ItJustFailed
				return
			}

			// out_component_size is pinned to 4: a u16 source gets widened to u32
			// (cgltf.h:2614-2618, the padding branch), so a single UNSIGNED_INT
			// DrawElements path covers both assets with no branching on type.
			// NOTE: the out == nil "query mode" returns accessor->count, so treating
			// anything non-zero as success without comparing would allocate an index
			// array that is entirely zero.
			if cgltf.accessor_unpack_indices(gp.indices, nil, 4, 0) != gp.indices.count {
				fmt.eprintln("[x] accessor_unpack_indices query failed: mesh", index, " prim", pi)
				delete(vtx)
				delete(prims)
				ret = .ItJustFailed
				return
			}

			index_count := gp.indices.count

			if index_count == 0 || index_count % 3 != 0 {
				fmt.eprintln("[x] index count is not a multiple of 3 (triangle list):", index_count, " mesh", index, " prim", pi)
				delete(vtx)
				delete(prims)
				ret = .ItJustFailed
				return
			}

			idx = make([]u32, index_count)

			// Conversion failure (sparse accessor, or a component wider than u32)
			// returns 0. This has to be checked, otherwise what gets drawn is an
			// all-zero index buffer -- every triangle being vertex #0, with no error.
			if cgltf.accessor_unpack_indices(gp.indices, rawptr(&idx[0]), 4, index_count) != index_count {
				fmt.eprintln("[x] accessor_unpack_indices failed (sparse or over-wide component): mesh", index, " prim", pi)
				delete(vtx)
				delete(idx)
				delete(prims)
				ret = .ItJustFailed
				return
			}

			p := Primitive {
				material_id = material_ids_from_gltf_file_to_the_real_array[cgltf.material_index(data, gp.material)],
			}

			gl.GenVertexArrays(1, &p.gl_vao_id)
			gl.GenBuffers(1, &p.gl_vbo_id)
			gl.GenBuffers(1, &p.gl_ebo_id)

			gl.BindVertexArray(p.gl_vao_id)

			gl.BindBuffer(gl.ARRAY_BUFFER, p.gl_vbo_id)
			gl.BufferData(gl.ARRAY_BUFFER, len(vtx) * size_of(Vertex), raw_data(vtx), gl.STATIC_DRAW)

			gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, p.gl_ebo_id)
			gl.BufferData(gl.ELEMENT_ARRAY_BUFFER, len(idx) * size_of(u32), raw_data(idx), gl.STATIC_DRAW)

			// The locations come from Vertex's field offsets; 0/12/24/40/48 are never
			// hand-written. A hand-written offset that drifts still compiles and GL
			// still reports nothing -- the model just comes out silently skewed.
			vertexAttribOffset(0, 3, offset_of(Vertex, position))
			vertexAttribOffset(1, 3, offset_of(Vertex, normal))
			vertexAttribOffset(2, 4, offset_of(Vertex, tangent))
			vertexAttribOffset(3, 2, offset_of(Vertex, uv0))
			vertexAttribOffset(4, 2, offset_of(Vertex, uv1))

			gl.BindVertexArray(0)

			// Option (a): a static VBO is never re-uploaded, so the CPU copy has no
			// consumer at all.
			// NOTE: the nil assignment below is a self-reference inside the same loop
			// body -- the mesh record receives the slice *value* (an independent
			// handle onto the same backing array), this delete is that array's only
			// release point, and nobody reads them after it.
			delete(vtx)
			delete(idx)

			p.vertexs = nil
			p.indices = nil

			prims[pi] = p
		}

		mesh := Mesh {
			primitives = prims,
		}

		pool_id := me.RefLoad(&meshes, mesh)
		if pool_id == 0 {
			fmt.eprintln("[x] meshes pool is full, cannot register:", index)
			// Pool-full happens *before* ownership transfer, so this path has to
			// release it itself.
			delete(mesh.primitives)
			ret = .ItJustFailed
			return
		}
		// Ownership of prims has moved into the mesh record; it must not be deleted
		// here -- the mesh's lifetime owns that.
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

	// cgltf's alpha_mode only has opaque/mask/blend (the binding does not expose
	// the C header's max_enum), and its zero value = opaque = the spec default,
	// which maps one-to-one onto this project's AlphaMode.
	gltfAlphaModeToMine :: proc(m : cgltf.alpha_mode) -> AlphaMode {
		#partial switch m {
		case .mask:
			return .Mask
		case .blend:
			return .Blend
		}
		return .Opaque
	}

	// The *semantic* value of a default TextureView, not the zero value. scale is
	// meaningful only for normal/occlusion, its spec default is 1.0, and cgltf does
	// not seed this field (it hands back 0.0 when absent) -- the consequence of
	// forgetting it is completely flat normals and completely inert occlusion,
	// reported by nothing. baseColor / metallicRoughness / emissive have no such
	// semantics, and the caller overrides them with {scale = 0}.
	defaultTextureView :: proc() -> TextureView {
		return TextureView {
			texture_id = 0,
			texcoord = 0,
			scale = 1.0,
		}
	}

	// Why cgltf's tv.scale is not copied across: that one field carries both the
	// normal's scale and the occlusion's strength, and it is *not seeded*, so when
	// absent it is 0.0 rather than the spec default of 1.0. Hence the caller-supplied
	// default_view.scale is used instead.
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
		return v
	}

	// The vertex attribute layout inside the VBO is a *version-coupled contract*:
	// adding one field to Vertex makes the five offset_of calls below drift with it.
	// The offsets must be computed by the compiler (offset_of); 0/12/24/40/48 are
	// never hand-written -- a hand-written skew still compiles and GL still reports
	// nothing, and the model just comes out silently skewed.
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

	// Flatten an accessor's packed data into one column of the interleaved vertex
	// array, laid out the way the target expects.
	//
	// accessor_unpack_floats is called per element rather than unpacking in bulk:
	// bulk would turn "planar attribute layout" into "planar attribute arrays plus
	// one more copy". coast_line alone is 720k vertices across the two assets, i.e.
	// a 9 MB intermediate array per attribute, and not one step of that is
	// avoidable -- the source and target element pitches simply differ, and cgltf's
	// fast memcpy path (cgltf.h:2346-2349) requires stride == ncomp * 4, which only
	// holds for a whole-array read.
	//
	// component_count comes from the *attribute type* (POSITION is always 3,
	// TANGENT always 4, ...), not from accessor.type: that way a source accessor
	// written too wide cannot overrun the target field.
	flattenAccessorToVertexAttribute :: proc(
		first_column : ^f32,
		acc : ^cgltf.accessor,
		vertex_count : uint,
		component_count : uint,
	) -> bool {
		if acc == nil {
			return false
		}

		// Only non-normalized float32 is accepted. A normalized integer attribute
		// (an r_8u normal, say, which is legal glTF) gets normalized into
		// [-1,1]/[0,1] by cgltf_element_read_float, and the byte-wise copy below
		// would not -- it would silently write 0..255 garbage. Better to fail here
		// than to produce wrong geometry.
		if acc.component_type != .r_32f || acc.normalized {
			return false
		}

		if acc.count != vertex_count {
			return false
		}

		row_stride := int(size_of(Vertex))
		for i in 0 ..< vertex_count {
			dst := rawptr(uintptr(rawptr(first_column)) + uintptr(i) * uintptr(row_stride))
			if cgltf.accessor_unpack_floats(acc, transmute([^]f32)dst, component_count) != component_count {
				return false
			}
		}

		return true
	}
}
