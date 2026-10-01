package paths

import "core:os"
import "core:strings"

// Where the resources live, resolved once at startup.
//
// Every field is a directory with a trailing separator, so a consumer appends a
// file name directly: strings.concatenate({AssetsDir(), "marble_bust_model/x.gltf"}).
//
// Forward slashes on every platform, matching the literal paths this project used
// before this package existed. Not filepath.join: that one allocates on every
// call and mixes the system separator in.
Data :: struct {
	resource : string, // <cwd>/resource/
	assets   : string, // <cwd>/resource/assets/
	shaders  : string, // <cwd>/resource/shaders/
}

data : Data

// Resolves the resource tree against the current working directory and keeps the
// result for the life of the process. Call once, before anything reads a path.
//
// The working directory is the anchor, so the process has to be started from the
// directory that holds resource/ -- there is no search, no fallback, and no
// executable-relative mode.
//
// Allocation: four small strings, once. Every accessor after this is a field read.
Init :: proc() -> bool {
	cwd, err := os.get_working_directory(context.allocator)
	if err != nil {
		return false
	}
	// get_working_directory allocates; joinPathWithSlash does not reuse its input,
	// so it is free to go.
	defer delete(cwd)

	data.resource = joinPathWithSlash(cwd, "resource")
	data.assets = joinPathWithSlash(data.resource, "assets")
	data.shaders = joinPathWithSlash(data.resource, "shaders")

	return true
}

// No allocation, no I/O. Empty until Init has run.
ResourceDir :: proc() -> string {
	return data.resource
}

AssetsDir :: proc() -> string {
	return data.assets
}

ShadersDir :: proc() -> string {
	return data.shaders
}

// One trailing '/' on the result, never two.
joinPathWithSlash :: proc(left, right : string) -> string {
	separator := "/"
	if strings.has_suffix(left, "/") {
		separator = ""
	}
	suffix := "/"
	if strings.has_suffix(right, "/") {
		suffix = ""
	}
	return strings.concatenate({left, separator, right, suffix})
}
