package pl

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:math/linalg"
import s3 "vendor:sdl3"
import gl "vendor:OpenGL"

import render "../../src/render"
import scene "../../src/scene"
import entity "../../src/entity"

OUT_W :: 1920
OUT_H :: 1080

ARG_USAGE :: `usage: pl <mode>
  mode = real   run the project's own Render, screenshot the window
  mode = probe  load every source variant, render to an offscreen target, dump numbers`

Frame_State :: struct {
	before : u32,
	during : u32,
	after : u32,
	clear_color : [4]f32,
}

// The report is written to a text file rather than to stdout: the previous session's
// logs came back as zero-byte files or as binary, so nothing is left to the console that
// a pipe could mangle.
Reporter :: struct {
	file : ^os.File,
}

rep_open :: proc(path : string) -> Reporter {
	f, err := os.create(path)
	if err != nil {
		fmt.eprintln("[x] cannot create the report:", path, err)
		os.exit(1)
	}
	return Reporter{file = f}
}

rep_line :: proc(r : Reporter, args : ..any) {
	fmt.fprintln(r.file, ..args)
	os.flush(r.file)
}

rep_close :: proc(r : Reporter) {
	os.close(r.file)
}

flush_errors :: proc() -> u32 {
	first : u32 = 0
	for {
		e := gl.GetError()
		if e == gl.NO_ERROR do break
		if first == 0 do first = e
	}
	return first
}

err_name :: proc(e : u32) -> string {
	switch e {
	case gl.NO_ERROR: return "NO_ERROR"
	case gl.INVALID_ENUM: return "INVALID_ENUM 0x500"
	case gl.INVALID_VALUE: return "INVALID_VALUE 0x501"
	case gl.INVALID_OPERATION: return "INVALID_OPERATION 0x502"
	case gl.INVALID_FRAMEBUFFER_OPERATION: return "INVALID_FRAMEBUFFER_OPERATION 0x506"
	case gl.OUT_OF_MEMORY: return "OUT_OF_MEMORY 0x505"
	}
	return fmt.tprintf("0x%X", e)
}

// Returns a copy that owns its storage. Handing back a string built over the slice that
// read_entire_file allocated -- and then freeing that slice -- leaves the text pointing at
// recycled memory, and the driver compiles whatever took its place.
read_owned_source :: proc(path : string) -> (src : string, ok : bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		fmt.eprintln("[x] cannot read", path)
		return "", false
	}
	defer delete(data)
	return strings.clone(string(data), context.allocator), true
}

// Mirrors vendor:OpenGL's own compile_shader_from_source: the source pointer and an
// explicit length, no cstring conversion and no reliance on a NUL. The length is what the
// GL spec actually reads (it stops at a NUL only when length is negative), so handing it
// over removes both the conversion and the "is the text still alive" question.
compile_from :: proc(kind : u32, src : string, tag : string) -> u32 {
	dump_text(
		fmt.tprintf("_probe/pl/out/enter_%s.txt", tag),
		fmt.tprintf("len=%d\nhead=<%s>\n", len(src), src[:min(len(src), 50)]),
	)
	sh := gl.CreateShader(kind)
	length := i32(len(src))
	text := cstring(raw_data(src))
	gl.ShaderSource(sh, 1, &text, &length)
	gl.CompileShader(sh)
	status : i32
	gl.GetShaderiv(sh, gl.COMPILE_STATUS, &status)
	if status == 0 {
		buf : [8192]byte
		gl.GetShaderInfoLog(sh, i32(len(buf)), nil, &buf[0])
		// The log and the source both go to files. Console output from these runs has
		// come back wrapped, truncated and unescaped before now, and a compile log that
		// is missing its first line is worse than no log.
		dump_text(fmt.tprintf("_probe/pl/out/fail_%s.log", tag), string(buf[:]))
		dump_text(fmt.tprintf("_probe/pl/out/fail_%s.src.glsl", tag), src)
		fmt.eprintln("[x] COMPILE FAILED", tag, len(src), string(buf[:]))
		gl.DeleteShader(sh)
		return 0
	}
	return sh
}

dump_text :: proc(path, text : string) {
	write_file(path, slice.to_bytes(transmute([]u8)text))
}

// Writes the whole slice, looping while the stream takes only part of it.
//
// A single os.write returns the count it transferred, and this platform's file stream
// stops at 1 MiB per call. One call per image therefore writes a fifth of a 1080p frame and
// reports success, which is how a broken capture looks exactly like a working one: the file
// exists, it has pixels in it, and the bottom four fifths of every picture is missing.
write_all :: proc(f : ^os.File, data : []u8) -> (total : int) {
	for total < len(data) {
		n, err := os.write(f, data[total:])
		if err != nil || n <= 0 do break
		total += n
	}
	if total != len(data) {
		fmt.eprintln("[!] short write:", total, "of", len(data))
	}
	return
}

// The same, to a path, with the file created and closed around it.
write_file :: proc(path : string, data : []u8) {
	f, err := os.create(path)
	if err != nil {
		fmt.eprintln("[x] cannot create", path)
		return
	}
	defer os.close(f)
	write_all(f, data)
}

link_from :: proc(vs, fs : u32, tag : string) -> u32 {
	p := gl.CreateProgram()
	gl.AttachShader(p, vs)
	gl.AttachShader(p, fs)
	gl.LinkProgram(p)
	status : i32
	gl.GetProgramiv(p, gl.LINK_STATUS, &status)
	if status == 0 {
		buf : [8192]byte
		gl.GetProgramInfoLog(p, i32(len(buf)), nil, &buf[0])
		fmt.eprintln("[x] LINK FAILED", tag, string(buf[:]))
		gl.DeleteProgram(p)
		return 0
	}
	return p
}

// The upload the project performs, written so it can be pointed at a program the harness
// compiled itself. Every location is fetched here rather than borrowed from the project's
// shadow_mapping_program, because that record is filled in from the wrong program object.
bind_point_light_shadow :: proc(p : u32, unit : i32, cube : u32) {
	gl.UseProgram(p)
	loc := gl.GetUniformLocation(p, cstring("u_point_light_shadow_maps[0]"))
	gl.Uniform1i(loc, unit)
	gl.ActiveTexture(gl.TEXTURE0 + u32(unit))
	gl.BindTexture(gl.TEXTURE_CUBE_MAP, cube)
}

draw_fullscreen :: proc(vao : u32, p : u32) {
	gl.UseProgram(p)
	gl.BindVertexArray(vao)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
}

make_output_target :: proc(tex : ^u32, fbo : ^u32) {
	gl.GenTextures(1, tex)
	gl.BindTexture(gl.TEXTURE_2D, tex^)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, OUT_W, OUT_H, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.GenFramebuffers(1, fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, fbo^)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, tex^, 0)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

dump_rgba :: proc(path : string, pixels : []u8, w, h : int) {
	hdr := fmt.tprintf("P6\n%d %d\n255\n", w, h)
	rgb := make([]u8, w * h * 3, context.allocator)
	defer delete(rgb)
	for i in 0 ..< w * h {
		rgb[i * 3 + 0] = pixels[i * 4 + 0]
		rgb[i * 3 + 1] = pixels[i * 4 + 1]
		rgb[i * 3 + 2] = pixels[i * 4 + 2]
	}
	out := make([]u8, len(hdr) + len(rgb), context.allocator)
	defer delete(out)
	copy(out, hdr)
	copy(out[len(hdr):], rgb)
	write_file(path, out)
}

write_ppm :: proc(path : string, w, h : int) {
	pixels := make([]u8, w * h * 4, context.allocator)
	defer delete(pixels)
	gl.PixelStorei(gl.PACK_ALIGNMENT, 1)
	gl.ReadPixels(0, 0, i32(w), i32(h), gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels))

	// ReadPixels hands back rows bottom-up, so the file is rewritten top-down; an
	// upside-down image would put the floor in the sky and make every comparison lie.
	flipped := make([]u8, w * h * 4, context.allocator)
	defer delete(flipped)
	for y in 0 ..< h {
		src := (h - 1 - y) * w * 4
		dst := y * w * 4
		copy(flipped[dst:dst + w * 4], pixels[src:src + w * 4])
	}
	dump_rgba(path, flipped, w, h)
}
